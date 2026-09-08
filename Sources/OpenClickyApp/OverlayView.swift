import SwiftUI
import OpenClickyKit

/// Observable mirror of `SessionController`'s state, for SwiftUI.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: SessionState = .dormant
    @Published var draft: String = ""
    /// What is about to run this, in one line — the provider, the model, the planner
    /// and the tier ceiling that follows from them.
    @Published var configuration: String = ""
    /// Whether that configuration can actually start a run. False turns the line into
    /// a warning rather than a status.
    @Published var configurationIsUsable = true
    /// What the next instruction carries from the ones before it, or empty for a
    /// conversation that has not started. See `Conversation.summary`.
    @Published var conversation: String = ""
    /// Whether there is a conversation for "New conversation" to end. The control is
    /// hidden rather than disabled when there is not: a button that clears nothing
    /// invites the user to press it to find out.
    @Published var carriesContext = false
    /// Every call this conversation has made. The panel under the input renders it;
    /// the rule for what goes in and how much is kept lives in `ActivityLog`.
    @Published var activity = ActivityLog()

    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onApproval: (Bool) -> Void = { _ in }
    var onStartOver: () -> Void = {}
}

/// The overlay's contents.
///
/// Deliberately small: one line of status, one input, and an approval prompt. A
/// foreground agent's UI competes with whatever the user is actually doing, so it
/// earns its space by staying out of the way.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var inputFocused: Bool
    /// Collapsed by default, and remembered for as long as the overlay exists. A
    /// foreground agent's window sits over the user's work, so the panel opens because
    /// someone opened it — but having opened it once to watch a run, they should not
    /// have to open it again for the next instruction.
    @State private var activityIsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .dormant:
                EmptyView()

            case .accepting:
                readyForInput

            case let .working(activity):
                statusRow(icon: "gearshape.2", tint: .secondary, text: activity)

            case let .awaitingApproval(approval):
                approvalPrompt(approval)

            // A finished task leaves the verdict on screen *and* the field under it.
            // The overlay no longer dismisses itself, because the end of a task is the
            // start of the next instruction — and the verdict has to survive that, or
            // the work spent making "nothing was done" and "did not finish" honest is
            // undone by the surface that shows them.
            case let .finished(summary, cost):
                statusRow(icon: "checkmark.circle", tint: .green, text: summary)
                if let cost { hint(cost) }
                readyForInput

            case let .stopped(reason):
                statusRow(icon: "stop.circle", tint: .orange, text: reason)
                readyForInput
            }

            // Under every state that has one, rather than inside the working branch.
            // The record of what a run did is worth reading *after* it ends — the
            // verdict says whether anything was accomplished, and this says what was
            // attempted — and Stop has to be reachable from the approval prompt too,
            // where the run is just as live and rather more stuck.
            activityPanel
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        // Escape means "deny this action" while an approval is showing and "stop the
        // run" otherwise. Routing both through one handler removes any dependence on
        // whether the Deny button's key equivalent consumes the event first — if both
        // fired, a single keypress would deny the tool *and* abort the whole run.
        .onExitCommand {
            if case .awaitingApproval = model.state {
                model.onApproval(false)
            } else {
                model.onEscape()
            }
        }
    }

    /// The input and everything that describes what pressing Return will do.
    ///
    /// One view for every state that accepts an instruction, so the field, the
    /// configuration line and the carried-context line cannot drift apart between the
    /// first instruction and the fifth.
    @ViewBuilder
    private var readyForInput: some View {
        inputField
        // Under the input, not in a menu: which model is about to drive the
        // Mac decides whether it can see the screen at all, and the overlay
        // was the one surface that never said.
        HStack(spacing: 8) {
            if !model.configuration.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: model.configurationIsUsable
                          ? "cpu" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(model.configurationIsUsable
                                         ? Color.secondary.opacity(0.6) : Color.orange)
                    Text(model.configuration)
                        .font(.system(size: 11))
                        .foregroundStyle(model.configurationIsUsable
                                         ? Color.secondary.opacity(0.7) : Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // Visible, next to the thing it acts on, rather than a keystroke someone
            // has to be told about: a session that cannot be reset grows without bound
            // and traps the user in an old thread, so the way out has to be on screen
            // at the moment they notice they want it. Also in the menu-bar menu, for
            // when the overlay is not up.
            if model.carriesContext {
                Button("New conversation") { model.onStartOver() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            }
        }
        if !model.conversation.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                Text(model.conversation)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.tint)
            TextField("What should I do?", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { model.onSubmit(model.draft) }
                .onAppear { inputFocused = true }
        }
    }

    private func approvalPrompt(_ approval: SessionState.Approval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: approval.isDestructive
                      ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .foregroundStyle(approval.isDestructive ? .red : .yellow)
                Text(approval.isDestructive ? "This is destructive" : "Approve this action?")
                    .font(.system(size: 14, weight: .semibold))
                Text(approval.tool)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Scrolls rather than clipping: a summary the user cannot finish reading
            // is a summary they cannot meaningfully approve.
            ScrollView {
                Text(approval.summary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)

            HStack(spacing: 8) {
                // Return approves an ordinary action; a destructive one needs
                // Command-Return, so a stray keypress cannot authorise it. The
                // condition lives on Approval so it is testable — this view is not.
                if approval.acceptsBareReturn {
                    Button("Approve") { model.onApproval(true) }
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Approve ⌘⏎") { model.onApproval(true) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                // No Escape key equivalent here: onExitCommand above owns that key
                // for the whole overlay and routes it to this same action.
                Button("Deny") { model.onApproval(false) }
                Spacer()
            }
        }
    }

    // MARK: - Activity

    /// The disclosure strip, the Stop control, and the log itself when it is open.
    ///
    /// Everything it renders came out of `SessionController.activity`, which is fed
    /// from the same event stream the status line is and stores each string exactly as
    /// the loop emitted it. That is deliberate and it is the security property: a tool
    /// result whose output `Policy.printsSecret` withheld from the model was replaced
    /// *inside the tool*, so what arrives here is already the withheld-output note and
    /// there is no second copy of the real thing for this panel to find.
    @ViewBuilder
    private var activityPanel: some View {
        // Nothing at all when the overlay is dormant. The panel is ordered out in that
        // state so it would not be seen either way, but a hidden window whose content
        // is still a hundred rows tall is a window that reappears the wrong size.
        if model.state.isVisible, !model.activity.isEmpty || model.state.isInterruptible {
            Divider().opacity(0.35)
            HStack(spacing: 8) {
                if !model.activity.isEmpty { activityDisclosure }
                Spacer(minLength: 8)
                // Escape has been the only way to stop a run, and it only works while
                // this panel holds keyboard focus — which a `.nonactivatingPanel`
                // hosting a SwiftUI focus engine does not reliably grant. A run that
                // cannot be stopped is the worst thing this application can do, so the
                // way to stop it is now on screen and does not depend on a key event
                // arriving. The shortcut is named on the button rather than in a
                // separate hint, so the two cannot advertise different keys.
                if model.state.isInterruptible { stopButton }
            }
            if activityIsExpanded, !model.activity.isEmpty { activityList }
        }
    }

    private var activityDisclosure: some View {
        Button {
            activityIsExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: activityIsExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                Text(collapsedSummary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.secondary.opacity(0.8))
            // The whole strip is the target, not just the glyph: a 9pt chevron is a
            // thing you miss twice before you hit it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(activityIsExpanded ? "Hide what the agent is doing" : "Show what the agent is doing")
    }

    /// What the strip says while it is shut.
    ///
    /// A count alone ("14 steps") says there is something here without saying whether
    /// it is worth opening, so the newest entry comes with it. Collapsed is the
    /// default state, which makes this line the one most people ever read.
    private var collapsedSummary: String {
        let total = model.activity.totalRecorded
        let count = total == 1 ? "1 step" : "\(total) steps"
        guard let latest = model.activity.latest else { return count }
        return "\(count) · \(line(for: latest))"
    }

    private var activityList: some View {
        // Bottom-anchored and scrolling: newest last is the order a terminal reads in,
        // and a run in flight should leave the newest line where the eye already is.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if model.activity.elided > 0 {
                        // Said, not hidden. What is on screen is the end of the run,
                        // and a panel that quietly dropped the beginning would read as
                        // the whole of it.
                        hint("… \(model.activity.elided) earlier steps are no longer kept")
                            .padding(.bottom, 2)
                    }
                    ForEach(model.activity.entries) { entry in
                        activityRow(entry).id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Capped, because the panel's height is the content's height — see
            // `OverlayPanel` — and an uncapped list of 200 rows would be a window
            // taller than the display with the input field somewhere off the top of it.
            .frame(maxHeight: 190)
            .onChange(of: model.activity.entries.last?.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onAppear {
                if let id = model.activity.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func activityRow(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol(for: entry.kind))
                .font(.system(size: 9))
                .foregroundStyle(tint(for: entry.kind))
                .frame(width: 11, alignment: .center)
            Text(line(for: entry))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.kind == .instruction ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// One entry as one line: what tier it was at, which tool, and what came back.
    private func line(for entry: ActivityLog.Entry) -> String {
        guard entry.kind != .instruction else { return entry.detail }
        let tier = entry.tier.map { "[T\($0.rawValue)] " } ?? ""
        let verb: String
        switch entry.kind {
        case .started: verb = ""
        case .succeeded: verb = "✓ "
        case .failed: verb = "✗ "
        case .denied: verb = "denied — "
        case .skipped: verb = "skipped — "
        case .instruction: verb = ""
        }
        return "\(tier)\(entry.tool): \(verb)\(entry.detail)"
    }

    private func symbol(for kind: ActivityLog.Entry.Kind) -> String {
        switch kind {
        case .instruction: return "text.cursor"
        case .started: return "arrow.right"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .denied: return "hand.raised.fill"
        case .skipped: return "minus"
        }
    }

    private func tint(for kind: ActivityLog.Entry.Kind) -> Color {
        switch kind {
        case .instruction: return .secondary
        case .started: return .secondary.opacity(0.6)
        case .succeeded: return .green
        case .failed: return .orange
        // The one thing a user watching a run is watching *for*, so it is the one
        // colour that is not a shade of the others.
        case .denied: return .yellow
        case .skipped: return .secondary.opacity(0.5)
        }
    }

    /// Stops the run, from wherever the overlay is when it is pressed.
    ///
    /// Deliberately the same callback Escape fires. `AppDelegate.handleEscape` is the
    /// single cancellation path — it cancels the run *and* answers any approval the
    /// gate is suspended inside, which a second path would have to remember to do —
    /// and a button that stopped runs its own way would be one more thing to keep in
    /// step with it. It is not routed through `onExitCommand`'s approval branch: a
    /// Stop pressed over an approval prompt means stop the run, not deny this one
    /// action, and the denial happens anyway on the way out.
    private var stopButton: some View {
        Button {
            model.onEscape()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill").font(.system(size: 9))
                Text("Stop ⎋").font(.system(size: 11))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help("Stop this run")
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}
