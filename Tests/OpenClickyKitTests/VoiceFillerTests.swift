import Testing
import Foundation
@testable import OpenClickyKit

/// The silence this covers is not cosmetic. A spoken session that goes quiet does not
/// read as "working" — it reads as "it did not hear me", so the sentence gets said
/// again, and saying it again is barge-in: it cancels the run that was about to answer.
@Suite("Voice filler")
struct VoiceFillerTests {

    @Test("Consecutive turns get different openers")
    func openersDoNotRepeat() {
        let said = (0..<VoiceFiller.openers.count).map { VoiceFiller.opener(turn: $0) }
        #expect(Set(said).count == said.count)
    }

    @Test("Consecutive holds in one wait get different words")
    func holdsDoNotRepeat() {
        let said = (0..<VoiceFiller.holds.count).map { VoiceFiller.hold(after: $0) }
        #expect(Set(said).count == said.count)
    }

    /// A session can be talked to for a very long time, and the counter behind these is
    /// a turn count. Wrapping is the answer; trapping is not.
    @Test("The counters wrap rather than trapping", arguments: [
        0, 1, 7, 99, 1_000_000, Int.max, -1, -7, Int.min + 1,
    ])
    func indicesWrap(index: Int) {
        #expect(!VoiceFiller.opener(turn: index).isEmpty)
        #expect(!VoiceFiller.hold(after: index).isEmpty)
    }

    /// Every line is about this conversation — heard you, still going — and never about
    /// what was found or done. A filler that said "let me check your settings" would be
    /// the application putting a statement about the user's machine into its own mouth,
    /// which is one surface along from a run reporting success it did not earn.
    @Test("No filler claims anything about the machine")
    func fillersMakeNoClaims() {
        let claims = [
            "found", "opened", "done", "finished", "settings", "updates",
            "installed", "ready", "worked", "success",
        ]
        for line in VoiceFiller.openers + VoiceFiller.holds {
            let lowered = line.lowercased()
            for claim in claims {
                #expect(!lowered.contains(claim), "\(line) claims something it cannot know")
            }
        }
    }

    /// Spoken into the gap before the agent's own first sentence. An opener still
    /// playing when the narration arrives delays the only part with information in it.
    @Test("An opener is short enough to be out of the way")
    func openersAreShort() {
        // Speech is about fifteen characters a second; two seconds is a receipt.
        for line in VoiceFiller.openers { #expect(line.count <= 30, "\(line)") }
        for line in VoiceFiller.holds { #expect(line.count <= 30, "\(line)") }
    }

    /// Long enough that an ordinary turn is never interrupted by one, short enough that
    /// a twenty-five-second planner wait is broken up rather than one unbroken silence.
    @Test("Patience is longer than an ordinary turn and shorter than a long one")
    func patienceIsInTheRightRange() {
        #expect(VoiceFiller.patience > 4)
        #expect(VoiceFiller.patience < 12)
    }
}
