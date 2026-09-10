import Testing
import Foundation
@testable import OpenClickyKit

/// Screenshot pruning is the main cost lever in a long computer-use session, and
/// getting it wrong breaks the request rather than merely costing money: dropping
/// a `tool_result` orphans its `tool_use` and the API rejects the whole message.
@Suite("Transcript pruning", .serialized)
struct TranscriptTests {

    private func makeTranscript() throws -> (Transcript, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-transcript-\(UUID().uuidString)")
        return (try Transcript(directory: directory), directory)
    }

    /// One screenshot turn: the assistant asks, the user message carries the image back.
    private func screenshotExchange(id: String) -> [Wire.Message] {
        [
            Wire.Message(role: .assistant, content: [
                .toolUse(id: id, name: "screenshot", input: .object([:])),
            ]),
            Wire.Message(role: .user, content: [
                .toolResult(
                    toolUseID: id,
                    content: [.text("Screenshot: 1920×803"), .image(mediaType: "image/jpeg", base64: "IMG-\(id)")],
                    isError: false
                ),
            ]),
        ]
    }

    private func imageCount(_ messages: [Wire.Message]) -> Int {
        messages.reduce(0) { total, message in
            total + message.content.reduce(0) { inner, block in
                guard case let .toolResult(_, content, _) = block else { return inner }
                return inner + content.filter(\.isImage).count
            }
        }
    }

    private func toolUseIDs(_ messages: [Wire.Message]) -> Set<String> {
        Set(messages.flatMap { $0.content.compactMap {
            if case let .toolUse(id, _, _) = $0 { return id }
            return nil
        }})
    }

    private func toolResultIDs(_ messages: [Wire.Message]) -> Set<String> {
        Set(messages.flatMap { $0.content.compactMap {
            if case let .toolResult(id, _, _) = $0 { return id }
            return nil
        }})
    }

