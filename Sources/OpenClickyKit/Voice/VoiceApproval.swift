import Foundation

/// Reads a spoken answer to a destructive-action prompt as consent, or refuses to.
///
/// The narrowest possible widening of `PermissionGate.parse`, and the narrowness is the
/// whole design. That parser is the authority on what approves and stays so: everything
/// here does is decide whether a spoken phrase is unambiguous enough to be *offered* to
/// it as a "yes". A second parser that could approve on its own would be a second thing
/// to keep in step with the first, and the first is the one three audits hardened.
///
/// Speech makes the stakes worse than typing in two specific ways, and both push the
/// same direction:
///
/// - **A transcript is a guess.** "Don't" and "go on" are two words apart in text and
///   much closer in a noisy room. A typed answer is seen before Return is pressed; a
///   spoken one is acted on before the person can see how it was heard.
/// - **The microphone hears everything.** A voice session is open continuously, so a
///   "yeah" said to someone else in the room arrives at the same channel as an answer.
///
/// So the rule is stricter than the typed one rather than looser: the phrase must be an
/// affirmative and *nothing else*. "Yes" approves; "yes, and then open Safari" does not,
/// because the second clause is evidence the person was not answering this question.
/// Everything unrecognised denies, which is the direction `Policy` fails in and the
/// direction `PermissionMode.stored` fails in.
///
/// **There is no spoken "always allow".** `PermissionGate` never offers a standing grant
/// for a destructive call, and a channel that could be misheard is the last one that
/// should be able to establish one.
public enum VoiceApproval {

    /// Phrases that mean yes and mean only yes.
    ///
    /// Deliberately short, and deliberately without "sure", "okay", "alright", "yep" or
    /// "fine" — every one of those is something people say while thinking, to someone
    /// else, or to acknowledge having heard a question rather than to answer it. A
    /// destructive action is not the place to be generous about what counts as consent.
    private static let affirmatives: Set<String> = [
        "yes", "yes please", "yes do it", "confirm", "confirmed",
        "approve", "approved", "do it", "go ahead", "permission granted",
    ]

    /// Phrases that mean no. Listed rather than inferred from "not an affirmative",
    /// because a *recognised* refusal and an unintelligible noise deserve different
    /// things said back — the first is answered, the second is asked again.
    private static let negatives: Set<String> = [
        "no", "no thanks", "no thank you", "don't", "do not", "stop", "cancel",
        "deny", "denied", "nope", "never mind", "nevermind", "abort",
    ]

    /// What a spoken phrase was understood as.
    public enum Reading: Sendable, Equatable {
        case approved
        case denied
        /// Not understood as either. The prompt stands and the question is repeated;
        /// it must never be treated as an answer in either direction.
        case unclear
    }

    /// Reads one utterance.
    ///
    /// Normalisation strips punctuation and collapses whitespace, because a transcriber
    /// decides on its own whether to write "Yes." or "yes" and neither is a different
    /// answer. It does *not* strip words: a phrase with anything else in it stays
    /// unrecognised, which is the point.
    public static func read(_ spoken: String) -> Reading {
        let normalized = normalize(spoken)
        guard !normalized.isEmpty else { return .unclear }
        if affirmatives.contains(normalized) { return .approved }
        if negatives.contains(normalized) { return .denied }
        return .unclear
    }

    /// The gate's own answer for a reading, so the two cannot drift apart.
    ///
    /// Routed through `PermissionGate.parse` rather than returning an `Approval`
    /// directly: that function is where "nothing but an offered choice approves" is
    /// enforced and tested, and it is asked here with `isDestructive: true` because a
    /// spoken answer is only ever solicited for a destructive call — every lesser one
    /// runs unprompted in the mode a voice session is used in.
    public static func approval(for spoken: String) -> PermissionGate.Approval {
        switch read(spoken) {
        case .approved: return PermissionGate.parse("yes", isDestructive: true)
        case .denied, .unclear: return PermissionGate.parse("no", isDestructive: true)
        }
    }

    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
                || $0 == "'"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "’", with: "'")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
