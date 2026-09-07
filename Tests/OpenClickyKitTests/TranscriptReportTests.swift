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
                         task: String, turns: Int, cost: Double,
                         unfulfilled: Bool? = nil,
                         trailingImages: Int = 0) throws {
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
        if let unfulfilled {
            rows.append("""
                {"sequence":\(rows.count),"timestamp":"\(time)","kind":"outcome","payload":\
                {"actions_taken":\(unfulfilled ? 0 : 2),"observations_made":1,\
                "intent":"action","stop_reason":"end_turn","unfulfilled":\(unfulfilled)}}
                """)
        }
        // Pushes the outcome note back past the first read window, so the widening
        // scan is exercised rather than assumed.
        for _ in 0..<trailingImages {
            rows.append("""
                {"sequence":\(rows.count),"timestamp":"\(time)","kind":"assistant","payload":\
                {"role":"assistant","content":[{"type":"text","text":"\(String(repeating: "x", count: 90_000))"}]}}
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

    // MARK: - Listing without reading the whole record

    /// Everything a listing needs is at one end of the file. Decoding all of it cost
    /// 0.15s per session, because a run that takes screenshots stores each as ~240KB
    /// of base64 — a hundred sessions would have been fifteen seconds to print a
    /// hundred lines. This asserts the fast path agrees with a full parse, which is
    /// the only thing that makes it safe.
    @Test("A listing matches what a full parse would say", arguments: [0, 1, 3])
    func listingAgreesWithFullParse(trailingImages: Int) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = String(repeating: "A", count: 240_000)
        var rows = [#"{"sequence":0,"timestamp":"2026-09-06T09:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"find the big files"}]}}"#]
        for turn in 0..<5 {
            rows.append("""
                {"sequence":\(rows.count),"timestamp":"2026-09-06T09:00:0\(turn).000Z",\
                "kind":"user","payload":{"role":"user","content":[{"type":"tool_result",\
                "tool_use_id":"t\(turn)","content":[{"type":"image","source":{"type":"base64",\
                "media_type":"image/jpeg","data":"\(image)"}}]}]}}
                """)
            rows.append("""
                {"sequence":\(rows.count),"timestamp":"2026-09-06T09:00:0\(turn).500Z",\
                "kind":"usage","payload":{"turn":\(turn),"input_tokens":4200,\
                "output_tokens":150,"cache_read_tokens":4100,"session_cost_usd":\(0.02 * Double(turn + 1))}}
                """)
        }
        // Images after the last usage entry force the tail window to widen; without
        // that, the cost and turn count would silently come back empty.
        for extra in 0..<trailingImages {
            rows.append("""
                {"sequence":\(rows.count),"timestamp":"2026-09-06T09:00:59.000Z",\
                "kind":"user","payload":{"role":"user","content":[{"type":"tool_result",\
                "tool_use_id":"x\(extra)","content":[{"type":"image","source":{"type":"base64",\
                "media_type":"image/jpeg","data":"\(image)"}}]}]}}
                """)
        }
        let url = directory.appendingPathComponent("aaaa1111.jsonl")
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        let entries = try TranscriptReport.entries(at: url)
        let usage = entries.filter { $0.kind == "usage" }

        #expect(listing.turns == usage.count, "turn count disagrees with a full parse")
        #expect(listing.cost == usage.last?.payload["session_cost_usd"]?.doubleValue)
        #expect(listing.task == "find the big files")
        #expect(listing.started == entries.first?.timestamp)
    }

    /// A record with no usage entries at all — an interrupted run — must list rather
    /// than vanish, since it is often the one worth reading.
    @Test("A session with no usage entries still lists")
    func sessionWithoutUsageStillLists() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"sequence":0,"timestamp":"2026-09-06T09:00:00.000Z","kind":"user","payload":{"role":"user","content":[{"type":"text","text":"stopped early"}]}}"#
            .write(to: directory.appendingPathComponent("bbbb2222.jsonl"),
                   atomically: true, encoding: .utf8)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.turns == 0)
        #expect(listing.cost == nil)
        #expect(listing.task == "stopped early")
    }

    // MARK: - Choosing what to forget

    private func dated(_ directory: URL, id: String, daysAgo: Int, now: Date) throws {
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .format(now.addingTimeInterval(-Double(daysAgo) * 86_400))
        try """
            {"sequence":0,"timestamp":"\(stamp)","kind":"user","payload":{"role":"user",\
            "content":[{"type":"text","text":"session \(id)"}]}}
            """.write(to: directory.appendingPathComponent("\(id).jsonl"),
                      atomically: true, encoding: .utf8)
    }

    /// `doctor` reported that records accumulate and are never pruned while offering
    /// no way to act on it. Selection is separate from deletion so a caller can show
    /// exactly what it is about to remove — deleting someone's screenshots is their
    /// decision, and the tool's job is to make it possible, not to make it.
    @Test("Only sessions older than the cutoff are selected")
    func selectsOnlyOldSessions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        try dated(directory, id: "ancient", daysAgo: 90, now: now)
        try dated(directory, id: "old", daysAgo: 31, now: now)
        try dated(directory, id: "recent", daysAgo: 2, now: now)

        let doomed = TranscriptReport.listings(in: directory, olderThan: 30, now: now)
        #expect(doomed.map(\.id) == ["ancient", "old"], "oldest first, and nothing recent")
    }

    /// A cutoff nothing meets must select nothing rather than everything — the
    /// direction of that mistake is the difference between a no-op and data loss.
    @Test("A cutoff nothing meets selects nothing")
    func selectsNothingWhenAllAreRecent() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        try dated(directory, id: "yesterday", daysAgo: 1, now: now)
        #expect(TranscriptReport.listings(in: directory, olderThan: 30, now: now).isEmpty)
    }

    /// `forget 0` means everything, and must mean it explicitly rather than by
    /// accident — it is the one cutoff that selects a record written moments ago.
    @Test("A zero cutoff selects everything")
    func zeroCutoffSelectsEverything() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        try dated(directory, id: "just-now", daysAgo: 0, now: now)
        #expect(TranscriptReport.listings(in: directory, olderThan: 0, now: now).count == 1)
    }

    // MARK: - The verdict in the record

    // The completion guard says "nothing was done" on a terminal that scrolls away.
    // The record is what remains, and a listing that cannot tell a run which did the
    // work from one which explained why it could not is the same failure one layer out.

    @Test("A run that changed nothing is marked in the listing")
    func listingMarksAnUnfulfilledRun() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "dddd4444", at: "2026-09-06T09:00:00.000Z",
                    task: "format the markdown", turns: 2, cost: 0.01, unfulfilled: true)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.unfulfilled == true)
        #expect(listing.line.contains("did nothing"))
    }

    @Test("A run that did the work is not marked")
    func listingLeavesAFulfilledRunUnmarked() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "eeee5555", at: "2026-09-06T09:00:00.000Z",
                    task: "open spotify", turns: 2, cost: 0.01, unfulfilled: false)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.unfulfilled == false)
        #expect(!listing.line.contains("did nothing"))
    }

    @Test("A session recorded before outcomes existed claims nothing either way")
    func listingLeavesAHistoricalRunUndecided() throws {
        // Absent and negative are different claims. Defaulting a missing verdict to
        // `false` would relabel every run recorded before this existed as successful,
        // which is the precise error the guard was written to stop.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "ffff6666", at: "2026-09-06T09:00:00.000Z",
                    task: "open spotify", turns: 2, cost: 0.01)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.unfulfilled == nil)
        #expect(!listing.line.contains("did nothing"))
    }

    @Test("The verdict is found even behind a large trailing entry")
    func listingFindsTheVerdictPastTheFirstWindow() throws {
        // The backwards scan reads a 64KB window first. A run that ends with a
        // screenshot puts ~240KB between the outcome note and the end of the file, so
        // a single short read would miss it and the run would silently read as
        // historical rather than as one that did nothing.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "aaaa7777", at: "2026-09-06T09:00:00.000Z",
                    task: "format the markdown", turns: 1, cost: 0.01,
                    unfulfilled: true, trailingImages: 2)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.unfulfilled == true)
    }

    @Test("The task is found even when notes precede it in the record")
    func listingFindsTheTaskPastLeadingNotes() throws {
        // A run writes a `run` note describing its configuration before anything else,
        // and may write a `plan` note after that. Reading line one and asking it for a
        // task labelled every session "(no task recorded)" the moment the
        // configuration note was added — caught by the end-to-end test.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let time = "2026-09-06T09:00:00.000Z"
        let probe = "<environment>\\ntime: x\\n</environment>\\n\\ntidy my downloads"
        let rows = [
            """
            {"sequence":0,"timestamp":"\(time)","kind":"run","payload":\
            {"model":"claude-haiku-4-5","mode":"ask"}}
            """,
            """
            {"sequence":1,"timestamp":"\(time)","kind":"plan","payload":\
            {"model":"claude-opus-5","plan":"1. do it"}}
            """,
            """
            {"sequence":2,"timestamp":"\(time)","kind":"user","payload":{"role":"user",\
            "content":[{"type":"text","text":"\(probe)"}]}}
            """,
            """
            {"sequence":3,"timestamp":"\(time)","kind":"usage","payload":\
            {"turn":0,"input_tokens":10,"output_tokens":1,"cache_read_tokens":9,\
            "session_cost_usd":0.01}}
            """,
        ]
        try rows.joined(separator: "\n").write(
            to: directory.appendingPathComponent("bbbb9999.jsonl"),
            atomically: true, encoding: .utf8
        )

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.task == "tidy my downloads")
        #expect(listing.turns == 1)
    }


    @Test("A run that died is listed with its cause, not as a blank session")
    func listingShowsTheFailure() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let time = "2026-09-07T00:23:14.000Z"
        let probe = "<environment>\\ntime: x\\n</environment>\\n\\nhow many files are in /tmp"
        let rows = [
            """
            {"sequence":0,"timestamp":"\(time)","kind":"user","payload":{"role":"user",\
            "content":[{"type":"text","text":"\(probe)"}]}}
            """,
            """
            {"sequence":1,"timestamp":"\(time)","kind":"failed","payload":\
            {"reason":"Refused: does not support tools","actions_taken":0}}
            """,
        ]
        try rows.joined(separator: "\n").write(
            to: directory.appendingPathComponent("cccc1111.jsonl"),
            atomically: true, encoding: .utf8
        )

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.failure == "Refused: does not support tools")
        #expect(listing.line.contains("does not support tools"))
        // The task still reads, so the row identifies which run died.
        #expect(listing.task == "how many files are in /tmp")
    }

    @Test("A failure outranks the did-nothing verdict")
    func failureOutranksUnfulfilled() throws {
        // A run that threw never reached a completion verdict. Showing "did nothing"
        // describes the symptom while hiding the cause.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try session(in: directory, id: "dddd2222", at: "2026-09-07T00:23:14.000Z",
                    task: "do the thing", turns: 1, cost: 0.01, unfulfilled: true)
        let url = directory.appendingPathComponent("dddd2222.jsonl")
        let existing = try String(contentsOf: url, encoding: .utf8)
        try (existing + "\n" + """
            {"sequence":99,"timestamp":"2026-09-07T00:23:14.000Z","kind":"failed",\
            "payload":{"reason":"connection refused","actions_taken":0}}
            """).write(to: url, atomically: true, encoding: .utf8)

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.line.contains("connection refused"))
        #expect(!listing.line.contains("did nothing"))
    }

}
