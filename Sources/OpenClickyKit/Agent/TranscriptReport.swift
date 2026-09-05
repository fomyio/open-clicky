import Foundation

/// Renders a stored session back into something a person can read.
///
/// The record was write-only. A run wrote megabytes of it, `doctor` reported that the
/// files accumulate and are never pruned, and nothing could open one — so "the
/// transcript exists to reconstruct what happened" was a claim with no implementation
/// behind it, and debugging a run meant `jq` and guesswork.
public enum TranscriptReport {

    /// Parses a session file.
    ///
    /// A trailing partial line is dropped rather than thrown on: a run that crashed or
    /// was killed mid-write leaves one, and that is exactly the session someone most
    /// wants to read. Refusing to open it would fail precisely when it matters.
    public static func entries(at url: URL) throws -> [Transcript.Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? withFraction.parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }

        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(Transcript.Entry.self, from: Data(line.utf8))
            }
    }

    /// The session rendered as lines, in the order it happened.
    public static func lines(for entries: [Transcript.Entry]) -> [RunReport.Line] {
        let ordered = entries.sorted { $0.sequence < $1.sequence }
        guard let start = ordered.first?.timestamp else {
            return [.init(text: "The record is empty.", emphasis: .detail)]
        }

        var lines: [RunReport.Line] = []
        for entry in ordered {
            let elapsed = entry.timestamp.timeIntervalSince(start)
            let stamp = String(format: "%6.1fs", elapsed)
            lines.append(contentsOf: render(entry, stamp: stamp))
        }
        return lines
    }

    private static func render(_ entry: Transcript.Entry, stamp: String) -> [RunReport.Line] {
        switch entry.kind {
        case "user", "assistant":
            return blocks(of: entry.payload).flatMap { stamped($0.0, $0.1, stamp: stamp) }
        default:
            return stamped("[\(entry.kind)] \(describe(entry.payload))", .warning, stamp: stamp)
        }
    }

    /// Puts the elapsed time on the first line and aligns the rest under it.
    ///
    /// A script's line structure is most of what makes it readable, and the shared
    /// `truncated` helper flattens newlines to spaces — right for an accessibility
    /// label, which is one node per line, wrong here: a six-line AppleScript came back
    /// as one run-on sentence. Found by reading a rendered session rather than by any
    /// test, which is the only way this kind of thing surfaces.
    private static func stamped(
        _ text: String, _ emphasis: RunReport.Line.Emphasis, stamp: String
    ) -> [RunReport.Line] {
        let padding = String(repeating: " ", count: stamp.count)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                .init(text: "\(index == 0 ? stamp : padding) \(line)", emphasis: emphasis)
            }
    }

    /// Truncates without flattening: line breaks are the structure being preserved.
    private static func clipped(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    /// One line per content block, with images named rather than printed.
    ///
    /// A screenshot is ~180KB of base64. Rendering it would bury the run in the one
    /// thing the reader cannot use, which is the failure mode a transcript viewer
    /// exists to avoid.
    private static func blocks(of payload: JSONValue) -> [(String, RunReport.Line.Emphasis)] {
        let role = payload["role"]?.stringValue ?? "?"
        guard let content = payload["content"]?.arrayValue else {
            return [("\(role): \(describe(payload))", .detail)]
        }

        return content.compactMap { block in
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                return ("\(role): \(clipped(text, 400))", role == "assistant" ? .speech : .detail)
            case "tool_use":
                let name = block["name"]?.stringValue ?? "?"
                return ("  → \(name) \(describe(block["input"] ?? .null))", .detail)
            case "tool_result":
                let isError = block["is_error"]?.boolValue ?? false
                return ("  \(isError ? "✗" : "✓") \(summarise(block["content"]))",
                        isError ? .failure : .success)
            case "thinking", "redacted_thinking":
                return ("  · thinking", .detail)
            case let other:
                return ("  ? \(other ?? "unknown block")", .detail)
            }
        }
    }

    private static func summarise(_ content: JSONValue?) -> String {
        guard let pieces = content?.arrayValue else { return describe(content ?? .null) }
        return pieces.map { piece -> String in
            if piece["type"]?.stringValue == "image" {
                let bytes = piece["source"]?["data"]?.stringValue?.count ?? 0
                return "[image, \(bytes / 1024)KB]"
            }
            return clipped(piece["text"]?.stringValue ?? "", 300)
        }.joined(separator: " ")
    }

    private static func describe(_ value: JSONValue) -> String {
        guard let fields = value.objectValue else { return value.stringValue ?? "" }
        return fields.keys.sorted().map { key in
            "\(key)=\(clipped(fields[key]?.stringValue ?? "\(fields[key] ?? .null)", 400))"
        }.joined(separator: " ")
    }
}
