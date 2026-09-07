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
    /// The base URL is dropped for Anthropic rather than stored and ignored: its
    /// endpoint is not configurable — it speaks the Messages API, not the OpenAI
    /// dialect — and a stored value nothing reads is a setting that appears to have
    /// taken effect.
    public var settings: ConfigFile.Settings {
        ConfigFile.Settings(
            provider: kind.rawValue,
            model: model,
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
