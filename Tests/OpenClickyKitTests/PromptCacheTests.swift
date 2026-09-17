import Testing
import Foundation
@testable import OpenClickyKit

/// Prompt caching fails silently. A misplaced breakpoint, or a byte that moves behind
/// one, produces a request that is still correct and an answer that is still right —
/// only the bill changes, and only `CostMeter.cacheHitRate` would ever say so. So the
/// things asserted here are the ones nothing else in the system would notice.
@Suite("Prompt caching")
struct PromptCacheTests {

    // MARK: - Where the history breakpoints go

    private func turn(_ id: String) -> [Wire.Message] {
        [
            Wire.Message(role: .assistant, content: [.toolUse(id: id, name: "probe", input: .object([:]))]),
            Wire.Message(role: .user, content: [
                .toolResult(toolUseID: id, content: [.text("ok")], isError: false),
            ]),
        ]
    }

    private func marked(_ messages: [Wire.Message], settledThrough: Int = 0) -> [Int] {
        let result = PromptCache.markingHistory(messages, settledThrough: settledThrough)
        return result.indices.filter { result[$0].cacheControl }
    }

    /// A session's first request has nothing cached yet, so there is one marker and it
    /// only writes. A second marker here would have to point at the same message.
    @Test("The opening request marks only the message it is about to write")
    func openingRequestMarksOnce() {
        #expect(marked([.user("do the thing")]) == [0])
    }

    /// Nothing has settled yet, so there is one marker and it only writes. A second
    /// one would have to sit in the churning tail, where it can never be read back.
    @Test("With nothing settled, only the newest turn is marked")
    func unsettledHistoryMarksOnlyTheEnd() {
        let opening = Wire.Message.user("do the thing")
        #expect(marked([opening] + turn("t1")) == [2])
        #expect(marked([opening] + turn("t1") + turn("t2")) == [4])
    }

    /// The pair that makes a growing history cache: the settled marker reads a prefix
    /// that is byte-identical to last turn's, and the end marker writes the entry that
    /// will be read on any turn where nothing aged out behind it.
    @Test("A settled frontier earns the second marker")
    func settledFrontierIsMarked() {
        let opening = Wire.Message.user("do the thing")
        let messages = [opening] + turn("t1") + turn("t2") + turn("t3")
        #expect(marked(messages, settledThrough: 3) == [2, 6])
        #expect(marked(messages, settledThrough: 5) == [4, 6])
    }

    /// The frontier is an index into the messages, not a turn boundary, so it can land
    /// on an assistant turn. Snapped backwards rather than used where it fell.
    @Test("A frontier landing mid-turn snaps back to the boundary before it")
    func frontierSnapsToATurnBoundary() {
        let messages = [Wire.Message.user("start")] + turn("t1") + turn("t2")
        // Index 3 is the assistant half of the second turn.
        #expect(marked(messages, settledThrough: 4) == [2, 4])
    }

    /// A frontier that has caught up with the newest message must not put both markers
    /// on it — that spends two breakpoints to cache one prefix. It is clamped to the
    /// message before the end instead, which is still a settled boundary.
    @Test("The two markers never land on the same message")
    func markersNeverCollide() {
        let messages = [Wire.Message.user("start")] + turn("t1")
        for frontier in [messages.count, 99, .max] {
            let result = marked(messages, settledThrough: frontier)
            #expect(result == [0, 2], "frontier \(frontier)")
            #expect(Set(result).count == result.count, "the same message was marked twice")
        }
    }

    /// The budget is four and the prefix has already spent two. A third history marker
    /// would be rejected by the API for the whole request, not quietly ignored.
    @Test("Never more history breakpoints than the budget leaves")
    func historyNeverExceedsItsShare() {
        var messages: [Wire.Message] = [.user("start")]
        for index in 0..<12 {
            messages += turn("t\(index)")
            for frontier in 0...messages.count {
                #expect(marked(messages, settledThrough: frontier).count <= PromptCache.forHistory)
            }
        }
        #expect(PromptCache.reservedForPrefix + PromptCache.forHistory == PromptCache.budget)
    }

