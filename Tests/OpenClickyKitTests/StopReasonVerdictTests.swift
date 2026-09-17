import Testing
import Foundation
@testable import OpenClickyKit

/// Which stop reasons earn a *success* disposition, and what happens to the ones nobody
/// taught this code to read.
///
/// The loop used to end with `.concluded(response.stopReason ?? "end_turn")`. That gives
/// the disposition meaning "the agent got to the end of its own work" to every word it
/// does not recognise — and `OpenAIWire.stopReason` deliberately passes unrecognised
/// values through verbatim, so anything a provider invents arrives intact and is read as
/// success. It is the same defect as the planner's, one layer up: the ambiguous case
/// resolved in the direction this project explicitly forbids.
@Suite("Stop reason verdicts")
struct StopReasonVerdictTests {

    /// The three the loop is entitled to treat as a finished turn. Both dialects
    /// normalise into these before the loop sees them.
    @Test("The concluding vocabulary is an allow-list", arguments: ["end_turn", "stop_sequence", "tool_use"])
    func concludingReasons(reason: String) {
        #expect(StopReason.reported(reason).disposition == .concluded)
        // The provider's own word survives; only the verdict is being decided here.
        #expect(StopReason.reported(reason).sentence == reason)
    }

    /// The whole point. A proxy that shouts `MAX_TOKENS`, an API that grows a reason for
    /// exhausting its context window, a vendor-specific string — none of them is evidence
    /// that the work is done, and all of them used to end the run at exit 0.
    @Test("An unrecognised reason is cut short, not concluded", arguments: [
        "MAX_TOKENS", "model_context_window_exceeded", "pause_turn", "content_filter",
        "length", "max_tokens", "error", "something_new_in_2027",
    ])
    func unknownReasonsAreCutShort(reason: String) {
        let verdict = StopReason.reported(reason)
        #expect(verdict.disposition == .cutShort, "\(reason) was read as a finished run")
        // Still reported in the provider's words — more useful than one invented here.
        #expect(verdict.sentence == reason)
    }

    /// Case is not a distinction worth preserving: the same answer shouted is the same
    /// answer, and a run reported as finished because a proxy upper-cased its response
    /// would be the silliest possible version of this bug.
    @Test("Matching is case-insensitive")
    func caseDoesNotDecideTheVerdict() {
        #expect(StopReason.reported("END_TURN").disposition == .concluded)
        #expect(StopReason.reported("Tool_Use").disposition == .concluded)
    }

    /// "Never default a missing verdict to success." Both dialects fill this in before
    /// the loop is reached — `OpenAIWire.stopReason` even documents that local runtimes
    /// omit it — so arriving here empty means something upstream failed to say what
    /// happened, which is not the same as the model having finished.
    @Test("No reason at all is not a success", arguments: [nil, ""] as [String?])
    func absentReasonIsCutShort(reason: String?) {
        #expect(StopReason.reported(reason).disposition == .cutShort)
    }

    /// The translation layer and the verdict layer have to agree about the canonical
    /// vocabulary, or a reason that means "finished" in one becomes "cut short" in the
    /// other. Derived from the translator rather than retyped.
    @Test("Everything the OpenAI dialect normalises to is classified deliberately")
    func translatedReasonsAreAllClassified() {
        func translate(_ raw: String) -> String {
            OpenAIWire.stopReason(finishReason: raw, hasToolCalls: false, refusal: nil)
        }
        // A turn that ended of its own accord, and one that ended by calling tools, are
        // both the model reaching the end of its own work — the loop only asks this
        // question when no calls arrived, and `execute` handles the ones that did.
        for finished in ["stop", "tool_calls", "function_call"] {
            #expect(StopReason.reported(translate(finished)).disposition == .concluded,
                    "\(finished) should read as a finished turn")
        }
        // A clipped answer and a filtered one are not.
        for stopped in ["length", "content_filter"] {
            #expect(StopReason.reported(translate(stopped)).disposition == .cutShort,
                    "\(stopped) should not read as a finished run")
        }
    }
}

/// A stream that stops without saying why, and without its sentinel, did not finish.
///
/// `StreamAssembler` has always known this — `sawDone` is set on `[DONE]` — and nothing
/// read it. A proxy that closes an SSE connection mid-answer (LiteLLM, nginx, ngrok, a
/// dropped tunnel) produced a synthesised `"stop"`, which becomes `end_turn`, which is a
/// concluded disposition and exit 0 with half a reply.
@Suite("Truncated streams")
struct TruncatedStreamTests {

    private func assembled(_ lines: [String]) -> JSONValue {
        var assembler = StreamAssembler()
        for line in lines { _ = assembler.consume(line: line) }
        return assembler.completion()
    }

    private func reason(_ value: JSONValue) -> String? {
        value["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue
    }

    private func chunk(_ text: String) -> String {
        #"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"#
    }

    @Test("A stream cut off with no reason and no sentinel reports truncation")
    func severedStreamIsTruncated() {
        let value = assembled([chunk("half a th")])
        #expect(reason(value) == "length")
        // Which is the vocabulary the loop already handles properly.
        #expect(OpenAIWire.stopReason(finishReason: "length", hasToolCalls: false, refusal: nil)
            == "max_tokens")
        #expect(StopReason.reported("max_tokens").disposition == .cutShort)
    }

    @Test("A stream that finished normally is untouched")
    func completeStreamStillConcludes() {
        #expect(reason(assembled([chunk("all of it"), "data: [DONE]"])) == "stop")
    }

    /// A stream that said why it stopped is taken at its word even if the sentinel never
    /// arrived — the provider answered the question, so nothing needs inferring.
    @Test("A stated reason wins over the missing sentinel")
    func statedReasonSurvivesAMissingSentinel() {
        let stated = #"data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}"#
        #expect(reason(assembled([stated])) == "stop")
    }
}
