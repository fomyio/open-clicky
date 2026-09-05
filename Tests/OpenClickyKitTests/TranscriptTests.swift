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
}
