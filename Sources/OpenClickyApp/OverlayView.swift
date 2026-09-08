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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .dormant:
                EmptyView()

            case .accepting:
                readyForInput

            case let .working(activity):
                statusRow(icon: "gearshape.2", tint: .secondary, text: activity)
                hint("esc to stop")

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
