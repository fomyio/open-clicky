import Testing
import Foundation
import AVFoundation
@testable import OpenClickyKit

/// The guard against the defect that made voice mode appear not to work at all.
///
/// `setVoiceProcessingEnabled(true)` reconfigures the input node into the VPIO unit's own
/// layout — nine channels, deinterleaved, on the machine this was found on — and
/// `AVAudioConverter` has no standard downmix for that. It does not fail. It produces
/// frames of the right length at the right rate, filled with zeroes. Measured over three
/// seconds in an ordinary room: no voice processing gave −36 dBFS, the default downmix
/// gave exactly zero, and taking channel 0 gave −25 dBFS.
///
/// So every session streamed perfect silence. Deepgram answered with empty transcripts,
/// which the parse correctly drops, and the session sat in `.listening` looking healthy.
/// Nothing threw and nothing logged. These hold the two pieces that make that state
/// detectable instead of invisible.
@Suite("Silent microphone detection")
struct SilenceWatchdogTests {

    // MARK: - Telling a dead stream from a quiet room

    /// The distinction the whole guard rests on. A real microphone in a silent room still
    /// carries its own noise floor — around −60 dBFS on a laptop — so a run of *exact*
    /// zeroes is a claim about the stream, not about the room.
    @Test("Digital silence is exact zeroes, not merely quiet")
    func exactZeroesOnly() {
        let dead = Data(count: 320)
        #expect(AudioCapture.isDigitallySilent(dead))

        // One sample of noise floor, of the size a real room produces, is enough.
        var faint = [Int16](repeating: 0, count: 160)
        faint[80] = 3
        let quiet = faint.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(!AudioCapture.isDigitallySilent(quiet))
        // And the level meter still calls that room silent, which is why the two
        // questions cannot share one answer.
        #expect(AudioCapture.loudness(of: quiet) == 0)
    }

    @Test("An empty buffer is not a claim about anything")
    func emptyBufferIsNotSilence() {
        #expect(!AudioCapture.isDigitallySilent(Data()))
        #expect(!AudioCapture.isDigitallySilent(Data([0])))
    }

    // MARK: - The cause

    /// The line the whole fix turns on, and the one the mutation sweep found defended by
    /// nothing: removing it restored the silent session with every other test still
    /// green. Nine channels is what `setVoiceProcessingEnabled(true)` actually produced
    /// on the machine this was found on, and `AVAudioConverter` has no standard downmix
    /// for that layout — it emits zeroes at the right rate rather than failing.
    @Test("A multi-channel input is taken from channel 0, never downmixed")
    func multiChannelInputTakesTheProcessedChannel() {
        // The VPIO layout that produced digital silence.
        #expect(AudioCapture.channelMap(forSourceChannels: 9) == [0])
        // And every other multi-element device, for the same reason: averaging elements
        // buys a recogniser nothing and can phase-cancel.
        #expect(AudioCapture.channelMap(forSourceChannels: 2) == [0])
        #expect(AudioCapture.channelMap(forSourceChannels: 4) == [0])
    }

    /// Mono in, mono out: there is nothing to choose, and a map here would only be a
    /// second way to say what the converter already does.
    @Test("A mono input is left to the converter")
    func monoInputNeedsNoMap() {
        #expect(AudioCapture.channelMap(forSourceChannels: 1) == nil)
    }

    // MARK: - When it fires

    @Test("It fires once the stream has been dead past the threshold")
    func firesAfterTheThreshold() {
        var watchdog = SilenceWatchdog(threshold: 4)
        // 100 ms buffers, as the tap delivers them.
        for index in 0..<39 {
            let tripped = watchdog.observe(isSilent: true, duration: 0.1)
            #expect(!tripped, "tripped early, at buffer \(index)")
        }
        let tripped = watchdog.observe(isSilent: true, duration: 0.1)
        #expect(tripped)
    }

    /// It reaches a surface the user is looking at, and a warning repeated fifty times a
    /// second is noise that buries the session it describes.
    @Test("It fires once per session, not once per buffer")
    func firesOnlyOnce() {
        var watchdog = SilenceWatchdog(threshold: 1)
        var fired = 0
        for _ in 0..<200 {
            if watchdog.observe(isSilent: true, duration: 0.1) { fired += 1 }
        }
        #expect(fired == 1)
        #expect(watchdog.hasWarned)
    }

    /// The false positive that would matter most: a session that works, told it does not.
    @Test("A working microphone never trips it, however quiet the room")
    func liveAudioNeverTrips() {
        var watchdog = SilenceWatchdog(threshold: 4)
        for _ in 0..<500 {
            let tripped = watchdog.observe(isSilent: false, duration: 0.1)
            #expect(!tripped)
        }
        #expect(watchdog.silentFor == 0)
    }

    /// A genuine gap — a muted call, a device switching mid-session, a headset coming up
    /// — must pass without a warning.
    @Test("A gap shorter than the threshold is forgiven, and forgotten")
    func gapsResetTheCount() {
        var watchdog = SilenceWatchdog(threshold: 4)
        for _ in 0..<30 { _ = watchdog.observe(isSilent: true, duration: 0.1) }
        #expect(watchdog.silentFor > 2.9)

        _ = watchdog.observe(isSilent: false, duration: 0.1)
        #expect(watchdog.silentFor == 0)

        // And the count starts over rather than resuming where it left off.
        for _ in 0..<30 {
            let tripped = watchdog.observe(isSilent: true, duration: 0.1)
            #expect(!tripped)
        }
    }

    /// A session restarted to fix this must be able to report it again if the fix did not
    /// take — otherwise the second attempt looks like the first one having worked. The
    /// re-arming is `AudioCapture.start()` constructing a fresh watchdog per session, not a
    /// `reset()` somebody has to remember to call, so what a test can hold is the half that
    /// makes that work: a new watchdog is armed whatever a previous one did.
    @Test("A fresh watchdog is armed, which is how a restarted session reports again")
    func aFreshWatchdogIsArmed() {
        var spent = SilenceWatchdog(threshold: 1)
        for _ in 0..<20 { _ = spent.observe(isSilent: true, duration: 0.1) }
        #expect(spent.hasWarned)

        var restarted = SilenceWatchdog(threshold: 1)
        #expect(!restarted.hasWarned)
        #expect(restarted.silentFor == 0)

        var firedAgain = false
        for _ in 0..<20 {
            if restarted.observe(isSilent: true, duration: 0.1) { firedAgain = true }
        }
        #expect(firedAgain)
    }

    @Test("A negative or zero-length buffer cannot move the count backwards")
    func degenerateDurationsAreIgnored() {
        var watchdog = SilenceWatchdog(threshold: 1)
        _ = watchdog.observe(isSilent: true, duration: -100)
        #expect(watchdog.silentFor == 0)
        #expect(!watchdog.hasWarned)
    }

    // MARK: - What it says

    /// The message someone reads while a session is open and apparently fine. It has to
    /// name the state — the stream, not the room — or it reads as the app complaining
    /// that nobody is talking.
    @Test("The message distinguishes a broken stream from a quiet room")
    func messageNamesTheRealState() {
        let text = AudioCapture.Error.silentInput.description
        #expect(text.contains("digital silence"))
        #expect(text.lowercased().contains("quiet room"))
        #expect(text.contains("Sound"))
    }
}
