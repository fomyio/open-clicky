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
