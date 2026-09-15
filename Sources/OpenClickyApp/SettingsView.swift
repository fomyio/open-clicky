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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                permissionsSection
                Divider()
                endpointSection
                Divider()
                modelSection
                Divider()
                plannerSection
                Divider()
                executionSection
                Divider()
                voiceSection
                Divider()
                checkSection
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
        // Ollama's list is the daemon's to answer, so it is asked when the window
        // opens rather than compiled into the build. `.task` and not `onAppear`: the
        // query is async and SwiftUI cancels it if the window closes first.
        .task { await model.refreshCatalog() }
        // Polled for as long as the window is up. macOS sends an app nothing when a
        // grant changes, so a panel that probed once would still be saying "not
        // granted" after the user had gone to System Settings and granted it — which
        // reads as the grant not having worked. SwiftUI cancels this on close.
        .task { await model.watchPermissions() }
    }

    // MARK: - Permissions

    /// What macOS is currently letting this app do, per grant and per tier.
    ///
    /// First on the window, because it is the answer to the question that brings people
    /// here. Every one of these failures is silent at the point of use: a tier-1 task
    /// dies on "osascript is not allowed to send keystrokes", a voice session hears
    /// nothing, a screenshot comes back as wallpaper. Until now the app reported none of
    /// them and `doctor` reported two of the five.
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The subject is named rather than assumed. In this window it is always the
            // app, but the same audit is printed by `doctor`, where it is the *terminal*
            // — and a reader comparing the two needs to know that before concluding one
            // of them is broken.
            heading(
                "Permissions",
                """
                What macOS is letting \(model.permissions.host.principal) do right now. \
                Refreshed while this window is open.
                """
            )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.permissions.grants) { grant in
                    grantRow(grant)
                }
            }

            ladderSummary

            if let advice = model.permissions.host.advice {
                // The account of *why* grants keep vanishing. Without it, an ad-hoc
                // build's rows flip to "denied" after every rebuild with nothing
                // anywhere to explain that this is the signature changing rather than
                // the user's grant being revoked.
                note(advice, icon: "signature", tint: .orange)
            }
        }
    }

    private func grantRow(_ grant: Grant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(for: grant.state))
                .foregroundStyle(tint(for: grant.state))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grant.kind.title).font(.system(size: 12, weight: .medium))
                    Text(grant.state.label)
                        .font(.system(size: 11))
                        .foregroundStyle(tint(for: grant.state))
                }
                Text(grant.kind.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Named per row rather than only in the ladder below, because "this is
                // the one that stops tier 1" is the fact that makes an abstract grant
                // worth walking to System Settings for.
                if !grant.kind.tiers.isEmpty, !grant.isSatisfied {
                    Text("Without it: " + grant.kind.tiers.map(\.label).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                // Shown granted or not: "granted" on a row whose probe covered one
                // target app is a claim wider than what was checked.
                if let scope = grant.kind.scope {
                    Text(scope)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = grant.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !grant.isSatisfied {
                HStack(spacing: 6) {
                    // Offered only where the system will actually show a prompt.
                    // Automation's consent dialog can only be raised by *sending* an
                    // Apple event, which means running a script nobody asked for — so
                    // that row gets the pane and no button that does nothing.
                    if grant.kind.isRequestable, grant.state != .denied {
                        Button("Request") { model.request(grant.kind) }
                    }
                    if grant.kind.settingsURL != nil {
                        Button("Open Settings") { model.openSettings(for: grant.kind) }
                    }
                    if grant.kind == .configFile {
                        Button("Repair") { model.repairConfigPermissions() }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    /// The capability ladder as four verdicts, which is the shape the rest of this app
    /// reasons in — `--max-tier`, the system prompt, the tool registry.
    private var ladderSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.permissions.ladder) { rung in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: rung.isReady ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(rung.isReady ? Color.green : .orange)
                        .frame(width: 14)
                    Text(rung.tier.label).font(.system(size: 11, weight: .medium))
                    Text(rung.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(rung.isReady ? .secondary : .primary)
                }
            }
            // The one sentence someone can act on without reading the four rows above:
            // the ladder is contiguous, so what matters is where the first gap is.
            note(
                model.permissions.isLadderComplete
                    ? "Every tier is available."
                    : """
                        A run can reach \(model.permissions.reachableTier.label). \
                        The ladder is contiguous — the agent is offered tiers 0 up to \
                        the first gap — so the topmost missing grant is not the one to \
                        fix first.
                        """,
                icon: model.permissions.isLadderComplete ? "checkmark.seal" : "info.circle",
                tint: model.permissions.isLadderComplete ? .green : .secondary
            )
        }
    }

    private func icon(for state: GrantState) -> String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .unknown: return "exclamationmark.circle"
        }
    }

    private func tint(for state: GrantState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unknown: return .orange
        }
    }

    // MARK: - Voice

    /// Who transcribes a voice session, and the key that lets one start at all.
    ///
    /// The section whose absence was the bug. A voice key could only be stored by
    /// exporting an environment variable, and this app is launched from Finder, which
    /// inherits none — so the menu item's only possible outcome was an error naming
    /// `openclicky auth --provider deepgram`, a command the parser rejects.
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(
                "Voice",
                "Who turns what you say into text. The agent's own model is unchanged — this transcribes, nothing more."
            )

            Picker("", selection: $model.voiceProvider) {
                ForEach(VoiceProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            note(model.voiceProvider.detail, icon: "waveform", tint: .secondary)

            LabeledContent("\(model.voiceProvider.label) key") {
                HStack(spacing: 8) {
                    // Write-only, like the model key above: a panel that displays the
                    // secret puts it in every screenshot of itself, including the ones
                    // this agent takes of its own window.
                    SecureField("Paste a key", text: $model.voiceKeyEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveVoiceKey() }
                    Button("Save") { model.saveVoiceKey() }
                        .disabled(model.voiceKeyEntry.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                }
            }

            HStack(spacing: 8) {
                switch model.voiceCredential {
                case .environment:
                    note("A key from your environment is in use, and it wins over the stored one.",
                         icon: "terminal", tint: .orange)
                case .stored:
                    note("Stored in \(model.config.url.path), readable only by you.",
                         icon: "checkmark.circle", tint: .green)
                    Button("Forget") { model.forgetVoiceKey() }
                        .buttonStyle(.link)
                case let .shared(entry):
                    // Said rather than shown as a plain tick, because the two keys
                    // being one key is a fact with a consequence: revoking it stops
                    // the model as well. Storing a dedicated one above unties them.
                    note("""
                        Using your stored \(entry) key — the same one the model uses, \
                        so revoking it stops both. Paste a key above to give voice its \
                        own.
                        """,
                         icon: "arrow.triangle.branch", tint: .secondary)
                case let .exposed(detail):
                    note(detail, icon: "exclamationmark.triangle.fill", tint: .red)
                case .none:
                    note("""
                        No \(model.voiceProvider.label) key stored, so a voice session \
                        cannot start. Get one at \(model.voiceProvider.signupHint).
                        """,
                         icon: "exclamationmark.triangle", tint: .orange)
                }
            }

            // Both halves, because either alone is a session that does nothing when
            // started and the two are indistinguishable from the menu item.
            if !model.permissions.canHear {
                note("""
                    Microphone access is not granted, so a session would hear nothing \
                    even with a key. It is a third grant, separate from Accessibility \
                    and Screen Recording — see Permissions above.
                    """,
                     icon: "mic.slash", tint: .orange)
            } else if model.voiceIsReady {
                note("Ready. Start one from the menu bar icon ▸ Start Voice Session.",
                     icon: "checkmark.seal", tint: .green)
            }
        }
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
                        // The base URL decides which daemon answers, so it decides
                        // which models exist. Asked again on a pause, like the save.
                        .onChange(of: model.baseURL) {
                            model.saveSoon()
                            model.refreshCatalogSoon()
                        }
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
                switch model.credential {
                case .environment:
                    note("A key from your environment is in use, and it wins over the stored one.",
                         icon: "terminal", tint: .orange)
                case .stored:
                    note("Stored in \(model.config.url.path), readable only by you.",
                         icon: "checkmark.circle", tint: .green)
                    Button("Forget") { model.forgetKey() }
                        .buttonStyle(.link)
                case let .shared(entry):
                    // Nothing sets this for a model provider today — only voice borrows
                    // a key. Rendered rather than ignored because the alternative is a
                    // row that goes blank if that ever changes, which is the silent
                    // empty state this enum was widened to prevent in the first place.
                    note("Using the stored \(entry) key.",
                         icon: "arrow.triangle.branch", tint: .secondary)
                case let .exposed(detail):
                    // Never folded into "no key stored". The file is readable by other
                    // accounts, the key in it should be treated as compromised, and an
                    // empty-looking state would let that carry on unmentioned.
                    note(detail, icon: "exclamationmark.triangle.fill", tint: .red)
                case .none:
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
                .executor,
                emptyLabel: nil,
                placeholder: model.modelPlaceholder
            )

            if !model.hasModel {
                // Said instead of the vision verdict, never beside it. "Cannot be sent
                // images" is a claim about a model, and there is none — the confident
                // sentence about nothing that this codebase keeps hunting down.
                //
                // Only two providers can reach this, and they need opposite advice: one
                // serves what this machine pulled, the other what a config file the
                // user wrote declares.
                note(model.kind == .ollama
                     ? """
                        No model chosen, so a run has nothing to call. Ollama has no \
                        default worth guessing: it serves what this machine has \
                        pulled, which `ollama list` prints, tag and all.
                        """
                     : """
                        No model chosen, so a run has nothing to call. \
                        \(model.kind.label) routes by names its own configuration \
                        defines, so only that configuration can say what to type here.
                        """,
                     icon: "exclamationmark.triangle", tint: .orange)
            }

            // The whole reason this panel exists. A model that cannot be sent an image
            // is not merely worse at tier 3 — the pixel tools are never loaded, so the
            // run works through the accessibility tree or not at all, and saying so
            // here is cheaper than the user inferring it from a run that never clicked.
            if model.hasModel {
                note(model.visionSummary,
                     icon: model.hasVision ? "eye" : "eye.slash",
                     tint: model.hasVision ? .green : .orange)
            }

            if model.hasModel, !model.hasVision {
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
                .planner,
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

    // MARK: - Execution

    /// The one control on this window that decides what happens to the user's machine
    /// rather than which endpoint answers, so what each position gives up is stated in
    /// full rather than implied by its name.
    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(
                "Execution mode",
                "Whether the agent stops for your approval before each action."
            )
            Picker("", selection: $model.executionMode) {
                ForEach(ExecutionModeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            note(model.executionMode.detail, icon: "info.circle", tint: .secondary)

            // Said on the permissive setting only, and phrased as what remains rather
            // than as a warning about what was chosen. Someone who turns this on has
            // decided; what they still need is an accurate account of the one backstop
            // left, so that meeting a prompt later reads as the promise being kept
            // rather than the setting having failed to apply.
            if model.configIsExposed {
                note("""
                    Ignored while \(model.config.url.lastPathComponent) is readable or \
                    writable by other accounts: a file anyone can edit must not be able \
                    to switch the approval prompt off. The agent is asking for now. \
                    Run `chmod 600 \(model.config.url.path)`, then set this again.
                    """,
                     icon: "lock.trianglebadge.exclamationmark", tint: .orange)
            } else if model.executionMode == .auto {
                note("""
                    The agent will click, type and run scripts on this Mac without \
                    stopping. Irreversible actions are the exception and still ask. \
                    Press Escape during a run to stop it.
                    """,
                     icon: "bolt.fill", tint: .orange)
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

    /// Which of the two model choices a picker is editing.
    private enum Role { case executor, planner }

    /// A picker over a catalogue, with a free-text escape hatch.
    ///
    /// Every decision here — which control shows, what the custom entry is called,
    /// whether a change is worth saving — belongs to `ModelPicker` in the kit, and the
    /// state belongs to `SettingsModel`. The version that derived both inline was
    /// broken in a way nothing could have caught: choosing "Custom…" while a
    /// catalogued model was selected changed no state the next redraw could see, so
    /// the field never appeared and the picker snapped back.
    ///
    /// The role is passed rather than a pair of closures because a `Binding`'s setter
    /// is `@Sendable`, and a closure parameter annotated to be both that and
    /// `@MainActor` crashes the 6.0 compiler. Bindings built inline keep the
    /// isolation they are written in, which is what every other control here does.
    ///
    /// - Parameter emptyLabel: the label for "nothing chosen", or nil where a choice
    ///   is required. The planner needs it — off is a real, and the default, answer.
    private func modelPicker(
        _ role: Role, emptyLabel: String?, placeholder: String
    ) -> some View {
        let picker = role == .executor ? model.modelPicker : model.plannerPicker

        return VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { picker.tag },
                set: { tag in
                    switch role {
                    case .executor: model.pickModel(tag)
                    case .planner: model.pickPlanner(tag)
                    }
                }
            )) {
                if let emptyLabel { Text(emptyLabel).tag(ModelPicker.noneTag) }
                ForEach(picker.choices) { choice in
                    Text(label(for: choice)).tag(choice.id)
                }
                Text(picker.customLabel).tag(ModelPicker.customTag)
            }
            .labelsHidden()

            if picker.isCustom {
                // Saved on a pause rather than per keystroke: a save rewrites the file
                // and chmods it twice, and `AppDelegate` re-reads it on every summon.
                // Return commits at once for anyone who expects it to.
                TextField(placeholder, text: Binding(
                    get: { picker.value },
                    set: { text in
                        switch role {
                        case .executor: model.typeModel(text)
                        case .planner: model.typePlanner(text)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.save() }
            }
            if picker.choices.isEmpty {
                // Two different reasons for the same empty list, and they send the user
                // to two different places. Saying "routes by names its own
                // configuration defines" under Ollama pointed at a proxy config nobody
                // has, when the answer is one command away on their own machine.
                note(model.kind == .ollama
                     ? """
                        Nothing to offer yet — this asks \(model.effectiveBaseURL) \
                        what it serves, and either it is not running or it has no \
                        models pulled. `ollama list` prints them; the id here must \
                        match one exactly, `:cloud` suffix and all.
                        """
                     : """
                        \(model.kind.label) routes by names its own configuration \
                        defines, so there is nothing to offer — type the id it serves.
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