    /// The regression the fixed-offset version had. A persistent session appends a new
    /// user instruction straight after the previous task's final assistant turn, so
    /// every index shifts by one and `last - 2` lands mid-turn — between an assistant's
    /// `tool_use` and the `tool_result` that answers it, which is never a boundary.
    @Test("A second instruction in one session does not shift the marker off a boundary")
    func breakpointsFollowTurnBoundariesNotArithmetic() {
        let firstTask: [Wire.Message] =
            [.user("first")] + turn("t1")
            + [Wire.Message(role: .assistant, content: [.text("done")])]
        let messages = firstTask + [.user("second")]

        let result = PromptCache.markingHistory(messages, settledThrough: 3)
        for index in result.indices where result[index].cacheControl {
            #expect(result[index].role == .user, "a breakpoint landed inside an assistant turn")
        }
    }

    @Test("Marking replaces any breakpoints already set rather than adding to them")
    func markingIsIdempotent() {
        let messages = [Wire.Message.user("start")] + turn("t1") + turn("t2")
        let once = PromptCache.markingHistory(messages, settledThrough: 3)
        #expect(marked(messages, settledThrough: 3) == marked(once, settledThrough: 3))
    }

    // MARK: - The system blocks

    @Test("The breakpoint closes the stable region, leaving the session block outside")
    func systemBreakpointSitsOnTheLastCachedBlock() {
        let blocks = PromptCache.systemBlocks(
            stable: "prompt", environment: "<screens>one</screens>", session: "grants"
        )
        #expect(blocks.map(\.text) == ["prompt", "<screens>one</screens>", "grants"])
        #expect(blocks.map(\.cacheControl) == [false, true, false])
    }

    /// An empty block would spend one of four breakpoints on nothing at all.
    @Test("An empty environment is dropped rather than sent blank")
    func emptyEnvironmentIsOmitted() {
        let blocks = PromptCache.systemBlocks(stable: "prompt", environment: "", session: "grants")
        #expect(blocks.map(\.text) == ["prompt", "grants"])
        #expect(blocks.map(\.cacheControl) == [true, false])
    }

    // MARK: - What actually reaches the wire

    private func encoded(_ message: Wire.Message) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Wire.encoder.encode(message))
    }

    private func cacheControlFlags(_ message: Wire.Message) throws -> [Bool] {
        let blocks = try #require(encoded(message)["content"]?.arrayValue)
        return blocks.map { $0["cache_control"] != nil }
    }

    /// `cache_control` goes on a content block, and only the last block of a message is
    /// a turn boundary — one in the middle would cut between a `thinking` block and the
    /// `tool_use` it justifies.
    @Test("A marked message carries the breakpoint on its last block only")
    func breakpointLandsOnTheFinalBlock() throws {
        let message = Wire.Message(role: .assistant, content: [
            .thinking(text: "considering", signature: "sig"),
            .text("here goes"),
            .toolUse(id: "t1", name: "probe", input: .object([:])),
        ], cacheControl: true)
        #expect(try cacheControlFlags(message) == [false, false, true])
    }

    @Test("An unmarked message carries no cache_control at all")
    func unmarkedMessageIsUnchanged() throws {
        let message = Wire.Message(role: .user, content: [.text("hello"), .text("again")])
        #expect(try cacheControlFlags(message) == [false, false])
    }

    /// `.passthrough` encodes through a single-value container while every other case
    /// takes a keyed one. Adding a key by reopening the encoder works for one of those
    /// shapes and silently drops it for the other, which is why the marker is applied
    /// to the re-read value instead.
    @Test("The breakpoint survives on a passthrough block")
    func breakpointAppliesToAnUnmodelledBlock() throws {
        let message = Wire.Message(role: .assistant, content: [
            .passthrough(.object(["type": .string("redacted_thinking"), "data": .string("xyz")])),
        ], cacheControl: true)
        let blocks = try #require(encoded(message)["content"]?.arrayValue)
        #expect(blocks.first?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(blocks.first?["type"]?.stringValue == "redacted_thinking",
                "the block's own fields must survive being marked")
    }

    /// A breakpoint is a property of one request, not of the turn. The transcript
    /// replays assistant turns verbatim and compares them; two messages holding the
    /// same content are the same message whichever one a sender happened to mark.
    @Test("A breakpoint is not part of a message's identity")
    func cacheControlIsOutsideEquality() throws {
        let plain = Wire.Message(role: .user, content: [.text("hello")])
        #expect(plain == plain.caching(true))

        let round = try JSONDecoder().decode(
            Wire.Message.self, from: Wire.encoder.encode(plain.caching(true))
        )
        #expect(!round.cacheControl, "a decoded message must not claim a breakpoint")
        #expect(round == plain)
    }
}
