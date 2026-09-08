import Testing
import Foundation
@testable import OpenClickyKit

/// The rule that decides whether a persistent session may keep the loop it has.
///
/// Tested here rather than through the app because the app target has no tests and the
/// failure this defends against is invisible from the outside: a cached loop keeps
/// answering from the endpoint and with the tool set it was built with, while every
/// surface reports the configuration the user has just chosen. Nothing throws, nothing
/// logs, and the run looks ordinary.
@Suite("Session configuration and conversation lifetime")
struct ConversationTests {

    private func provider(
        kind: Provider.Kind = .anthropic,
        model: String = "claude-haiku-4-5",
        baseURL: String? = nil,
        planner: String? = nil,
        key: String? = "sk-test-123456789"
    ) -> Provider {
        Provider(
            kind: kind,
            model: model,
            baseURL: baseURL.flatMap(URL.init(string:)),
            credentials: key.map(Credentials.apiKey),
            source: .configFile,
            plannerModel: planner
        )
    }

    // MARK: - What counts as the same configuration

    /// Two resolutions of an unchanged `config.json` describe the same run. Comparing
    /// identity instead of value would rebuild on every task, and "the conversation
    /// carries forward" would be false while looking true.
    @Test("An unchanged configuration keeps the loop it built")
    func unchangedConfigurationMatches() {
        let first = SessionConfiguration(provider: provider())
        let second = SessionConfiguration(provider: provider())
        #expect(first.matches(second))
        #expect(second.matches(first))
    }

    /// Each of these is baked into the loop at construction and cannot be changed
    /// afterwards, so each has to end the conversation that was using it.
    @Test("Anything that shapes the loop ends the conversation", arguments: [
        "provider", "model", "planner", "endpoint", "key",
    ])
    func everyShapingFieldIsCompared(field: String) {
        let before = SessionConfiguration(provider: provider(
            kind: .openai, model: "gpt-4o",
            baseURL: "https://api.openai.com/v1", planner: "o3", key: "sk-test-123456789"
        ))
        let after: SessionConfiguration
        switch field {
        case "provider":
            after = SessionConfiguration(provider: provider(
                kind: .groq, model: "gpt-4o",
                baseURL: "https://api.openai.com/v1", planner: "o3", key: "sk-test-123456789"
            ))
        case "model":
            after = SessionConfiguration(provider: provider(
                kind: .openai, model: "gpt-4o-mini",
                baseURL: "https://api.openai.com/v1", planner: "o3", key: "sk-test-123456789"
            ))
        case "planner":
            after = SessionConfiguration(provider: provider(
                kind: .openai, model: "gpt-4o",
                baseURL: "https://api.openai.com/v1", planner: nil, key: "sk-test-123456789"
            ))
        case "endpoint":
            after = SessionConfiguration(provider: provider(
                kind: .openai, model: "gpt-4o",
                baseURL: "http://localhost:4000", planner: "o3", key: "sk-test-123456789"
            ))
        default:
            after = SessionConfiguration(provider: provider(
                kind: .openai, model: "gpt-4o",
                baseURL: "https://api.openai.com/v1", planner: "o3", key: "sk-test-987654321"
            ))
        }
        #expect(!before.matches(after), "a change of \(field) must not reuse the loop")
        #expect(after.difference(from: before) != nil, "and it must be able to say so")
    }

    /// The key is compared without being carried: a configuration value ends up beside
    /// things that get printed, and the digest is enough to notice a rotation.
    @Test("The credential is compared as a digest, not as a key")
    func credentialIsNotHeldInTheClear() {
        let configuration = SessionConfiguration(provider: provider(key: "sk-test-123456789"))
        #expect(configuration.credentialDigest != nil)
        #expect("\(configuration)".contains("sk-test-123456789") == false)
        #expect(SessionConfiguration(provider: provider(key: nil)).credentialDigest == nil)
    }

