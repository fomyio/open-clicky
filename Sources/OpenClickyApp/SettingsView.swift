import SwiftUI
import OpenClickyKit

/// Where the provider, the model and the planner are chosen.
///
/// The app used to offer neither: it resolved whatever the environment and the config
/// file happened to say, so changing model meant editing JSON by hand or running the
/// CLI — and the one thing a user of a menu-bar agent cannot see is why it is slow, or
/// why it never takes a screenshot. Both are model choices, so both are made here, and
/// the consequence of each is stated beside it rather than discovered during a run.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// The sentinel a picker uses for "not in the list".
    ///
    /// A control character, so it can never collide with a real model id — a catalogue
    /// is a shortcut, and an id this build has never heard of has to stay reachable.
    private static let customTag = "\u{1}custom"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                endpointSection
                Divider()
                modelSection
                Divider()
                plannerSection
                Divider()
                checkSection
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: - Endpoint

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Provider", "Which endpoint answers, and whose key signs the request.")

            Picker("", selection: Binding(
                get: { model.kind },
                set: { model.select($0) }
            )) {
                ForEach(Provider.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.acceptsBaseURL {
                LabeledContent("Base URL") {
                    TextField(model.baseURLPlaceholder, text: $model.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.save() }
                        .onChange(of: model.baseURL) { model.save() }
                }
            }

            credentialRow
        }
    }

    private var credentialRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    // Never populated from disk: a panel that shows the secret puts it
                    // in every screenshot of itself — including the ones this agent
                    // takes.
                    SecureField(
                        model.needsKey ? "Paste a key" : "Optional for a local Ollama",
                        text: $model.apiKeyEntry
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveKey() }
                    Button("Save") { model.saveKey() }
                        .disabled(model.apiKeyEntry.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                }
            }

            HStack(spacing: 8) {
                switch model.credentialSource {
                case "environment":
                    note("A key from your environment is in use, and it wins over the stored one.",
                         icon: "terminal", tint: .orange)
                case "config file":
                    note("Stored in \(model.config.url.path), readable only by you.",
                         icon: "checkmark.circle", tint: .green)
                    Button("Forget") { model.forgetKey() }
                        .buttonStyle(.link)
                default:
                    note(model.needsKey
                         ? "No key stored for \(model.kind.label) yet."
                         : "No key — a local Ollama does not need one.",
                         icon: model.needsKey ? "exclamationmark.triangle" : "info.circle",
                         tint: model.needsKey ? .orange : .secondary)
                }
            }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Model", "The model that drives your Mac, turn by turn.")
            modelPicker(
                selection: $model.model,
                choices: model.catalog,
                emptyLabel: nil,
                placeholder: "Model id, e.g. \(model.kind.defaultModel ?? "gpt-4o")"
            )

            // The whole reason this panel exists. A model that cannot be sent an image
            // is not merely worse at tier 3 — the pixel tools are never loaded, so the
            // run works through the accessibility tree or not at all, and saying so
            // here is cheaper than the user inferring it from a run that never clicked.
            note(model.visionSummary,
                 icon: model.hasVision ? "eye" : "eye.slash",
                 tint: model.hasVision ? .green : .orange)

            if !model.hasVision {
                note("""
                    Pick a vision model if you want it to see and click: \
                    \(visionExamples). Screen Recording is not needed without one.
                    """,
                     icon: "lightbulb", tint: .secondary)
            }
        }
    }

    /// The vision-capable ids this provider offers, for the nudge above.
    ///
    /// Read out of the catalogue rather than typed into the sentence, so a model added
    /// to one list cannot go unmentioned in the other.
    private var visionExamples: String {
        let names = model.catalog.filter(\.vision).map(\.label)
        guard !names.isEmpty else {
            return "this provider's list has none — try Anthropic or OpenAI"
        }
        return names.joined(separator: ", ")
    }

    // MARK: - Planner

    private var plannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(
                "Planner",
                "A stronger model asked how to approach the task once, before the run starts."
            )
            modelPicker(
                selection: $model.planner,
                choices: model.plannerCatalog,
                emptyLabel: "None — run unplanned",
                placeholder: "Planner model id"
            )

            if let caution = model.plannerCaution {
                note(caution, icon: "exclamationmark.triangle", tint: .orange)
            } else if model.planner.isEmpty {
                note("Off. Every run is a single model, which is the cheaper default.",
                     icon: "info.circle", tint: .secondary)
            } else {
                note("""
                    Costs one extra round-trip at \(model.planner) prices per run. \
                    It takes no actions — the plan is advice the executor may depart \
                    from — and it must be served by \(model.kind.label), like the model above.
                    """,
                     icon: "info.circle", tint: .secondary)
            }
        }
    }

    // MARK: - Checking it

    private var checkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Test this configuration") {
                    Task { await model.check() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                if case .checking = model.status {
                    ProgressView().controlSize(.small)
                }
            }

            switch model.status {
            case .idle:
                note("One token in and one out. \"A key is stored\" is not the same claim as \"this works\".",
                     icon: "info.circle", tint: .secondary)
            case .checking:
                note("Asking \(model.kind.label)…", icon: "hourglass", tint: .secondary)
            case let .ok(text):
                note(text, icon: "checkmark.circle", tint: .green)
            case let .warning(text):
                note(text, icon: "exclamationmark.triangle", tint: .orange)
            case let .failure(text):
                note(text, icon: "xmark.circle", tint: .red)
            }

            if let error = model.saveError {
                note("Could not save: \(error)", icon: "xmark.circle", tint: .red)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved to \(model.config.url.path) — mode 600, plain text.")
            Text("The `openclicky` CLI reads the same file. A flag or an environment variable overrides it for one run.")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Pieces

    /// A picker over a catalogue, with a free-text escape hatch.
    ///
    /// - Parameter emptyLabel: the label for "nothing chosen", or nil where a choice
    ///   is required. The planner needs it — off is a real, and the default, answer.
    private func modelPicker(
        selection: Binding<String>,
        choices: [ModelChoice],
        emptyLabel: String?,
        placeholder: String
    ) -> some View {
        let isCustom = !selection.wrappedValue.isEmpty
            && !choices.contains { $0.id == selection.wrappedValue }

        return VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { isCustom ? Self.customTag : selection.wrappedValue },
                set: { picked in
                    // Switching *to* custom keeps whatever is there and hands the user
                    // a field; it must not clear a valid id they are editing.
                    guard picked != Self.customTag else { return }
                    selection.wrappedValue = picked
                    model.save()
                }
            )) {
                if let emptyLabel { Text(emptyLabel).tag("") }
                ForEach(choices) { choice in
                    Text(label(for: choice)).tag(choice.id)
                }
                Text(isCustom ? "Custom: \(selection.wrappedValue)" : "Custom…")
                    .tag(Self.customTag)
            }
            .labelsHidden()

            if isCustom || choices.isEmpty {
                TextField(placeholder, text: selection)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.save() }
                    .onChange(of: selection.wrappedValue) { model.save() }
            }
            if choices.isEmpty {
                note("""
                    \(model.kind.label) routes by names its own configuration defines, \
                    so there is nothing to offer — type the id it serves.
                    """,
                     icon: "info.circle", tint: .secondary)
            }
        }
    }

    /// A catalogue entry as one line: what it is, whether it can see, and when to pick it.
    private func label(for choice: ModelChoice) -> String {
        var parts = [choice.label]
        parts.append(choice.vision ? "vision" : "no vision")
        if let note = choice.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint == .secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
