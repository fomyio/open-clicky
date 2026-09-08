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

    /// Where the credential for the selected provider comes from — or why it cannot
    /// be read.
    ///
    /// `.exposed` exists because `try?` around resolution collapsed a
    /// `ConfigFile.Error.tooOpen` into "nothing configured": a file anyone on the
    /// machine can read rendered as an unremarkable empty state, while the CLI refuses
    /// to use it and says to rotate the key. A panel that hides that is worse than one
    /// that never mentioned the file.
    enum Credential: Equatable {
        case none
        case environment
        case stored
        case exposed(String)
    }

    /// What a check against the endpoint produced.
    enum Status: Equatable {
        case idle
        case checking
        case ok(String)
        case warning(String)
        case failure(String)
    }

    @Published private(set) var kind: Provider.Kind
    /// The two model pickers, held rather than rebuilt per render.
    ///
    /// This is the whole fix for an escape hatch that could not be reached: "the user
    /// wants to type an id" is a decision, and a decision the view re-derives from the
    /// current value each time it draws is a decision that never survives being made.
    @Published var modelPicker: ModelPicker
    /// Empty value means "no planner": the run is unplanned, which is the default.
    @Published var plannerPicker: ModelPicker
    @Published var baseURL: String
    /// Typed by the user, written on demand, never read back from disk.
    @Published var apiKeyEntry: String = ""

    @Published private(set) var status: Status = .idle
    /// Where the credential for `kind` is coming from right now.
    @Published private(set) var credential: Credential = .none
    /// The last write failure, or nil. Shown rather than swallowed: a settings panel
    /// that silently fails to save is a panel that lies about what the next run does.
    @Published private(set) var saveError: String?

    let config: ConfigFile

    init(config: ConfigFile = ConfigFile()) {
        self.config = config
        let selection = ProviderSelection.stored((try? config.settings()) ?? ConfigFile.Settings())
        self.kind = selection.kind
        self.baseURL = selection.baseURL
        self.modelPicker = Self.picker(for: selection.kind, value: selection.model, allowsNone: false)
        self.plannerPicker = Self.picker(for: selection.kind, value: selection.planner, allowsNone: true)
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

    /// What the executor picker is showing right now.
    ///
    /// The picker's own list rather than `selection.catalog`, because for Ollama the
    /// two are different answers: the catalogue in the library is empty by design and
    /// the daemon's reply arrives afterwards. Anything reading this to describe what
    /// is on offer — the vision nudge, for one — must describe the list the user is
    /// actually looking at.
    var catalog: [ModelChoice] { modelPicker.choices }

    var model: String { modelPicker.value }
    var planner: String { plannerPicker.value }

    private static func picker(
        for kind: Provider.Kind, value: String, allowsNone: Bool
    ) -> ModelPicker {
        ModelPicker(
            value: value,
            choices: allowsNone ? ModelCatalog.planners(for: kind) : ModelCatalog.models(for: kind),
            allowsNone: allowsNone
        )
    }

    // MARK: - Asking the endpoint what it serves

    /// Replaces both pickers' choices with the models the endpoint reports.
    ///
    /// Ollama only — `ModelCatalog.isLiveQueried` decides, and for every other provider
    /// this returns without touching anything, because a curated list must not be
    /// replaced by the empty one a hosted endpoint gives while its key is still being
    /// typed. The synchronous, empty list is what shows until this answers, which is
    /// the free-text field: the right control for a value only the daemon knows.
    ///
    /// The stored key is read into a local, never into a published property. This panel
    /// deliberately never displays a secret — it would be in every screenshot of itself
    /// — but a listing against `https://ollama.com/v1` is signed like any other request,
    /// and `Provider.storedKey` is the one place that says where a key comes from.
    func refreshCatalog() async {
        guard ModelCatalog.isLiveQueried(kind) else { return }
        let asked = kind
        let askedBaseURL = baseURL
        let key = (try? Provider.storedKey(for: asked, config: config))?.key
        let found = await ModelCatalog.installed(
            for: asked,
            baseURL: askedBaseURL.isEmpty ? nil : URL(string: askedBaseURL),
            apiKey: key
        )

        // Nothing came back: the daemon is not running, or is not this. Left alone
        // rather than applied, because an empty answer and a momentary failure are the
        // same reply here, and dropping a working list on a blip would take the user's
        // options away at random. The list already on screen is at worst stale, and the
        // free-text field is beside it either way.
        guard !found.isEmpty else { return }

        // The user can switch provider, or retype the base URL, while the daemon is
        // answering. A reply is only ever applied to the question it answered — the
        // alternative is Ollama's model list appearing under Anthropic, which reads as
        // a picker offering models that 404.
        guard kind == asked, baseURL == askedBaseURL else { return }
        modelPicker.offer(found)
        plannerPicker.offer(found)
    }

    /// Starts a refresh, replacing one already in flight.
    ///
    /// Cancelled rather than left to race: two answers applied in arrival order would
    /// let a slow reply for the previous endpoint land last and win.
    func refreshCatalogSoon() {
        catalogRefresh?.cancel()
        catalogRefresh = Task { [weak self] in
            await self?.refreshCatalog()
        }
    }

    private var catalogRefresh: Task<Void, Never>?

    // MARK: - Picking a model

    /// An entry chosen from the list, or the move to the free-text field.
    ///
    /// `ModelPicker.pick` answers whether the change is worth persisting: the move to
    /// the field is not, because it changes nothing yet and saving there would write
    /// the value the user is about to replace.
    func pickModel(_ tag: String) {
        if modelPicker.pick(tag) { save() }
    }

    func pickPlanner(_ tag: String) {
        if plannerPicker.pick(tag) { save() }
    }

    /// Typed into the free-text field. Saved on a pause — see `saveSoon`.
    func typeModel(_ text: String) {
        modelPicker.type(text)
        saveSoon()
    }

    func typePlanner(_ text: String) {
        plannerPicker.type(text)
        saveSoon()
    }

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

    /// The endpoint a run would actually call: what was typed, or the provider's own.
    /// Named in the empty-catalogue note, where "not running" is only useful beside
    /// *which* address answered nothing.
    var effectiveBaseURL: String {
        baseURL.isEmpty ? baseURLPlaceholder : baseURL
    }

    /// The placeholder for the free-text model field.
    ///
    /// An example is only offered where one can be true. It used to fall back to
    /// `gpt-4o` for any provider without a default, which under Ollama suggested a
    /// model that endpoint has never served. What Ollama serves is whatever was pulled,
    /// so the field points at the command that says so rather than naming an id this
    /// build cannot know.
    var modelPlaceholder: String {
        if let example = modelPicker.choices.first?.id { return "Model id, e.g. \(example)" }
        if let fallback = kind.defaultModel { return "Model id, e.g. \(fallback)" }
        return kind == .ollama
            ? "Model id exactly as `ollama list` prints it, tag and all"
            : "Model id this endpoint serves"
    }

    /// Whether a model has been chosen at all.
    ///
    /// Ollama has no default any more — there is no id this build could name that a
    /// given machine is sure to have pulled — so "nothing chosen" is a state the panel
    /// can genuinely be in, and one a run refuses to start from.
    var hasModel: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        baseURL = updated.baseURL
        modelPicker = Self.picker(for: updated.kind, value: updated.model, allowsNone: false)
        plannerPicker = Self.picker(for: updated.kind, value: updated.planner, allowsNone: true)
        status = .idle
        save()
        refreshCredentialSource()
        refreshCatalogSoon()
    }

    /// Saves shortly, replacing any save already pending.
    ///
    /// For the text fields. Saving on each keystroke wrote the file — a directory
    /// probe, an atomic replace and two `chmod`s — once per character, and published
    /// every half-typed id to a reader: `AppDelegate` re-resolves the provider on every
    /// summon. Waiting for a Return instead would lose what someone typed and then
    /// closed the window on, which is the failure a Save button has.
    func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private var pendingSave: Task<Void, Never>?

    /// Persists the current choice. Called on every edit — a settings panel with a
    /// Save button people forget to press is a panel that reports a configuration the
    /// next run does not use.
    func save() {
        pendingSave?.cancel()
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
        // Asked before resolution, because resolution *throws* on an exposed file and
        // a caught throw cannot be told apart from an empty one.
        if let problem = config.permissionProblem() {
            credential = .exposed("\(problem)")
            return
        }
        guard let provider = try? resolveProvider() else {
            credential = .none
            return
        }
        switch provider.source {
        case .environment: credential = .environment
        case .configFile: credential = .stored
        case nil: credential = .none
        }
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
        refreshCredentialSource()
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