    /// Switching provider usually changes the model, the endpoint and the key at once.
    /// The phrase names the one the user recognises as the thing they just did.
    @Test("What changed is named, outermost first")
    func differenceNamesTheOutermostChange() {
        let anthropic = SessionConfiguration(provider: provider())
        let ollama = SessionConfiguration(provider: provider(
            kind: .ollama, model: "llava", baseURL: "http://localhost:11434/v1", key: nil
        ))
        #expect(ollama.difference(from: anthropic) == "the provider changed to Ollama")

        let haiku = SessionConfiguration(provider: provider(model: "claude-haiku-4-5"))
        let opus = SessionConfiguration(provider: provider(model: "claude-opus-4-5"))
        #expect(opus.difference(from: haiku) == "the model changed to claude-opus-4-5")

        let planned = SessionConfiguration(provider: provider(planner: "claude-opus-4-5"))
        #expect(planned.difference(from: haiku) == "the planner changed to claude-opus-4-5")
        #expect(haiku.difference(from: planned) == "the planner was turned off")
        #expect(haiku.difference(from: haiku) == nil, "nothing changed, nothing to say")
    }

    // MARK: - The conversation

    /// The whole promise of a persistent overlay. Without this, every summon is a first
    /// summon and "now close it" has nothing to resolve against.
    @Test("Instructions carry forward while the configuration holds")
    func instructionsCarryForward() {
        let configuration = SessionConfiguration(provider: provider())
        var conversation = Conversation()

        #expect(conversation.begin(configuration) == .startedOver(reason: nil))
        #expect(conversation.begin(configuration) == .carriedForward(instruction: 2))
        #expect(conversation.begin(configuration) == .carriedForward(instruction: 3))
        #expect(conversation.instructions == 3)
        #expect(conversation.carriesContext)
    }

    /// The defect this exists to prevent: a loop built from one configuration still
    /// serving tasks after the user chose another, with nothing on screen to say so.
    @Test("A settings change starts the conversation over and says why")
    func configurationChangeStartsOver() {
        var conversation = Conversation()
        _ = conversation.begin(SessionConfiguration(provider: provider()))
        _ = conversation.begin(SessionConfiguration(provider: provider()))
        #expect(conversation.instructions == 2)

        let started = conversation.begin(SessionConfiguration(
            provider: provider(model: "claude-opus-4-5")
        ))
        #expect(started == .startedOver(reason: "the model changed to claude-opus-4-5"))
        // A new loop means a new transcript holding exactly this instruction. Carrying
        // the old count would have the overlay claim context no request contains.
        #expect(conversation.instructions == 1)
    }

    @Test("Starting over forgets the conversation")
    func startOverForgetsEverything() {
        let configuration = SessionConfiguration(provider: provider())
        var conversation = Conversation()
        _ = conversation.begin(configuration)
        _ = conversation.begin(configuration)

        conversation.startOver()
        #expect(!conversation.carriesContext)
        #expect(conversation.instructions == 0)
        #expect(conversation.summary == nil)
        #expect(conversation.begin(configuration) == .startedOver(reason: nil),
                "the next instruction begins a new thread, not the old one")
    }

    /// "1 instructions" is the same defect as the "1 turns" this codebase has already
    /// fixed twice: a sentence assembled from a count nobody read back.
    @Test("The carried line counts what the next instruction will carry")
    func summaryCountsAndPluralises() {
        let configuration = SessionConfiguration(provider: provider())
        var conversation = Conversation()
        #expect(conversation.summary == nil, "nothing to say before the first instruction")

        _ = conversation.begin(configuration)
        #expect(conversation.summary == "carrying 1 earlier instruction")
        _ = conversation.begin(configuration)
        #expect(conversation.summary == "carrying 2 earlier instructions")
    }

    /// The user has to be able to tell "it forgot" from "you changed the model".
    @Test("The line names the change that ended the last thread")
    func summaryNamesTheRestart() {
        var conversation = Conversation()
        _ = conversation.begin(SessionConfiguration(provider: provider()))
        _ = conversation.begin(SessionConfiguration(provider: provider(model: "gpt-4o")))
        #expect(conversation.summary
                == "carrying 1 earlier instruction — started over because the model changed to gpt-4o")

        // Said once, on the instruction that started the thread, and not for ever after.
        _ = conversation.begin(SessionConfiguration(provider: provider(model: "gpt-4o")))
        #expect(conversation.summary == "carrying 2 earlier instructions")
    }
}
