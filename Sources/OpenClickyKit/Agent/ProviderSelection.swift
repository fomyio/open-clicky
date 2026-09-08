import Foundation

/// A provider, model and planner chosen together, on their way to `config.json`.
///
/// In the library rather than in the app's view model for the reason `Invocation` is
/// in the library rather than in `main.swift`: what it decides — whether the chosen
/// model can be sent a screenshot, and what happens to a model id when the provider
/// changes underneath it — is checkable without a window server, and would be
/// defended by nothing while it lived in a `View`.
///
/// Empty strings, not optionals, because every field is bound to a text control. The
/// conversion to `ConfigFile.Settings` is where blank becomes absent.
public struct ProviderSelection: Equatable, Sendable {

    public var kind: Provider.Kind
    public var model: String
    /// Empty means unplanned, which is the default and not a missing value.
    public var planner: String
    /// Empty means the provider's own endpoint.
    public var baseURL: String

    public init(
        kind: Provider.Kind,
        model: String = "",
        planner: String = "",
        baseURL: String = ""
    ) {
        self.kind = kind
        self.model = model
        self.planner = planner
        self.baseURL = baseURL
    }

    /// The selection a stored settings block describes, filling in the provider's own
    /// default model where none was chosen.
    ///
    /// A default is materialised here and not written back by itself: the file records
    /// what the user chose, so an unchosen model must keep tracking the built-in
    /// default rather than being frozen at whatever it was on the day the file was
    /// first written.
    public static func stored(_ settings: ConfigFile.Settings) -> ProviderSelection {
        let kind = settings.provider.flatMap(Provider.Kind.init(rawValue:)) ?? .anthropic
        return ProviderSelection(
            kind: kind,
            model: settings.model ?? kind.defaultModel ?? "",
            planner: settings.planner ?? "",
            baseURL: settings.baseURL ?? ""
        )
    }

    /// This selection as it is written to disk.
    ///
    /// The exact inverse of `stored`: that fills the provider's default in for
    /// display, and this strips it back out for storage, so a round trip is lossless
    /// and the file keeps recording only what the user actually chose.
    ///
    /// Stripping it matters. The app hands this straight to `setSettings` whenever a
    /// provider is picked, so writing the materialised default would freeze it: one
    /// click on a provider tab and that provider's model is pinned forever at whatever
    /// the built-in default happened to be that day, without anyone having chosen it.
    /// Absent means "the provider's own", which keeps tracking it.
    ///
    /// The base URL is dropped for Anthropic rather than stored and ignored: its
    /// endpoint is not configurable — it speaks the Messages API, not the OpenAI
    /// dialect — and a stored value nothing reads is a setting that appears to have
    /// taken effect.
    public var settings: ConfigFile.Settings {
        ConfigFile.Settings(
            provider: kind.rawValue,
            model: model == kind.defaultModel ? nil : model,
            baseURL: acceptsBaseURL ? baseURL : nil,
            planner: planner
        )
    }

    /// Whether this provider's endpoint is the user's to choose. See `settings`.
    public var acceptsBaseURL: Bool { kind != .anthropic }

    /// The same selection against another provider.
    ///
    /// Nothing is carried across, and that is the point. A model id is meaningful only
    /// beside the endpoint that serves it: keeping `llava` while switching to
    /// Anthropic produces a 404 that reads as a broken install, and keeping a base URL
    /// aims one provider's client at another's endpoint. The stored settings hold one
    /// active choice — the CLI resolves a single provider, model and base URL — so a
    /// per-provider memory would be a second shape for the same question.
    public func switching(to next: Provider.Kind) -> ProviderSelection {
        guard next != kind else { return self }
        return ProviderSelection(kind: next, model: next.defaultModel ?? "")
    }

    // MARK: - What the choice means

    /// What the chosen model accepts and can be trusted to drive.
    public var capabilities: ModelCapabilities { .forModel(model) }

    /// Whether the chosen model can be sent a screenshot.
    public var hasVision: Bool { capabilities.vision }

    /// The highest tier a run on this selection can reach.
    public var maxTier: Tier { capabilities.maxTier }

    /// The vision verdict in one sentence, for a settings panel.
    public var visionSummary: String { ModelChoice(id: model).capabilitySummary }

