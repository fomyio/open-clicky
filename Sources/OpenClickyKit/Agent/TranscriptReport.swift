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
    /// Decodes the timestamps a transcript actually writes.
    private static func entryDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? withFraction.parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }
        return decoder
    }

    public static func entries(at url: URL) throws -> [Transcript.Entry] {
        let decoder = entryDecoder()

        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(Transcript.Entry.self, from: Data(line.utf8))
            }
    }

    /// One line about a stored session, for choosing between them.
    public struct Listing: Sendable {
        public let id: String
        public let url: URL
        public let started: Date
        public let task: String
        public let turns: Int
        public let cost: Double?

        /// e.g. `a1b2c3d4  06 Sep 09:00   2 turns  $0.0612  tidy my downloads`
        public var line: String {
            let when = Listing.dateFormat.string(from: started)
            let money = cost.map { String(format: "$%.4f", $0) } ?? "—"
            // "1 turns" reads as a bug in the tool rather than a fact about the run.
            let counted = "\(turns) turn\(turns == 1 ? "" : "s")"
            return "\(id.prefix(8))  \(when)  \(counted.padding(toLength: 8, withPad: " ", startingAt: 0))  "
                + "\(money.padding(toLength: max(money.count, 9), withPad: " ", startingAt: 0))"
                + "  \(task)"
        }

        private static let dateFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd MMM HH:mm"
            return formatter
        }()
    }

    /// Every stored session, newest first.
    ///
    /// A session is named by a UUID, so with more than one of them the only ways to
    /// find the right record were to replay the latest or to already know its id.
    /// What identifies a run to a person is what they asked for and when.
    public static func listings(in directory: URL) -> [Listing] {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "jsonl" }

        return files.compactMap(listing(at:)).sorted { $0.started > $1.started }
    }

    /// One session's summary, without decoding the parts a summary does not use.
    ///
    /// Decoding every line cost 0.15s per session, because a run that takes
    /// screenshots stores each as ~240KB of base64 and the listing was parsing all of
    /// them to print a task and a cost. Six sessions took nearly a second; a hundred
    /// would have taken fifteen. Lines are filtered by a substring first, so an image
    /// is skipped without ever being handed to JSONDecoder.
    private static func listing(at url: URL) -> Listing? {
        let decoder = entryDecoder()
        func decode<S: StringProtocol>(_ line: S) -> Transcript.Entry? {
            try? decoder.decode(Transcript.Entry.self, from: Data(line.utf8))
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // The opening entry carries the task and the start time, and it is the first
        // line — so only the first few kilobytes are needed for it.
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let headText = String(data: head, encoding: .utf8),
              let firstLine = headText.split(separator: "\n").first,
              let opening = decode(firstLine)
        else { return nil }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let latest = lastUsage(in: handle, size: size, decode: decode)

        return Listing(
            id: url.deletingPathExtension().lastPathComponent,
            url: url,
            started: opening.timestamp,
            task: firstTask(in: [opening]),
            // `turn` is zero-based and the record is append-only, so the last usage
            // entry knows how many there were without counting them.
            turns: latest.flatMap { $0.payload["turn"]?.doubleValue }.map { Int($0) + 1 } ?? 0,
            cost: latest?.payload["session_cost_usd"]?.doubleValue
        )
    }

    /// The last `usage` entry, found by reading backwards from the end.
    ///
    /// A run that takes screenshots stores each as ~240KB of base64, so a session is
    /// megabytes and a listing that read all of them took 0.15s each — a hundred
    /// sessions would have been fifteen seconds to print a hundred lines. Everything a
    /// listing needs is at one end of the file or the other.
    private static func lastUsage(
        in handle: FileHandle, size: Int,
        decode: (Substring) -> Transcript.Entry?
    ) -> Transcript.Entry? {
        // Widening window: a usage entry is small, but an image line between it and
        // the end can be large, so one short read is not always enough.
        for window in [64 * 1024, 1024 * 1024, size] where window > 0 {
            let offset = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }

            let entry = text.split(separator: "\n")
                .reversed()
                .lazy
                .filter { String(decoding: $0.utf8.prefix(160), as: UTF8.self).contains("\"usage\"") }
                .compactMap(decode)
                .first
            if let entry { return entry }
            if window >= size { break }
        }
        return nil
    
    }

    /// What the person actually asked for, with the environment probe stripped.
    ///
    /// The first user message is prefixed with an `<environment>` block, so taking it
    /// whole labelled every session with the same six lines about the frontmost app.
    private static func firstTask(in entries: [Transcript.Entry]) -> String {
        for entry in entries where entry.kind == "user" {
            guard let content = entry.payload["content"]?.arrayValue else { continue }
            for block in content where block["type"]?.stringValue == "text" {
                let text = block["text"]?.stringValue ?? ""
                let task = text.components(separatedBy: "</environment>").last ?? text
                let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return clipped(trimmed, 60) }
            }
        }
        return "(no task recorded)"
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
            // Two decimals: a whole run can finish inside one second, and at one
            // decimal every entry in it reads 0.0s — which is exactly the run whose
            // timing someone is trying to understand.
            let stamp = String(format: "%6.2fs", elapsed)
            lines.append(contentsOf: render(entry, stamp: stamp))
        }
        lines.append(contentsOf: summary(for: ordered, start: start))
        return lines
    }

    /// What the run cost and how long it took.
    ///
    /// The per-turn usage notes were rendered raw — a `session_cost_usd` on every
    /// line and no total anywhere — so the one question a person opens an old
    /// transcript to answer had to be answered by scrolling to the last one and
    /// reading a float. The live run has said this since it was written; the replay
    /// of that same run did not.
    private static func summary(
        for entries: [Transcript.Entry], start: Date
    ) -> [RunReport.Line] {
        let usage = entries.filter { $0.kind == "usage" }
        guard let last = usage.last, let end = entries.last?.timestamp else { return [] }

        let cost = last.payload["session_cost_usd"]?.doubleValue
        let turns = usage.count
        let elapsed = end.timeIntervalSince(start)

        var parts = ["\(turns) turn\(turns == 1 ? "" : "s")"]
        parts.append(elapsed < 60
            ? String(format: "%.1fs", elapsed)
            : String(format: "%.1f min", elapsed / 60))
        if let cost { parts.append(String(format: "$%.4f", cost)) }

        // The same canary the live run watches: a cold cache over several turns means
        // something volatile reached the cached prefix and it is re-billed every turn.
        let cacheRead = usage.compactMap { $0.payload["cache_read_tokens"]?.doubleValue }
        let input = usage.compactMap { $0.payload["input_tokens"]?.doubleValue }
        var lines: [RunReport.Line] = [
            .init(text: "", emphasis: .detail),
            .init(text: "── \(parts.joined(separator: " · "))", emphasis: .detail),
        ]
        if turns > 1, input.reduce(0, +) > 0 {
            let rate = cacheRead.reduce(0, +) / input.reduce(0, +)
            if rate < 0.1 {
                lines.append(.init(
                    text: "   note: cache hit rate \(Int(rate * 100))% — the cached "
                        + "prefix was probably invalidated each turn.",
                    emphasis: .warning
                ))
            }
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
        guard let fields = value.objectValue else { return display(value) }
        return fields.keys.sorted().map { key in
            "\(key)=\(clipped(display(fields[key] ?? .null), 400))"
        }.joined(separator: " ")
    }

    /// A value as a person would write it.
    ///
    /// Falling back to string interpolation printed the enum: a turn's usage read
    /// `input_tokens=number(4200.0) session_cost_usd=number(0.027549999999999998)`.
    /// Every one of those is wrong for a reader — the case name, a float for a count,
    /// and fifteen digits of binary rounding on a figure in dollars.
    static func display(_ value: JSONValue) -> String {
        switch value {
        case let .string(text): return text
        case let .bool(flag): return flag ? "true" : "false"
        case let .number(number):
            if number == number.rounded(), abs(number) < 1e15 {
                return String(Int(number))
            }
            return String(format: "%.4f", number)
        case .null: return "null"
        case let .array(items): return "[\(items.map(display).joined(separator: ", "))]"
        case let .object(fields):
            return "{\(fields.keys.sorted().map { "\($0)=\(display(fields[$0] ?? .null))" }.joined(separator: " "))}"
        }
    }
}