    @Test("Only the most recent screenshots survive")
    func prunesOlderImages() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("look at my screen"))
        for index in 1...5 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }

        #expect(imageCount(await transcript.conversation) == 5)
        #expect(imageCount(await transcript.conversation(keepingRecentImages: 2)) == 2)
        #expect(imageCount(await transcript.conversation(keepingRecentImages: 0)) == 0)
    }

    @Test("The images kept are the newest ones")
    func keepsTheNewestImages() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...4 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }

        let surviving = await transcript.conversation(keepingRecentImages: 2)
            .flatMap { $0.content }
            .compactMap { block -> [Wire.ToolResultContent]? in
                guard case let .toolResult(_, content, _) = block else { return nil }
                return content
            }
            .flatMap { $0 }
            .compactMap { block -> String? in
                guard case let .image(_, base64) = block else { return nil }
                return base64
            }

        #expect(surviving == ["IMG-toolu_3", "IMG-toolu_4"])
    }

    /// The failure that would take the whole request down with a 400.
    @Test("Pruning never orphans a tool_use")
    func preservesToolUsePairing() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...4 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }

        let pruned = await transcript.conversation(keepingRecentImages: 1)
        #expect(toolUseIDs(pruned) == toolResultIDs(pruned))
        #expect(toolUseIDs(pruned).count == 4, "every exchange must keep both halves")
    }

    @Test("An elided image leaves a note telling the model to look again")
    func elidedImageLeavesGuidance() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...2 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }

        let pruned = await transcript.conversation(keepingRecentImages: 1)
        let text = pruned.flatMap { $0.content }.compactMap { block -> String? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }
                .joined(separator: " ")
        }.joined(separator: " ")

        #expect(text.contains("take a new screenshot"))
    }

    @Test("Text-only conversations are untouched")
    func leavesTextAlone() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("how much disk space is left?"))
        await transcript.append(Wire.Message(role: .assistant, content: [
            .toolUse(id: "toolu_1", name: "shell", input: .object(["command": .string("df -h")])),
        ]))
        await transcript.append(Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "toolu_1", content: [.text("120Gi available")], isError: false),
        ]))

        #expect(await transcript.conversation(keepingRecentImages: 0) == transcript.conversation)
    }

    @Test("Pruning is measurably cheaper on a long session")
    func prunedConversationIsSubstantiallySmaller() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...12 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }

        func tokens(_ messages: [Wire.Message]) -> Int {
            messages.reduce(0) { total, message in
                total + message.content.reduce(0) { inner, block in
                    guard case let .toolResult(_, content, _) = block else { return inner }
                    return inner + content.reduce(0) { $0 + $1.estimatedTokens }
                }
            }
        }

        let full = tokens(await transcript.conversation)
        let pruned = tokens(await transcript.conversation(keepingRecentImages: 2))
        #expect(full > 17_000, "12 screenshots should cost ~18k tokens unpruned")
        #expect(pruned < 4_000)
    }

    // MARK: - Stale text results

    private func textExchange(id: String, result: String, isError: Bool = false) -> [Wire.Message] {
        [
            Wire.Message(role: .assistant, content: [
                .toolUse(id: id, name: "shell", input: .object([:])),
            ]),
            Wire.Message(role: .user, content: [
                .toolResult(toolUseID: id, content: [.text(result)], isError: isError),
            ]),
        ]
    }

    private func resultTexts(_ messages: [Wire.Message]) -> [String] {
        messages.flatMap { $0.content }.compactMap { block in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }
                .joined(separator: "\n")
        }
    }

    @Test("Old bulky results are abbreviated, recent ones are not")
    func abbreviatesStaleResults() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Ten results, each far over the stale budget.
        for index in 1...10 {
            let body = "LINE-\(index)-" + String(repeating: "x", count: 3_000) + "-END-\(index)"
            for message in textExchange(id: "toolu_\(index)", result: body) {
                await transcript.append(message)
            }
        }

        let policy = Transcript.ContextPolicy(
            keepRecentImages: 2, keepRecentFullResults: 3, staleResultBudget: 400
        )
        let texts = resultTexts(await transcript.conversation(policy: policy))
        #expect(texts.count == 10)

        // The three newest survive whole.
        #expect(texts.suffix(3).allSatisfy { $0.count > 3_000 })
        // The seven older ones are cut to roughly the budget plus the note.
        #expect(texts.prefix(7).allSatisfy { $0.count < 1_000 })
    }

    /// A head-only cut loses the conclusion, which for command output is usually
    /// the part that matters.
    @Test("Abbreviation keeps both the head and the tail")
    func abbreviationKeepsBothEnds() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        let body = "HEAD-MARKER" + String(repeating: "-", count: 5_000) + "TAIL-MARKER"
        for index in 1...5 {
            for message in textExchange(id: "toolu_\(index)", result: index == 1 ? body : "small") {
                await transcript.append(message)
            }
        }

        let policy = Transcript.ContextPolicy(keepRecentFullResults: 1, staleResultBudget: 200)
        let first = try #require(resultTexts(await transcript.conversation(policy: policy)).first)
        #expect(first.contains("HEAD-MARKER"))
        #expect(first.contains("TAIL-MARKER"))
        #expect(first.contains("elided"))
    }

    /// An error is what the model needs to correct itself, and is short anyway.
    @Test("Error results are never abbreviated")
    func errorsSurviveIntact() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        let failure = "FAILURE-DETAIL " + String(repeating: "e", count: 3_000)
        for message in textExchange(id: "toolu_err", result: failure, isError: true) {
            await transcript.append(message)
        }
        for index in 1...8 {
            for message in textExchange(id: "toolu_\(index)", result: "later") {
                await transcript.append(message)
            }
        }

        let policy = Transcript.ContextPolicy(keepRecentFullResults: 2, staleResultBudget: 100)
        let first = try #require(resultTexts(await transcript.conversation(policy: policy)).first)
        #expect(first == failure, "an error result must reach the model in full")
    }

    @Test("Results already under budget are left alone")
    func shortResultsUntouched() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...8 {
            for message in textExchange(id: "toolu_\(index)", result: "short output \(index)") {
                await transcript.append(message)
            }
        }
        let policy = Transcript.ContextPolicy(keepRecentFullResults: 1, staleResultBudget: 400)
        let texts = resultTexts(await transcript.conversation(policy: policy))
        #expect(texts == (1...8).map { "short output \($0)" })
    }

    @Test("Abbreviation never orphans a tool_use")
    func abbreviationPreservesPairing() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...6 {
            let body = String(repeating: "y", count: 5_000)
            for message in textExchange(id: "toolu_\(index)", result: body) {
                await transcript.append(message)
            }
        }
        let pruned = await transcript.conversation(
            policy: Transcript.ContextPolicy(keepRecentFullResults: 1, staleResultBudget: 100)
        )
        #expect(toolUseIDs(pruned) == toolResultIDs(pruned))
        #expect(toolUseIDs(pruned).count == 6)
    }

    @Test("The unpruned policy sends the history untouched")
    func unprunedPolicyIsIdentity() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...4 {
            for message in screenshotExchange(id: "img_\(index)") { await transcript.append(message) }
            for message in textExchange(id: "txt_\(index)", result: String(repeating: "z", count: 4_000)) {
                await transcript.append(message)
            }
        }
        #expect(await transcript.conversation(policy: .unpruned) == transcript.conversation)
    }

    /// Both levers together on a session that mixes screenshots and bulky dumps.
    @Test("A long mixed session is substantially cheaper under the default policy")
    func defaultPolicyCutsALongSession() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...10 {
            for message in screenshotExchange(id: "img_\(index)") { await transcript.append(message) }
            // An accessibility dump of a busy window is a few thousand tokens.
            for message in textExchange(id: "ax_\(index)", result: String(repeating: "node ", count: 3_000)) {
                await transcript.append(message)
            }
        }

        func tokens(_ messages: [Wire.Message]) -> Int {
            messages.flatMap { $0.content }.reduce(0) { total, block in
                guard case let .toolResult(_, content, _) = block else { return total }
                return total + content.reduce(0) { $0 + $1.estimatedTokens }
            }
        }

        let full = tokens(await transcript.conversation)
        let pruned = tokens(await transcript.conversation(policy: .default))
        #expect(full > 45_000)
        #expect(Double(pruned) < Double(full) * 0.35, "the default policy should cut most of it")
    }

    /// The handle is held open for the session, so every entry must still be on disk
    /// as it is written — a crash mid-session should not lose the record of what the
    /// agent did before it.
    @Test("Entries are readable from disk as soon as they are written")
    func entriesAreFlushedImmediately() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("first"))
        let afterFirst = try String(contentsOfFile: await transcript.path, encoding: .utf8)
        #expect(afterFirst.contains("first"))

        await transcript.note(kind: "usage", ["turn": .number(1)])
        let afterNote = try String(contentsOfFile: await transcript.path, encoding: .utf8)
        #expect(afterNote.contains("usage"))
        #expect(afterNote.contains("first"), "earlier entries survive later writes")

        // One JSON object per line, still parseable.
        let lines = afterNote.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            #expect((try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) != nil)
        }
    }

    @Test("Two transcripts in the same directory do not interleave")
    func concurrentTranscriptsAreIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-parallel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try Transcript(directory: directory)
        let second = try Transcript(directory: directory)
        await first.append(.user("alpha"))
        await second.append(.user("beta"))

        let firstText = try String(contentsOfFile: await first.path, encoding: .utf8)
        let secondText = try String(contentsOfFile: await second.path, encoding: .utf8)
        #expect(firstText.contains("alpha") && !firstText.contains("beta"))
        #expect(secondText.contains("beta") && !secondText.contains("alpha"))
    }

    // MARK: - Long sessions

    /// The claim behind all the pruning is that a long session does not grow without
    /// bound. Asserted here as a property rather than observed once: over 40 turns of
    /// screenshots and accessibility dumps, the unpruned conversation grows linearly
    /// while what is actually sent plateaus.
    @Test("Context stays bounded across a long session")
    func contextDoesNotGrowLinearly() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Sized like the real thing: a downscaled JPEG is around 45KB of base64, and
        // an accessibility dump of a busy window a few thousand characters.
        let image = String(repeating: "A", count: 45_000)
        let dump = String(repeating: "node line here ", count: 300)

        func encodedSize(_ messages: [Wire.Message]) throws -> Int {
            try JSONEncoder().encode(messages).count
        }

        var sentAtTurn: [Int: Int] = [:]
        var fullAtTurn: [Int: Int] = [:]

        for turn in 1...40 {
            await transcript.append(Wire.Message(role: .assistant, content: [
                .toolUse(id: "shot\(turn)", name: "screenshot", input: .object([:])),
                .toolUse(id: "ax\(turn)", name: "ax_capture", input: .object([:])),
            ]))
            await transcript.append(Wire.Message(role: .user, content: [
                .toolResult(toolUseID: "shot\(turn)",
                            content: [.image(mediaType: "image/jpeg", base64: image)], isError: false),
                .toolResult(toolUseID: "ax\(turn)", content: [.text(dump)], isError: false),
            ]))

            if [8, 40].contains(turn) {
                sentAtTurn[turn] = try encodedSize(await transcript.conversation(policy: .default))
                fullAtTurn[turn] = try encodedSize(await transcript.conversation)
            }
        }

        let fullGrowth = Double(fullAtTurn[40]!) / Double(fullAtTurn[8]!)
        let sentGrowth = Double(sentAtTurn[40]!) / Double(sentAtTurn[8]!)

        // Five times the turns, so an unpruned conversation grows about fivefold.
        #expect(fullGrowth > 4.0, "the unpruned conversation should grow with the session")
        // What is sent must not. The residual growth is the elision notes left in
        // place of stale results, which is a fixed small cost per turn.
        #expect(sentGrowth < 1.5, "sent context grew \(sentGrowth)x between turn 8 and 40")

        // And in absolute terms it stays a small fraction of the window.
        #expect(sentAtTurn[40]! < 250_000, "turn 40 sent \(sentAtTurn[40]! / 1024)KB")
        #expect(sentAtTurn[40]! < fullAtTurn[40]! / 10, "pruning should remove most of it")
    }

    /// Whatever else is trimmed, the two most recent screenshots survive — they are
    /// what a before-and-after comparison needs.
    @Test("A long session still carries its most recent images")
    func recentImagesSurviveALongSession() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for turn in 1...30 {
            for message in screenshotExchange(id: "toolu_\(turn)") {
                await transcript.append(message)
            }
        }

        let sent = await transcript.conversation(policy: .default)
        let images = sent.flatMap(\.content).compactMap { block -> [Wire.ToolResultContent]? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content
        }.flatMap { $0 }.compactMap { block -> String? in
            guard case let .image(_, base64) = block else { return nil }
            return base64
        }

        #expect(images == ["IMG-toolu_29", "IMG-toolu_30"], "the newest two, in order")
    }

    /// A transcript holds command output, file contents and base64 screenshots in
    /// full, and is never pruned on disk. The default umask would make it 0644, and
    /// every local macOS account is in `staff` — so on a shared machine another user
    /// could read it. Fixed once and never tested until a mutation walked past it.
    @Test("Transcripts are readable only by their owner")
    func transcriptsArePrivate() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }
        await transcript.append(.user("something private"))

        let fileMode = try FileManager.default
            .attributesOfItem(atPath: await transcript.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber

        #expect(fileMode?.intValue == 0o600,
                "transcript is \(String(fileMode?.intValue ?? 0, radix: 8))")
        #expect(directoryMode?.intValue == 0o700,
                "session directory is \(String(directoryMode?.intValue ?? 0, radix: 8))")

        // Specifically: nothing for group or other, whatever the umask happens to be.
        #expect((fileMode?.intValue ?? 0) & 0o077 == 0, "group or other can read it")
        #expect((directoryMode?.intValue ?? 0) & 0o077 == 0, "the directory is traversable")
    }

    /// The transcript exists to reconstruct what happened. Reading one showed every
    /// entry in a run carrying the identical timestamp — ISO8601 resolves to
    /// milliseconds at best, and several entries a turn are written inside one. So
    /// the record could not order its own contents.
    @Test("Entries carry a gapless order independent of the clock")
    func entriesAreOrdered() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("a task"))
        for turn in 0..<5 {
            await transcript.note(kind: "usage", ["turn": .number(Double(turn))])
        }

        let lines = try String(contentsOfFile: await transcript.path, encoding: .utf8)
            .split(separator: "\n")
        let entries = try lines.map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }

        let sequences = entries.compactMap { $0["sequence"]?.intValue }
        #expect(sequences == Array(0..<entries.count), "sequence was \(sequences)")

        // The point of the field: the clock cannot separate these.
        let timestamps = Set(entries.compactMap { $0["timestamp"]?.stringValue })
        #expect(timestamps.count < entries.count,
                "timestamps happened to be distinct; the ordering must not rely on that")
    }

    @Test("Timestamps carry sub-second precision")
    func timestampsHaveFractionalSeconds() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }
        await transcript.note(kind: "usage", ["turn": .number(0)])

        let line = try String(contentsOfFile: await transcript.path, encoding: .utf8)
            .split(separator: "\n").first
        let entry = try JSONDecoder().decode(
            JSONValue.self, from: Data(String(try #require(line)).utf8)
        )
        let timestamp = try #require(entry["timestamp"]?.stringValue)

        #expect(timestamp.contains("."), "no fractional seconds in \(timestamp)")
        #expect(timestamp.hasSuffix("Z"), "not UTC: \(timestamp)")
    }

    @Test("The on-disk record keeps every image, whatever is sent")
    func jsonlRetainsFullHistory() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...3 {
            for message in screenshotExchange(id: "toolu_\(index)") {
                await transcript.append(message)
            }
        }
        _ = await transcript.conversation(keepingRecentImages: 1)

        let contents = try String(contentsOfFile: await transcript.path, encoding: .utf8)
        for index in 1...3 {
            #expect(contents.contains("IMG-toolu_\(index)"), "the transcript is the full record")
        }
    }

    // MARK: - What the records cost

    /// A run that takes screenshots writes them to the record in full, so a busy
    /// session is measured in megabytes, and nothing prunes the directory. That is a
    /// defensible trade — the record exists to reconstruct what happened — but it was
    /// invisible: no command reported it, so the only way to discover a tool growing
    /// on your disk indefinitely was to go looking.
    @Test("Storage reports what the sessions actually occupy")
    func storageReportsSessions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Transcript.storage(in: directory).sessions == 0)

        for name in ["a", "b", "c"] {
            try Data(repeating: 0x41, count: 1_000)
                .write(to: directory.appendingPathComponent("\(name).jsonl"))
        }
        // Not a session record, and must not be counted as one.
        try Data("note".utf8).write(to: directory.appendingPathComponent("README.txt"))

        let storage = Transcript.storage(in: directory)
        #expect(storage.sessions == 3)
        #expect(storage.bytes == 3_000)
        #expect(storage.oldest != nil)
        #expect(storage.summary.contains("3 sessions"))
    }

    /// ByteCountFormatter renders zero as "Zero KB" by default, so a fresh install
    /// reported "1 session, Zero KB" — which reads as a broken number, not a size.
    @Test("An empty record reports a number, not a word")
    func storageSummaryUsesDigits() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("empty.jsonl").path, contents: Data()
        )

        let summary = Transcript.storage(in: directory).summary
        #expect(!summary.lowercased().contains("zero"), "got \(summary)")
        #expect(summary.contains("0"), "got \(summary)")
    }

    @Test("An absent directory reports nothing rather than failing")
    func storageHandlesMissingDirectory() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let storage = Transcript.storage(in: missing)
        #expect(storage.sessions == 0)
        #expect(storage.bytes == 0)
        #expect(storage.oldest == nil)
    }

    @Test("A single session is not described in the plural")
    func storageSummaryIsGrammatical() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("x".utf8).write(to: directory.appendingPathComponent("one.jsonl"))
        #expect(Transcript.storage(in: directory).summary.contains("1 session,"))
    }

    /// The reader and the writer must not disagree about where sessions live.
    ///
    /// Checked without constructing a default transcript: doing that wrote a real
    /// session file into the user's home directory on every test run, which is both
    /// litter and a test that depends on — and mutates — state outside itself.
    @Test("A transcript is written where storage looks for it")
    func defaultDirectoryIsShared() async throws {
        // The writer's side: a transcript lands inside the directory it was given.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let transcript = try Transcript(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = await transcript.path
        #expect(path.hasPrefix(directory.path))

        // The reader's side: with no directory named, storage reads the same default.
        #expect(Transcript.storage().directory == Transcript.defaultDirectory)
        #expect(Transcript.defaultDirectory.path.hasSuffix(".openclicky/sessions"))
    }

    /// Swift seeds its dictionary ordering per process, so without sorted keys an
    /// entry's fields came out in a different order on every line. The reader's tail
    /// search inspects a short prefix to find `"kind":"usage"` without decoding the
    /// ~240KB images beside it, and `kind` sometimes landed outside that prefix — so
    /// the same file reported 0, 1 or 2 turns depending on the run. A flaky answer is
    /// worse than a wrong one: it looks like a passing test most of the time.
    ///
    /// Which is exactly the trap this test fell into itself. It used to assert only
    /// that each line begins `{"kind":`, and an unsorted encoder puts `kind` first by
    /// chance roughly one process in four — so with `.sortedKeys` removed it passed
    /// 7 runs in 20 of the same binary, and the mutation sweep reported the invariant
    /// undefended at random. Asserting the whole entry ascends, nested keys included,
    /// leaves one arrangement in 4! × 6! that could pass by luck.
    @Test("Every entry writes its keys in the same order")
    func entriesAreWrittenDeterministically() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("hello"))
        // Six payload keys, alphabetical by construction, so their sorted order is
        // unambiguous and reading it back cannot be confused with a lucky shuffle.
        await transcript.note(kind: "usage", [
            "alpha": .number(0), "bravo": .number(1), "charlie": .number(2),
            "delta": .number(3), "echo": .number(4), "foxtrot": .number(5),
        ])
        await transcript.append(Wire.Message(role: .assistant, content: [.text("done")]))

        let lines = try String(contentsOfFile: await transcript.path, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            // `kind` first is what the tail search depends on, and it is the cheapest
            // thing to say about the line — but on its own it is a coin toss.
            #expect(line.hasPrefix(#"{"kind":"#),
                    "keys are not in a stable order: \(line.prefix(60))")
            #expect(Self.keysAscend([#""kind":"#, #""payload":"#, #""sequence":"#, #""timestamp":"#], in: line),
                    "top-level keys are not sorted: \(line.prefix(80))")
        }
        #expect(Self.keysAscend(
            [#""alpha":"#, #""bravo":"#, #""charlie":"#, #""delta":"#, #""echo":"#, #""foxtrot":"#],
            in: lines[1]
        ), "keys nested in the payload are not sorted: \(lines[1].prefix(120))")
    }

    /// Whether `markers` occur in this order, each after the last. Position rather than
    /// equality, so the assertion stays about ordering and says nothing about the
    /// values between them.
    private static func keysAscend(_ markers: [String], in line: Substring) -> Bool {
        var cursor = line.startIndex
        for marker in markers {
            guard let found = line.range(of: marker, range: cursor..<line.endIndex) else {
                return false
            }
            cursor = found.upperBound
        }
        return true
    }

    /// The property the ordering protects: a listing finds the usage entry however
    /// large the entries around it are.
    @Test("A usage entry is found next to a large one")
    func usageIsFoundBesideLargeEntries() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        await transcript.append(.user("find the big ones"))
        await transcript.note(kind: "usage", ["turn": .number(0), "session_cost_usd": .number(0.02)])
        // A screenshot-sized entry after the usage note, which is what pushed the
        // tail search past it.
        await transcript.append(Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "t1", content: [
                .image(mediaType: "image/jpeg", base64: String(repeating: "A", count: 240_000)),
            ], isError: false),
        ]))

        let listing = try #require(TranscriptReport.listings(in: directory).first)
        #expect(listing.turns == 1)
        #expect(listing.cost == 0.02)
    }

    // MARK: - Byte stability, for the prompt cache

    /// The defect `compacted` and `settledThrough` exist to prevent, and the only one
    /// here that nothing else in the system would notice.
    ///
    /// Pruning is retroactive: `conversation(policy:)` measures its windows backwards
    /// from the newest message, so a screenshot intact on turn two is elided on turn
    /// four — rewriting bytes the model was already sent. Prompt caching matches on a
    /// *prefix*, so a block edited behind a breakpoint invalidates it and every turn
    /// re-bills the whole history at full price. The request stays correct throughout;
    /// only the bill moves, which is why this is asserted here and nowhere else.
    ///
    /// The claim is therefore about the *settled* region, not the whole array: the
    /// unsettled tail is still liable to be rewritten, and that is exactly why no
    /// breakpoint that has to hit is placed in it.
    @Test("The settled region never changes once it has been sent")
    func settledHistoryIsAppendOnly() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        let policy = Transcript.ContextPolicy(keepRecentImages: 1, keepRecentFullResults: 2,
                                              staleResultBudget: 40)
        var previous: [Wire.Message] = []
        var compared = 0
        for index in 0..<8 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
            let sent = await transcript.compacted(policy: policy)
            // Only what was settled *and* already sent can be compared: the frontier
            // is behind the newest turn by construction.
            let common = min(sent.settledThrough, previous.count)
            compared = max(compared, common)
            #expect(Array(sent.messages.prefix(common)) == Array(previous.prefix(common)),
                    "turn \(index) rewrote settled history the previous request had sent")
            previous = sent.messages
        }
        #expect(previous.count == 16)
        #expect(compared > 0, "nothing was ever both settled and previously sent")
    }

    /// The same claim at the level that actually bills: identical bytes, not merely
    /// equal values. `Wire.Message` compares content and ignores the breakpoint, so an
    /// equality check alone could pass while the serialised prefix moved.
    @Test("The settled prefix is byte-identical from one turn to the next")
    func settledPrefixIsByteStable() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        let policy = Transcript.ContextPolicy(keepRecentImages: 1, keepRecentFullResults: 2,
                                              staleResultBudget: 40)
        var previousBytes: [Data] = []
        var sawASettledPrefix = false
        for index in 0..<8 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
            let sent = await transcript.compacted(policy: policy)
            let bytes = try sent.messages.map { try Wire.encoder.encode($0) }
            let settled = min(sent.settledThrough, previousBytes.count)
            if settled > 0 { sawASettledPrefix = true }
            #expect(Array(bytes.prefix(settled)) == Array(previousBytes.prefix(settled)),
                    "turn \(index) changed the bytes of a settled message")
            previousBytes = bytes
        }
        #expect(sawASettledPrefix, "nothing ever settled, so the assertion above proved nothing")
    }

    /// The frontier has to actually advance, or the "settled" region is a permanently
    /// empty set that every assertion about it passes vacuously.
    @Test("The settled frontier grows as the conversation does")
    func settledFrontierAdvances() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        let policy = Transcript.ContextPolicy(keepRecentImages: 1, keepRecentFullResults: 2,
                                              staleResultBudget: 400)
        var frontiers: [Int] = []
        for index in 0..<6 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
            frontiers.append(await transcript.compacted(policy: policy).settledThrough)
        }
        #expect(frontiers == frontiers.sorted(), "the frontier went backwards")
        #expect(frontiers.first == 0, "nothing can be settled before anything has aged out")
        #expect(try #require(frontiers.last) > 0, "nothing ever settled")
    }

    /// A policy that prunes nothing has no mechanism that could rewrite a message, so
    /// the whole history is cacheable. Falling through to zero here would turn caching
    /// off for the runs least able to afford it.
    @Test("An unpruned policy settles the whole conversation at once")
    func unprunedSettlesEverything() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<3 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
        }
        let sent = await transcript.compacted(policy: .unpruned)
        #expect(sent.settledThrough == sent.messages.count)
        #expect(imageCount(sent.messages) == 3, "an unpruned policy must still prune nothing")
    }

    /// Repeated abbreviation used to take a head and tail *of the abbreviation*,
    /// producing a shorter string every turn — data loss, and history that never
    /// settled however long the session ran.
    @Test("Abbreviating an already-abbreviated result changes nothing")
    func abbreviationIsIdempotent() {
        let once = Transcript.abbreviate(String(repeating: "x", count: 500), to: 40)
        #expect(Transcript.abbreviate(once, to: 40) == once)
        #expect(Transcript.abbreviate(Transcript.elidedImageNote, to: 40) == Transcript.elidedImageNote)
    }

    /// The pruning still has to *happen* — a stable prefix that never drops anything
    /// is just an unpruned transcript with extra steps.
    @Test("Compaction still elides, and what it drops stays dropped")
    func compactionStillPrunesAndIsMonotonic() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<4 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
        }
        let policy = Transcript.ContextPolicy(keepRecentImages: 1, keepRecentFullResults: 6,
                                              staleResultBudget: 400)
        #expect(imageCount(await transcript.compacted(policy: policy).messages) == 1)

        // The record itself is now the compacted one: a later read under a *laxer*
        // policy cannot resurrect what was dropped, which is the honest consequence of
        // keeping the pruning rather than recomputing it.
        #expect(imageCount(await transcript.conversation) == 1)
        #expect(imageCount(await transcript.conversation(policy: .unpruned)) == 1)
    }

    /// `conversation(policy:)` is still the pure one. Callers that want to know what a
    /// policy *would* do — a report, a size estimate — must be able to ask without
    /// changing what the next request sends.
    @Test("Asking what a policy would do does not do it")
    func conversationStaysPure() async throws {
        let (transcript, directory) = try makeTranscript()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<3 {
            for message in screenshotExchange(id: "t\(index)") {
                await transcript.append(message)
            }
        }
        _ = await transcript.conversation(keepingRecentImages: 0)
        #expect(imageCount(await transcript.conversation) == 3)
    }

}
