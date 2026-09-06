import Testing
import Foundation
@testable import OpenClickyKit

/// The record was write-only: megabytes per run, reported by `doctor`, never pruned,
/// and openable by nothing. "The transcript exists to reconstruct what happened" was
/// a claim with no implementation behind it.
@Suite("Transcript report")
struct TranscriptReportTests {

    private func write(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session() async throws -> (Transcript, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let transcript = try Transcript(directory: directory)
        return (transcript, directory)
    }

    @Test("A session reads back in the order it happened")
    func roundTrip() async throws {
        let (transcript, directory) = try await session()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("open my notes"))
        await transcript.append(Wire.Message(role: .assistant, content: [
            .text("Looking."), .toolUse(id: "t1", name: "app_script", input: .object([
                "script": .string("tell application \"Notes\" to activate"),
            ])),
        ]))
        await transcript.append(Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "t1", content: [.text("ok")], isError: false),
        ]))
        await transcript.note(kind: "denied", ["tool": .string("shell"), "reason": .string("no")])

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        #expect(entries.count == 4)
        #expect(entries.map(\.sequence) == [0, 1, 2, 3])

        let text = TranscriptReport.lines(for: entries).map(\.text).joined(separator: "\n")
        #expect(text.contains("open my notes"))
        #expect(text.contains("→ app_script"))
        #expect(text.contains("tell application"))
        #expect(text.contains("[denied]"))
        #expect(text.contains("✓ ok"))
    }

    /// The session someone most wants to read is the one that died mid-write.
    @Test("A record truncated by a crash still opens")
    func truncatedRecordIsReadable() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-05T10:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"sequence":1,"timestamp":"2026-09-05T10:00:01.500Z","kind":"assistant","payl"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try TranscriptReport.entries(at: url)
        #expect(entries.count == 1, "a partial final line must not lose the whole record")
        #expect(TranscriptReport.lines(for: entries).contains { $0.text.contains("hello") })
    }

    /// A screenshot is ~180KB of base64. Printing one buries the run in the single
    /// thing the reader cannot use.
    @Test("Images are named, not printed")
    func imagesAreNotDumped() throws {
        let base64 = String(repeating: "A", count: 40_000)
        let url = try write([
            """
            {"sequence":0,"timestamp":"2026-09-05T10:00:00.000Z","kind":"user","payload":\
            {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":\
            [{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\(base64)"}}]}]}}
            """,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try TranscriptReport.lines(for: TranscriptReport.entries(at: url))
            .map(\.text).joined()
        #expect(text.contains("[image, 39KB]"))
        #expect(!text.contains("AAAAAAAAAA"), "the base64 was printed")
        #expect(text.count < 200)
    }

    @Test("Elapsed time is measured from the first entry")
    func elapsedTimeIsRelative() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-05T10:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"a"}]}}"#,
            #"{"sequence":1,"timestamp":"2026-09-05T10:00:02.250Z","kind":"assistant","payload":{"role":"assistant","content":[{"type":"text","text":"b"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = try TranscriptReport.lines(for: TranscriptReport.entries(at: url)).map(\.text)
        #expect(lines.first?.contains("0.00s") == true)
        #expect(lines.last?.contains("2.25s") == true, "got \(lines)")
    }

    /// A script's line structure is most of what makes it readable. The shared
    /// `truncated` helper flattens newlines — right for an accessibility label, wrong
    /// here — and a six-line AppleScript rendered as one run-on sentence. Found by
    /// reading a rendered session, not by a test.
    @Test("Multi-line content keeps its lines, aligned under the timestamp")
    func multiLineContentIsNotFlattened() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-05T10:00:00.000Z","kind":"assistant","payload":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"app_script","input":{"script":"line one\nline two\nline three"}}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
        #expect(lines.count == 3, "the script was flattened into \(lines.count) line(s)")
        #expect(lines[0].text.contains("0.00s"), "the stamp belongs on the first line")
        #expect(lines[1].text.contains("line two"))
        #expect(!lines[1].text.contains("0.00s"), "the stamp repeated on a continuation")
        #expect(lines[1].text.hasPrefix("      "), "continuations must align under the stamp")
    }

    /// Falling back to string interpolation printed the enum case: a turn's usage
    /// read `input_tokens=number(4200.0) session_cost_usd=number(0.027549999999999998)`.
    /// The case name, a float for a count, and fifteen digits of binary rounding on a
    /// figure in dollars — three wrong things in one field, none of which any test
    /// looked at.
    @Test("Values render as a person would write them", arguments: [
        (JSONValue.number(4200), "4200"),
        (.number(0.027549999999999998), "0.0275"),
        (.string("shell"), "shell"),
        (.bool(true), "true"),
        (.null, "null"),
        (.array([.number(1), .string("a")]), "[1, a]"),
    ])
    func valuesRenderReadably(pair: (JSONValue, String)) {
        #expect(TranscriptReport.display(pair.0) == pair.1)
    }

    /// A whole run can finish inside one second. At one decimal every entry in it
    /// reads 0.0s — which is exactly the run whose timing someone is trying to read.
    @Test("Sub-second entries are distinguishable")
    func timingHasSubSecondResolution() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-05T10:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"a"}]}}"#,
            #"{"sequence":1,"timestamp":"2026-09-05T10:00:00.040Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"b"}]}}"#,
            #"{"sequence":2,"timestamp":"2026-09-05T10:00:00.370Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"c"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let stamps = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .map { $0.text.prefix(8).trimmingCharacters(in: .whitespaces) }
        #expect(Set(stamps).count == 3, "entries collapsed to the same stamp: \(stamps)")
    }

    @Test("An empty record says so rather than rendering nothing")
    func emptyRecord() throws {
        let url = try write([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .contains { $0.text.contains("empty") })
    }

    // MARK: - What the run cost

    private func usage(_ sequence: Int, at time: String, turn: Int,
                       input: Int, cacheRead: Int, cost: Double) -> String {
        """
        {"sequence":\(sequence),"timestamp":"\(time)","kind":"usage","payload":\
        {"turn":\(turn),"input_tokens":\(input),"output_tokens":100,\
        "cache_read_tokens":\(cacheRead),"session_cost_usd":\(cost)}}
        """
    }

    /// The per-turn usage notes rendered raw, with a running cost on every line and no
    /// total anywhere — so the one question a person opens an old transcript to answer
    /// had to be answered by finding the last one and reading a float off it.
    @Test("A replayed run ends with what it cost")
    func runSummaryIsReported() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-06T09:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"go"}]}}"#,
            usage(1, at: "2026-09-06T09:00:04.000Z", turn: 0, input: 4200, cacheRead: 4100, cost: 0.0275),
            usage(2, at: "2026-09-06T09:00:42.000Z", turn: 1, input: 4600, cacheRead: 4400, cost: 0.0612),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .map(\.text).joined(separator: "\n")
        #expect(text.contains("2 turns"))
        #expect(text.contains("42.0s"))
        #expect(text.contains("$0.0612"), "the total should be the last running cost")
        #expect(!text.contains("cache hit rate"), "a warm cache needs no note")
    }

    /// The same canary the live run watches: a cold cache over several turns means
    /// something volatile reached the cached prefix and it is re-billed every turn.
    /// Two of this project's costliest defects looked exactly like this and nothing
    /// else — a replay that cannot show it cannot diagnose them either.
    @Test("A cold cache is flagged on replay")
    func coldCacheIsFlagged() throws {
        let url = try write([
            usage(0, at: "2026-09-06T09:00:00.000Z", turn: 0, input: 4200, cacheRead: 0, cost: 0.05),
            usage(1, at: "2026-09-06T09:00:20.000Z", turn: 1, input: 4200, cacheRead: 0, cost: 0.10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .map(\.text).joined(separator: "\n")
        #expect(text.contains("cache hit rate 0%"))
        #expect(text.contains("invalidated each turn"))
    }

    /// A single turn cannot show a cache trend, and warning on one would cry wolf on
    /// every short run — the first request has nothing cached to hit.
    @Test("A single turn is not flagged")
    func singleTurnIsNotFlagged() throws {
        let url = try write([
            usage(0, at: "2026-09-06T09:00:00.000Z", turn: 0, input: 4200, cacheRead: 0, cost: 0.05),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .map(\.text).joined(separator: "\n")
        #expect(text.contains("1 turn ·"))
        #expect(!text.contains("cache hit rate"))
    }

    /// A record with no usage notes at all — an interrupted run, or one that failed
    /// before its first reply — must not invent a summary.
    @Test("A run with no usage notes reports no cost")
    func noUsageNoSummary() throws {
        let url = try write([
            #"{"sequence":0,"timestamp":"2026-09-06T09:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"go"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let text = TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .map(\.text).joined(separator: "\n")
        #expect(!text.contains("turn ·"))
        #expect(!text.contains("$"))
    }

    // MARK: - Choosing between stored sessions

    private func session(in directory: URL, id: String, at time: String,
                         task: String, turns: Int, cost: Double) throws {
        var rows = ["""
            {"sequence":0,"timestamp":"\(time)","kind":"user","payload":{"role":"user",\
            "content":[{"type":"text","text":"<environment>\\ntime: x\\n</environment>\\n\\n\(task)"}]}}
            """]
        for turn in 0..<turns {
            rows.append("""
                {"sequence":\(turn + 1),"timestamp":"\(time)","kind":"usage","payload":\
                {"turn":\(turn),"input_tokens":10,"output_tokens":1,"cache_read_tokens":9,\
                "session_cost_usd":\(cost)}}
                """)
        }
        try rows.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("\(id).jsonl"),
                   atomically: true, encoding: .utf8)
    }

    /// A session is named by a UUID, so with more than one of them the only ways to
    /// find the right record were to replay the latest or to already know the id.
    /// What identifies a run to a person is what they asked for, and when.
    @Test("Sessions are listed newest first, with what was asked")
    func sessionsAreListed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "aaaa1111", at: "2026-09-06T09:00:00.000Z",
                    task: "tidy my downloads", turns: 2, cost: 0.0612)
        try session(in: directory, id: "bbbb2222", at: "2026-09-06T14:00:00.000Z",
                    task: "how many unread emails", turns: 1, cost: 0.0180)

        let listings = TranscriptReport.listings(in: directory)
        #expect(listings.count == 2)
        #expect(listings.first?.id == "bbbb2222", "newest should come first")
        #expect(listings.first?.task == "how many unread emails")
        #expect(listings.last?.turns == 2)
        #expect(listings.last?.cost == 0.0612)
    }

    /// The first user message carries the environment probe, so taking it whole
    /// labelled every session with the same six lines about the frontmost app.
    @Test("The listed task is what was asked, not the environment block")
    func listedTaskExcludesTheEnvironment() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try session(in: directory, id: "cccc3333", at: "2026-09-06T09:00:00.000Z",
                    task: "find the big files", turns: 1, cost: 0.01)

        let task = try #require(TranscriptReport.listings(in: directory).first?.task)
        #expect(task == "find the big files")
        #expect(!task.contains("environment"))
    }

    /// "1 turns" reads as a bug in the tool rather than a fact about the run.
    @Test("A single turn is not described in the plural")
    func listingIsGrammatical() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try session(in: directory, id: "dddd4444", at: "2026-09-06T09:00:00.000Z",
                    task: "one thing", turns: 1, cost: 0.01)

        let line = try #require(TranscriptReport.listings(in: directory).first?.line)
        #expect(line.contains("1 turn "))
        #expect(!line.contains("1 turns"))
    }

    @Test("An empty directory lists nothing rather than failing")
    func emptyDirectoryListsNothing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        #expect(TranscriptReport.listings(in: missing).isEmpty)
    }
}
