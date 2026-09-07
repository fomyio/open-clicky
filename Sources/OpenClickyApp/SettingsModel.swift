import Foundation
import OpenClickyKit

/// The settings window's state, and the only thing in the app that writes
/// `~/.openclicky/config.json`.
///
/// Separated from the view for the reason `SessionController` is: what it decides —
/// which provider is in play, whether the chosen model can see the screen, whether a
/// planner choice is worth paying for — is checkable without a window server, and was
/// unreachable by any test while it lived in a `View`.
///
/// It never loads a stored key into a published property. A settings panel that shows
/// the secret puts it in every screenshot the user takes of it, and in the accessibility
/// tree of the machine this very agent reads — so the key is write-only here, and what
/// is displayed is *where* the credential came from, which is the thing people actually
/// need to know when one of two stores is stale.
@MainActor
final class SettingsModel: ObservableObject {

    /// What a check against the endpoint produced.
    enum Status: Equatable {
        case idle
        case checking
        case ok(String)
        case warning(String)
        case failure(String)
    }

    @Published var kind: Provider.Kind
    @Published var model: String
    /// Empty means "no planner": the run is unplanned, which is the default.
    @Published var planner: String
    @Published var baseURL: String
    /// Typed by the user, written on demand, never read back from disk.
    @Published var apiKeyEntry: String = ""

    @Published private(set) var status: Status = .idle
    /// Where the credential for `kind` is coming from right now, or nil for none.
    @Published private(set) var credentialSource: String?
    /// The last write failure, or nil. Shown rather than swallowed: a settings panel
    /// that silently fails to save is a panel that lies about what the next run does.
    @Published private(set) var saveError: String?

    let config: ConfigFile

    init(config: ConfigFile = ConfigFile()) {
        self.config = config
        let selection = ProviderSelection.stored((try? config.settings()) ?? ConfigFile.Settings())
        self.kind = selection.kind
        self.model = selection.model
        self.planner = selection.planner
        self.baseURL = selection.baseURL
        refreshCredentialSource()
    }

    // MARK: - What the choice means

    /// The published fields as one value.
    ///
    /// Every rule about this choice lives on `ProviderSelection`, in the library,
    /// where a test can reach it — this type is the SwiftUI binding surface and
    /// nothing more.
    var selection: ProviderSelection {
        ProviderSelection(kind: kind, model: model, planner: planner, baseURL: baseURL)
    }

    var catalog: [ModelChoice] { selection.catalog }
    var plannerCatalog: [ModelChoice] { ModelCatalog.planners(for: kind) }

    /// The vision verdict, in the words the settings panel shows.
    ///
    /// The question the user came to answer: a model that cannot be sent images does
    /// not merely take worse screenshots, it never receives one — `ToolRegistry`
    /// removes the pixel tools entirely, and a run that never clicks looks like a run
    /// that chose not to.
    var visionSummary: String { selection.visionSummary }

    var hasVision: Bool { selection.hasVision }

    /// Advice about the planner pairing, or nil when there is nothing to say.
    var plannerCaution: String? { selection.plannerCaution }

    /// Whether this provider's endpoint is the user's to choose.
    var acceptsBaseURL: Bool { selection.acceptsBaseURL }

    var baseURLPlaceholder: String {
        kind.defaultBaseURL?.absoluteString ?? ""
    }

    /// Whether a run can start for this provider without any key at all.
    var needsKey: Bool { kind.requiresKey }

    // MARK: - Editing

    /// Switches provider, taking that provider's own defaults with it.
    ///
    /// What is carried across — nothing — is decided by `ProviderSelection.switching`,
    /// where it is tested.
    func select(_ next: Provider.Kind) {
        guard next != kind else { return }
        let updated = selection.switching(to: next)
        kind = updated.kind
        model = updated.model
        planner = updated.planner
        baseURL = updated.baseURL
        status = .idle
        save()
        refreshCredentialSource()
    }

    /// Persists the current choice. Called on every edit — a settings panel with a
    /// Save button people forget to press is a panel that reports a configuration the
    /// next run does not use.
    func save() {
        do {
            try config.setSettings(selection.settings)
            saveError = nil
        } catch {
            saveError = "\(error)"
        }
    }

    /// Stores the typed key and clears the field.
    ///
    /// Trimmed first. A key pasted from a password manager routinely carries a space,
    /// and untrimmed it fails in both directions: a leading one makes a valid key look
    /// malformed, a trailing one stores a key that 401s on every request afterwards.
    func saveKey() {
        let key = apiKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try config.setKey(key, provider: kind.rawValue)
            apiKeyEntry = ""
            saveError = nil
            status = .idle
        } catch {
            saveError = "\(error)"
        }
        refreshCredentialSource()
    }

    func forgetKey() {
        do {
            try config.removeKey(provider: kind.rawValue)
            saveError = nil
            status = .idle
        } catch {
            saveError = "\(error)"
        }
        refreshCredentialSource()
    }

    // MARK: - Checking it

    /// Resolves the provider exactly as a run does.
    ///
    /// The same call the run takes, not a reconstruction of it: a check that bypasses
    /// the lookup it is meant to validate proves only that a key works somewhere.
    func resolveProvider() throws -> Provider {
        try Provider.resolve(
            config: config,
            kind: kind,
            baseURL: acceptsBaseURL && !baseURL.isEmpty ? baseURL : nil,
            model: model.isEmpty ? nil : model,
            planner: planner.isEmpty ? nil : planner
        )
    }

    private func refreshCredentialSource() {
        guard let provider = try? resolveProvider() else {
            credentialSource = nil
            return
        }
        credentialSource = provider.source?.rawValue
    }

    /// One token in and one out, against the endpoint this configuration names.
    ///
    /// "A key is stored" is not the same claim as "this works", and the gap between
    /// them is where a mistyped key, an unreachable daemon, or a model id the provider
    /// has never heard of hides until the user has typed a task and watched it fail.
    func check() async {
        status = .checking
        let provider: Provider
        do {
            provider = try resolveProvider()
        } catch {
            status = .failure("\(error)")
            return
        }
        credentialSource = provider.source?.rawValue
        switch await provider.verify() {
        case .working:
            status = .ok("Verified against \(provider.kind.label) — \(provider.model) answered.")
        case let .misconfigured(detail):
            // The credential is fine and replacing it would not help. Distinct from a
            // rejection on purpose: against a local Ollama this is almost always a
            // model that has never been pulled, and "check your key" sends the user
            // to the one thing that is working.
            status = .warning("\(provider.kind.label) refused this request: \(detail)")
        case let .rejected(detail):
            status = .failure("\(provider.kind.label) rejected the key: \(detail)")
        case let .unreachable(detail):
            status = .warning("Could not reach \(provider.kind.label): \(detail)")
        }
    }
}
