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
        /// The stream is alive and carrying nothing. See `SilenceWatchdog`.
        case silentInput

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
            case .silentInput:
                return """
                    The microphone is open but every sample arriving is digital \
                    silence, so nothing is being transcribed. A quiet room is never \
                    exactly zero — this is the stream being broken rather than nobody \
                    talking. Check that the input device in System Settings ▸ Sound is \
                    the one you are speaking into, and that no other app has taken \
                    exclusive use of it.
                    """
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

    /// Opens the microphone and delivers mono 16-bit PCM until `stop()`.
    ///
    /// - Parameters:
    ///   - sampleRate: the rate the chosen transcriber was told to expect.
    ///
    ///     Passed in rather than read off `AudioFormat`, because the two vendors wired
    ///     up disagree — Deepgram is told 16 kHz in its query string, and the Realtime
    ///     API's `pcm16` *means* 24 kHz — and a vendor told the wrong rate does not
    ///     fail, it transcribes noise. That is the defect this whole conversion exists
    ///     to prevent, so the rate travels with the choice of vendor rather than being
    ///     assumed here.
    ///   - onBuffer: called on the audio thread with mono PCM at `sampleRate`. It must
    ///     not block: everything it hands the buffer to is asynchronous for that reason.
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
    ///   - onProblem: called at most once per session, from the audio thread, when the
    ///     stream is alive and carrying nothing. See `SilenceWatchdog` and the channel
    ///     map below for why that is a state this had to learn to detect.
    public func start(
        sampleRate: Int = AudioFormat.sampleRate,
        onBuffer: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in },
        onProblem: @escaping @Sendable (Error) -> Void = { _ in }
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

        // Read *after* voice processing has been enabled, because enabling it replaces
        // the node's format — and on this hardware it replaces 1 channel with nine.
        let sourceFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(AudioFormat.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw Error.engineFailed(
                "no conversion from \(sourceFormat) to \(sampleRate) Hz mono PCM"
            )
        }
        // The fix for the bug that made voice appear not to work at all. See
        // `channelMap(forSourceChannels:)`.
        if let map = Self.channelMap(forSourceChannels: sourceFormat.channelCount) {
            converter.channelMap = map
        }
        // Belt and braces for the same class of defect: a stream that is alive and
        // carrying nothing must say so rather than look like a quiet room.
        //
        // Per session rather than per instance, and that is what makes the once-per-session
        // contract hold: a capture restarted on this same object gets a watchdog that has
        // never warned, without anyone having to remember to re-arm one in `stop()`.
        let watchdog = SilenceBox(SilenceWatchdog())

        input.installTap(onBus: 0, bufferSize: 2_048, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard !self.gated else {
                // Gated: nothing is being listened to, so the meter reads nothing.
                onLevel(0)
                return
            }
            guard let data = Self.convert(buffer, using: converter, to: target) else { return }
            // Fed before the buffer goes anywhere, and measured on the samples actually
            // being sent — the same honesty rule the level meter follows.
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            if watchdog.observe(isSilent: Self.isDigitallySilent(data), duration: seconds) {
                onProblem(Error.silentInput)
            }
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

    /// Which source channel a mono conversion should take, or nil to leave it to the
    /// converter's own layout handling.
    ///
    /// **The bug that made voice mode appear not to work at all.**
    ///
    /// `setVoiceProcessingEnabled(true)` reconfigures the input node into the VPIO unit's
    /// own layout. On the machine this was found on that is *nine* channels,
    /// deinterleaved — the processed voice, the raw elements, and the render reference —
    /// and `AVAudioConverter` has no standard downmix for a nine-channel layout. It does
    /// not fail. It produces frames of the right length at the right rate, filled with
    /// digital silence. Measured over three seconds in an ordinary room: no voice
    /// processing gave −36 dBFS, voice processing with the default downmix gave exactly
    /// zero, and taking channel 0 gave −25 dBFS.
    ///
    /// So every voice session this app ever started streamed perfect silence to the
    /// transcriber. Deepgram answered with empty transcripts, which
    /// `DeepgramTranscriber.events(in:)` correctly drops, so the session sat in
    /// `.listening` looking entirely healthy and heard nothing, forever. Nothing threw
    /// and nothing logged.
    ///
    /// Channel 0 rather than a downmix, and not only as a repair: for the VPIO unit
    /// channel 0 *is* the echo-cancelled voice channel, which is the one signal here
    /// worth having. For an ordinary multi-element device it is the primary mic.
    /// Averaging elements buys a recogniser nothing and can phase-cancel.
    ///
    /// A free function over a channel count rather than a line inside `start()`, because
    /// `start()` needs a device and the mutation sweep found this exact decision
    /// defended by nothing — the most important line in the fix, and removing it would
    /// have restored the silent session with every test still green.
    static func channelMap(forSourceChannels count: AVAudioChannelCount) -> [NSNumber]? {
        // Mono in, mono out: there is nothing to choose, and forcing a map would only
        // be a second way to say the same thing.
        guard count > 1 else { return nil }
        return [0]
    }

    /// Whether every sample in the buffer is exactly zero.
    ///
    /// The distinction that makes the watchdog honest. A real microphone in a silent
    /// room still produces its own noise floor — around −60 dBFS on a laptop — so a run
    /// of *exact* zeros is not quiet, it is a stream that is not carrying the microphone
    /// at all. `loudness` cannot be used for this: its −50 dB floor deliberately reports
    /// a quiet room as zero, which is the whole reason the two are separate.
    static func isDigitallySilent(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return false }
        return pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).allSatisfy { $0 == 0 }
        }
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

/// A `SilenceWatchdog` reachable from the audio thread.
///
/// The tap closure is `@Sendable` and called on a real-time thread, and the watchdog is
/// a mutating value type. A class with a lock is the cheapest correct way to hold one
/// across those calls; the critical section is two comparisons and an addition, which is
/// short enough to be safe where a real-time thread is concerned.
private final class SilenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var watchdog: SilenceWatchdog
    init(_ watchdog: SilenceWatchdog) { self.watchdog = watchdog }
    func observe(isSilent: Bool, duration: TimeInterval) -> Bool {
        lock.withLock { watchdog.observe(isSilent: isSilent, duration: duration) }
    }
}
