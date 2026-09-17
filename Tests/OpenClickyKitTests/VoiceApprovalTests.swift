import Testing
import Foundation
@testable import OpenClickyKit

/// Consent by microphone. The gate is the only containment this project has, and a
/// spoken answer is a *guess* about what someone said, arriving on a channel that is
/// open continuously and hears everyone in the room. Every rule here fails towards
/// denial, and the tests are written to catch a future edit that makes it generous.
@Suite("Spoken approval")
struct VoiceApprovalTests {

    @Test("A plain affirmative approves", arguments: [
        "yes", "Yes", "YES", "yes.", "Yes!", "  yes  ", "confirm", "Confirmed.",
        "do it", "Do it!", "go ahead", "approve", "approved", "yes please",
    ])
    func plainAffirmativesApprove(spoken: String) {
        #expect(VoiceApproval.read(spoken) == .approved, "'\(spoken)'")
        #expect(VoiceApproval.approval(for: spoken) == .allow)
    }

    @Test("A plain refusal denies", arguments: [
        "no", "No.", "nope", "stop", "cancel", "don't", "Don't!", "do not",
        "deny", "never mind", "abort", "no thanks",
    ])
    func plainRefusalsDeny(spoken: String) {
        #expect(VoiceApproval.read(spoken) == .denied, "'\(spoken)'")
        #expect(VoiceApproval.approval(for: spoken) == .deny)
    }

    /// The rule that separates this from the typed parser. A second clause is evidence
    /// the person was not answering this question — they were talking to someone, or
    /// carrying on with an instruction — and a microphone cannot tell those apart.
    @Test("An affirmative with anything else attached is not consent", arguments: [
        "yes and then open Safari", "yes but not that one", "yes I was talking to Sam",
        "well yes", "yes if you have to", "I guess yes", "yes yes yes",
        "he said yes", "yes to the first one", "do it later", "go ahead and wait",
    ])
    func qualifiedAffirmativesDoNotApprove(spoken: String) {
        #expect(VoiceApproval.read(spoken) != .approved, "'\(spoken)' approved a destructive call")
        #expect(VoiceApproval.approval(for: spoken) == .deny)
    }

    /// Things people say while thinking, to someone else, or to acknowledge having
    /// heard the question rather than to answer it. A destructive action is not the
    /// place to be generous about what counts as consent.
    @Test("Hedges and acknowledgements are not consent", arguments: [
        "sure", "okay", "ok", "alright", "yep", "yeah", "fine", "mhm", "uh huh",
        "right", "I mean", "hold on", "wait", "hmm", "whatever",
    ])
    func hedgesAreNotConsent(spoken: String) {
        #expect(VoiceApproval.read(spoken) != .approved, "'\(spoken)' approved a destructive call")
        #expect(VoiceApproval.approval(for: spoken) == .deny)
    }

    /// A misheard fragment, a cough, a door. Unclear is answered by asking again, never
    /// by acting — and never by silently denying without saying so either.
    @Test("Noise is unclear rather than an answer", arguments: [
        "", "   ", "\n", "ss", "the", "asdf", "mm hm hm", "...",
    ])
    func noiseIsUnclear(spoken: String) {
        #expect(VoiceApproval.read(spoken) == .unclear, "'\(spoken)'")
        #expect(VoiceApproval.approval(for: spoken) == .deny, "unclear must never approve")
    }

    /// The direction the whole file fails in, asserted as a property rather than by
    /// example: nothing outside the small affirmative list can approve, whatever it is.
    @Test("Nothing unlisted can approve, however it is spelled")
    func onlyListedPhrasesApprove() {
        let listed = ["yes", "yes please", "yes do it", "confirm", "confirmed",
                      "approve", "approved", "do it", "go ahead", "permission granted"]
        // Every mutation of a listed phrase that adds a word must stop approving.
        for phrase in listed {
            for suffix in [" later", " to that", " I think", " and stop", " not"] {
                #expect(VoiceApproval.approval(for: phrase + suffix) == .deny,
                        "'\(phrase + suffix)'")
            }
            for prefix in ["don't ", "do not ", "maybe ", "did you say "] {
                #expect(VoiceApproval.approval(for: prefix + phrase) == .deny,
                        "'\(prefix + phrase)'")
            }
        }
    }

    /// `PermissionGate.parse` is the authority on what approves, and this must not grow
    /// a second one. The typed parser's own rule — that an unadvertised key is not
    /// consent — is what stops "a" meaning always-allow on a destructive prompt, and it
    /// has to keep applying when the answer arrives by microphone.
    @Test("A spoken answer can never establish a standing grant")
    func spokenAnswerNeverAlwaysAllows() {
        for spoken in ["always", "always allow", "a", "allow always", "yes always",
                       "yes to everything", "stop asking", "don't ask again"] {
            #expect(VoiceApproval.approval(for: spoken) != .allowAlways, "'\(spoken)'")
        }
        // And the one phrase that does approve approves exactly once.
        #expect(VoiceApproval.approval(for: "yes") == .allow)
    }

    /// Punctuation and capitalisation are the transcriber's choices, not the speaker's.
    @Test("Normalisation strips the transcriber's punctuation, not the speaker's words")
    func normalisationKeepsWords() {
        #expect(VoiceApproval.normalize("  Yes,   please!  ") == "yes please")
        #expect(VoiceApproval.normalize("Don't.") == "don't")
        #expect(VoiceApproval.normalize("Yes — and no") == "yes and no")
    }
}
