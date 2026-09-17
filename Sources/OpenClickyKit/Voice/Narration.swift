import Foundation

/// Turns what the agent wrote into what it should say.
///
/// The two are not the same text and the gap is wider than it looks. Prose written for a
/// terminal carries markdown, backticks, absolute paths, URLs, bullet lists and code —
/// every one of which is either unintelligible or actively hostile when read aloud.
/// "Press `cmd+shift+p`" spoken verbatim is "press backtick c m d plus shift plus p
/// backtick"; `/Users/someone/Documents/Projects/OpenClicky/Sources/…` is eleven seconds
/// of path nobody was listening to by the end of.
///
/// A pure function over a string, in the kit, because it is the one part of speech that
/// can be checked without a speaker — and because getting it wrong is not a crash but a
/// slow erosion of whether the thing is bearable to use, which no test catches by
/// accident.
///
/// **It only ever removes and shortens.** Nothing here invents a word the model did not
/// write. The narration is the agent's own account of what it is doing, and a layer that
/// paraphrased it would be putting statements about the user's machine into its mouth —
/// the same class of error as a run reporting success it did not earn, one surface along.
public enum Narration {

    /// Roughly how many characters are worth speaking from one turn.
    ///
    /// Speech is about fifteen characters a second, so this is ~20 seconds — already
    /// long for "say what you are about to do". The point of the cap is not economy but
    /// interruptibility: a narration that runs for a minute is one the user has to talk
    /// over to stop, and having to interrupt your assistant to get on with things is the
    /// failure this whole phase is trying to avoid. The model is *also* told to be brief
    /// (see `SystemPrompt.session`); this is what happens when it is not.
    public static let budget = 300

    /// What to say for a turn's prose, or nil when there is nothing worth saying.
    ///
    /// Nil rather than empty for the same reason `SummonedApp.remembered` returns nil:
    /// the caller's decision is "speak or don't", and an empty string is a request to
    /// speak nothing, which queues an utterance and fires a completion for silence.
    public static func speakable(_ prose: String) -> String? {
        var text = prose

        // Fenced code first, before anything else can strip the fences and leave the
        // code looking like prose. A block is never spoken: it is for reading, it is
        // usually long, and it is the single worst thing that can arrive at a speaker.
        text = replacing(#"```[\s\S]*?```"#, in: text, with: " ")

        // Inline code keeps its content — `cmd+shift+p` is exactly the sort of thing the
        // narration exists to say — but loses the backticks, which are not words.
        text = replacing("`([^`]*)`", in: text, with: "$1")

        // Markdown emphasis and headings. The characters are punctuation to a reader and
        // noise to a listener.
        text = replacing(#"\*\*([^*]*)\*\*"#, in: text, with: "$1")
        text = replacing(#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, in: text, with: "$1")
        text = replacing(#"(?m)^\s{0,3}#{1,6}\s+"#, in: text, with: "")

        // A link says its text, not its target.
        text = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(#"\bhttps?://([^\s/]+)\S*"#, in: text, with: "$1")

        // An absolute path is spoken as the thing at the end of it. The directories
        // above are how a machine finds a file, not how a person refers to one, and by
        // the time they have been read out the sentence they were in is over.
        // Home-relative first. The absolute rule below matches two-or-more segments and
        // would otherwise eat the tail of `~/Library/Preferences/x.plist`, leaving the
        // tilde stranded against the filename as "~x.plist".
        text = replacing(#"~(?:/[\w.@%+-]+)+/?"#, in: text, with: { match in
            match.split(separator: "/").last.map(String.init) ?? "that path"
        })
        text = replacing(#"(?:/[\w.@%+-]+){2,}/?"#, in: text, with: { match in
            let name = match.split(separator: "/").last.map(String.init) ?? match
            return name.isEmpty ? "that path" : name
        })

        // List markers become sentence breaks: a listener has no bullets to see, and
        // without the pause the items run together into one clause.
        text = replacing(#"(?m)^\s*[-*+]\s+"#, in: text, with: ". ")
        text = replacing(#"(?m)^\s*\d+[.)]\s+"#, in: text, with: ". ")

        // Every run of whitespace is one space. Paragraph breaks carry no meaning to a
        // synthesiser, and a newline mid-sentence makes some of them pause oddly.
        text = replacing(#"\s+"#, in: text, with: " ")
        text = replacing(#"(?:\.\s*){2,}"#, in: text, with: ". ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Punctuation on its own is what is left of a turn that was entirely code or an
        // entirely stripped list. There is nothing in it to say.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return clipped(text)
    }

    /// Cuts to the budget at a sentence end where possible.
    ///
    /// Mid-word is the one place it must never cut: a synthesiser given half a word says
    /// half a word, and the listener hears a fault rather than an abbreviation. Falling
    /// back to a word boundary and then to the raw budget keeps that impossible whatever
    /// the text looks like.
    static func clipped(_ text: String, to budget: Int = budget) -> String {
        guard text.count > budget else { return text }
        let head = String(text.prefix(budget))

        // Prefer the last sentence end, but only if it keeps enough to be worth saying —
        // otherwise a long first sentence would be cut back to almost nothing.
        if let stop = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: stop) > budget / 2 {
            return String(head[...stop])
        }
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }

    /// The same, where the replacement depends on what was matched.
    private static func replacing(
        _ pattern: String, in text: String, with transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Backwards, so each replacement cannot invalidate the ranges not yet applied.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
