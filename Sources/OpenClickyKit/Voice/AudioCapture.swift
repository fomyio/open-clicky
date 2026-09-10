import Foundation
import AVFoundation

/// The microphone, converted into what the transcriber expects.
///
/// Two jobs, and the second one is the interesting one.
///
/// **Format.** The input device runs at whatever rate it likes — 44.1 kHz or 48 kHz
/// float, usually — and the transcriber is told, in the socket's query string, to
/// expect 16 kHz mono 16-bit PCM. Those two facts have to be reconciled somewhere, and
/// a vendor told the wrong format does not fail: it transcribes noise, confidently.
/// The conversion happens once, here, at the tap.
///
/// **Echo.** The agent speaks through the same machine it listens on, so its own voice
/// arrives back at the microphone and reads as the user interrupting — the session
/// cancels its own run, then does it again on the next sentence. This is the
/// audio-domain form of the invariant this project keeps rediscovering: *our own
/// surface is not the user's*. `setVoiceProcessingEnabled` asks the OS to subtract our
/// output from the input, which is the only version of this that lets someone interrupt
/// mid-sentence. It can refuse — some aggregate and virtual devices do not support it —
/// and when it does, `hasEchoCancellation` reports the truth so `VoiceSession` falls
/// back to gating the transcript while speaking. A capability that cannot be confirmed
/// is treated as absent; guessing the other way produces a session that talks over
/// itself and looks possessed.
public final class AudioCapture: @unchecked Sendable {

    public enum Error: Swift.Error, CustomStringConvertible {
        case microphoneDenied
        case engineFailed(String)

        public var description: String {
            switch self {
            case .microphoneDenied:
                return """
                    Microphone access is not granted, so the voice session cannot hear \
                    anything. Grant it in System Settings > Privacy & Security > \
                    Microphone. This is a third grant, separate from Accessibility and \
                    Screen Recording.
                    """
            case let .engineFailed(detail):
                return "The audio engine would not start: \(detail)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var isGated = false

    /// Whether the OS is subtracting our own output from what the mic hears.
    ///
    /// Read after `start()`. Before it, the answer is not known and is therefore false.
    public private(set) var hasEchoCancellation = false

    public init() {}

    /// Whether the user has granted microphone access.
    ///
    /// Asked separately from starting, so `doctor` and the settings window can report
    /// the grant without opening a device — the same split `PermissionStatus` uses for
    /// Accessibility and Screen Recording.
    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Opens the microphone and delivers 16 kHz mono PCM until `stop()`.
    ///
    /// - Parameter onBuffer: called on the audio thread. It must not block: everything
    ///   it hands the buffer to is asynchronous for that reason.
    /// - Parameters:
    ///   - onBuffer: called on the audio thread with 16 kHz mono PCM. Must not block.
    ///   - onLevel: called on the audio thread with the buffer's loudness, 0–1.
    ///
    ///     A separate channel because it has a different destination and a different
    ///     honesty requirement. The indicator built on it is a *level meter*, not a
    ///     decoration: a waveform that moves while nobody is talking tells the user the
    ///     microphone is working when it may not be, which is the same class of claim as
    ///     a run reporting success it did not earn. So the number is measured from the
    ///     samples actually being sent, and it is zero whenever the transcript is gated
    ///     — because in that state nothing the microphone hears is being listened to,
    ///     and a meter that kept bouncing would be describing a stream going nowhere.
    public func start(
        onBuffer: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
    ) throws {
        guard Self.isAuthorized else { throw Error.microphoneDenied }

        let input = engine.inputNode
        // Asked for before the tap is installed, because enabling it changes the node's
        // format — installing first and enabling after leaves the tap converting from a
        // format the node has stopped using.
        do {
            try input.setVoiceProcessingEnabled(true)
            hasEchoCancellation = input.isVoiceProcessingEnabled
        } catch {
            // Not fatal, and deliberately not silent either: the session still works,
            // it just cannot be interrupted mid-sentence. `VoiceSession` reads this and
            // gates the transcript instead.
            hasEchoCancellation = false
        }

        let sourceFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioFormat.sampleRate),
            channels: AVAudioChannelCount(AudioFormat.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw Error.engineFailed("no conversion from \(sourceFormat) to 16 kHz mono PCM")
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard !self.gated else {
                // Gated: nothing is being listened to, so the meter reads nothing.
                onLevel(0)
                return
            }
            guard let data = Self.convert(buffer, using: converter, to: target) else { return }
            onLevel(Self.loudness(of: data))
            onBuffer(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Error.engineFailed("\(error)")
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        gated = false
    }

    /// Whether buffers are being discarded before they reach the transcriber.
    ///
    /// The engine keeps running either way. Stopping and restarting it around every
    /// sentence the agent speaks costs a device reconfiguration each time — audible as
    /// a click, and slow enough that the first word after it is lost.
    public var gated: Bool {
        get { lock.withLock { isGated } }
        set { lock.withLock { isGated = newValue } }
    }

    /// How loud one buffer is, 0–1, from the samples that are actually being sent.
    ///
    /// RMS rather than peak: a single sample of clipping is not what a room sounds like,
    /// and a meter driven by peaks spends most of its time pinned. Mapped through a
    /// decibel scale because loudness is logarithmic and a linear RMS spends most of
    /// *its* time near zero — speech at a normal distance is around -30 dBFS, which is a
    /// linear 0.03 and indistinguishable from silence on a bar chart.
    ///
    /// The floor is -50 dB: quieter than that is a room, not a voice, and letting it
    /// show would make the indicator twitch continuously at nothing.
    static func loudness(of pcm: Data) -> Float {
        guard pcm.count >= 2 else { return 0 }
        let sumOfSquares = pcm.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            return samples.reduce(0.0) { total, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return total + normalized * normalized
            }
        }
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        let rms = (sumOfSquares / Double(count)).squareRoot()
        guard rms > 0 else { return 0 }

        let floor = -50.0
        let decibels = 20 * log10(rms)
        guard decibels > floor else { return 0 }
        return Float(min(1, (decibels - floor) / -floor))
    }

    /// One buffer, resampled and packed into bytes.
    ///
    /// `.haveData` alone is not success: the converter reports `.inputRanDry` and
    /// `.endOfStream` with a buffer that is valid but empty, and forwarding those sends
    /// zero-length frames down the socket for as long as the mic is open.
    private static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> Data? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        // Boxed because `AVAudioConverterInputBlock` is declared `@Sendable` while
        // `AVAudioPCMBuffer` is not, and the flag it needs is mutable. The block is
        // invoked synchronously, inline, before `convert` returns — it never escapes
        // and never crosses a thread — so the unchecked conformance is describing what
        // actually happens rather than waving the checker past something unproven.
        let source = ConversionSource(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !source.consumed else {
                status.pointee = .noDataNow
                return nil
            }
            source.consumed = true
            status.pointee = .haveData
            return source.buffer
        }
        guard error == nil, output.frameLength > 0,
              let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// One buffer and its consumed flag, for the duration of a single synchronous
/// conversion. See `AudioCapture.convert(_:using:to:)`.
private final class ConversionSource: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
