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

    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onApproval: (Bool) -> Void = { _ in }
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
                inputField
                // Under the input, not in a menu: which model is about to drive the
                // Mac decides whether it can see the screen at all, and the overlay
                // was the one surface that never said.
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

            case let .working(activity):
                statusRow(icon: "gearshape.2", tint: .secondary, text: activity)
                hint("esc to stop")

            case let .awaitingApproval(approval):
                approvalPrompt(approval)

            case let .finished(summary, cost):
                statusRow(icon: "checkmark.circle", tint: .green, text: summary)
                if let cost { hint(cost) }

            case let .stopped(reason):
                statusRow(icon: "stop.circle", tint: .orange, text: reason)
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