    /// Advice about the planner pairing, or nil when there is nothing to say.
    public var plannerCaution: String? {
        ModelCatalog.plannerCaution(planner: planner, executor: model)
    }

    /// The models this provider is offered, for a picker.
    public var catalog: [ModelChoice] { ModelCatalog.models(for: kind) }

    /// Whether an id is one the picker lists, or something typed by hand.
    public func isCatalogued(_ id: String) -> Bool {
        catalog.contains { $0.id == id }
    }
}

/// A picker over a catalogue with a free-text escape hatch, and the state deciding
/// which of the two the user is looking at.
///
/// In the library because the first version of this lived in a `View` and was broken:
/// "is this a custom id" was *derived* from whether the current value appeared in the
/// catalogue, so choosing "Custom…" while a catalogued model was selected — the common
/// case, since every provider fills in a real default — changed nothing, the text field
/// never appeared, and the picker snapped back. The escape hatch was unreachable for
/// exactly the people who needed it, and the comment beside it said the opposite.
///
/// Being custom is therefore a *decision*, held here, not a property inferred from the
/// value. A test can now drive the transitions; a `View` could not.
public struct ModelPicker: Equatable, Sendable {

    /// The tag for "not in the list". A control character, so it can never collide
    /// with a real model id.
    public static let customTag = "\u{1}custom"
    /// The tag for "nothing chosen", where that is an answer.
    public static let noneTag = ""

    /// Settable only through `offer`, because a catalogue can arrive after the picker
    /// was built — see there.
    public private(set) var choices: [ModelChoice]
    /// Whether "none" is offered. True for the planner, where off is the default
    /// answer rather than a missing one.
    public let allowsNone: Bool

    /// The model id itself. Empty means nothing is chosen.
    public private(set) var value: String
    /// Set when the user asked to type an id, and kept even while what they have typed
    /// happens to match the catalogue — otherwise the field would vanish mid-word the
    /// moment a prefix matched.
    private var choseToType: Bool

    public init(value: String, choices: [ModelChoice], allowsNone: Bool) {
        self.choices = choices
        self.allowsNone = allowsNone
        self.value = value
        // A stored id the catalogue does not list is custom without anyone saying so:
        // the field has to be showing for it to be editable at all.
        self.choseToType = !value.isEmpty && !choices.contains { $0.id == value }
    }

    /// Whether the free-text field is showing.
    ///
    /// Always, for a provider with no catalogue — LiteLLM routes by names its own
    /// configuration defines, so the field is the only way to say anything.
    public var isCustom: Bool { choseToType || choices.isEmpty }

    /// What the picker control should show as selected.
    public var tag: String { isCustom ? Self.customTag : value }

    /// The user picked an entry from the list.
    ///
    /// - Returns: whether the choice is worth persisting. False only for the move to
    ///   the text field, which changes nothing yet — saving there would write the
    ///   value the user is about to replace.
    @discardableResult
    public mutating func pick(_ tag: String) -> Bool {
        guard tag != Self.customTag else {
            choseToType = true
            return false
        }
        choseToType = false
        value = tag
        return true
    }

    /// The user typed into the field.
    public mutating func type(_ text: String) {
        choseToType = true
        value = text
    }

    /// The same picker over a catalogue that arrived later.
    ///
    /// Ollama's list is asked of the daemon, so it lands some milliseconds after the
    /// window opens — and the two things it must not disturb are the two this type
    /// exists to protect. The value survives: a model id typed by hand is the only
    /// record of what the user wants, and a list arriving is not a reason to replace
    /// it. So does the decision to type: `choseToType` is kept even when the arriving
    /// list turns out to contain what has been typed so far, because the alternative is
    /// the field vanishing mid-word at a moment nobody can predict — the exact defect
    /// that made the escape hatch unreachable before, reintroduced asynchronously.
    public mutating func offer(_ arrivals: [ModelChoice]) {
        choices = arrivals
    }

    /// The label for the custom entry, naming what is in the field when it is showing.
    public var customLabel: String {
        isCustom && !value.isEmpty ? "Custom: \(value)" : "Custom…"
    }
}
