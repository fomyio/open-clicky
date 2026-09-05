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
        #expect(lines.first?.contains("0.0s") == true)
        #expect(lines.last?.contains("2.2s") == true, "got \(lines)")
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
        #expect(lines[0].text.contains("0.0s"), "the stamp belongs on the first line")
        #expect(lines[1].text.contains("line two"))
        #expect(!lines[1].text.contains("0.0s"), "the stamp repeated on a continuation")
        #expect(lines[1].text.hasPrefix("      "), "continuations must align under the stamp")
    }

    @Test("An empty record says so rather than rendering nothing")
    func emptyRecord() throws {
        let url = try write([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptReport.lines(for: try TranscriptReport.entries(at: url))
            .contains { $0.text.contains("empty") })
    }
}
