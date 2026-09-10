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
    /// Whether actions will run without stopping for approval.
    ///
    /// Shown only when true — see `refreshConfigurationLine`. Held as a `Bool` rather
    /// than as the mode itself because the overlay's job is to answer one question,
    /// "will this stop and ask me", and the four `PermissionMode` cases answer several.
    @Published var autoApproves = false
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
    /// What the user is typing in reply to a question from the agent.
    ///
    /// Its own field, never `draft`. A question and an instruction are answered in the
    /// same place on screen and mean entirely different things — one continues a tool
    /// call, the other starts a task — and a single buffer would leave whichever came
    /// second pre-filled with the first.
    @Published var answer: String = ""
    /// The voice session's own state, on its own object.
    ///
    /// Not `@Published`: it is an `ObservableObject` in its own right, and the whole
    /// point is that its twenty-a-second level updates do not invalidate this one. A
    /// `let` so that identity never changes and the views observing it never re-subscribe.
    let meter = VoiceMeter()

    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onApproval: (Bool) -> Void = { _ in }
    /// The user's reply to a question. Empty means they skipped it.
    ///
    /// A `String` rather than an `AskUserTool.Answer` so this surface cannot express
    /// `.unavailable` — that case means *nobody was there*, and a view being looked at
    /// by the person it is asking is the one place that can never be true.
    var onAnswer: (String) -> Void = { _ in }
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
    /// Separate from `inputFocused` because the two fields are never on screen
    /// together and must never share a focus binding: a question is not an instruction.
    @FocusState private var answerFocused: Bool
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

            case let .awaitingAnswer(question):
                questionPrompt(question)

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
        // Escape means "deny this action" while an approval is showing, "skip this
        // question" while one is showing, and "stop the run" otherwise. Routing all
        // three through one handler removes any dependence on whether a button's key
        // equivalent consumes the event first — if both fired, a single keypress would
        // deny the tool *and* abort the whole run.
        //
        // A question is skipped rather than stopped for the same reason Escape denies
        // rather than aborts: the key resolves whatever the overlay is blocked on, and
        // the run survives it. Stopping is what the Stop control is for, and it stays
        // reachable from here — see `activityPanel`.
        .onExitCommand {
            if case .awaitingApproval = model.state {
                model.onApproval(false)
            } else if case .awaitingAnswer = model.state {
                model.onAnswer("")
            } else {
                model.onEscape()
            }
        }
    }

    /// The input and everything that describes what pressing Return will do.
    ///
    /// Shown wherever the overlay is, not only where an instruction is typed.
    ///
    /// It lived inside `readyForInput`, which meant it was on screen at the one moment it
    /// was least needed — before anything had happened — and gone during the run, the
    /// approval and the verdict. Auto-approve is a claim about what is happening *now*:
    /// that the clicks and keystrokes going into the user's Mac are not stopping to ask.
    /// The moment to be able to see that is while they are happening.
    @ViewBuilder
    private var autoApproveBadge: some View {
        if model.autoApproves {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 9))
                Text("Auto").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
            .help("Actions run without asking. Irreversible ones still prompt.")
        }
    }

    /// One view for every state that accepts an instruction, so the field, the
    /// configuration line and the carried-context line cannot drift apart between the
    /// first instruction and the fifth.
    @ViewBuilder
    private var readyForInput: some View {
        // The indicator stands in for the field only while a session is running.
        // Replacing it outright would take typing away from every user without a
        // Deepgram key, and from every task that is easier typed than said.
        if let phase = model.meter.phase {
            LiveAudioIndicator(meter: model.meter, phase: phase)
        } else {
            inputField
        }
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
            autoApproveBadge
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
                Spacer(minLength: 8)
                // Here of all places. A prompt appearing while auto-approve is on looks
                // like the setting failed to apply unless something says otherwise —
                // and what it actually means is the opposite: this is one of the calls
                // that asks whatever the setting says, which is the reassurance the
                // badge's own help text spells out.
                autoApproveBadge
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

    /// A question from the agent, framed by the tool rather than by this view.
    ///
    /// **The whole point is that this cannot be mistaken for the prompt above it.**
    /// `AskUserTool` spends a type on that: the header, the caveat and the answer
    /// prompt are `static let`s the model cannot reach, its own words are reduced to a
    /// single prefixed line, and a question shaped like the gate's offer is refused
    /// rather than displayed. Every one of those defences is spent at this step,
    /// because the user answers what they *see* — so a panel that invented its own
    /// wording, or dropped the caveat to save a line, or offered the answer as a pair
    /// of buttons, would hand back exactly the ambiguity the tool paid to remove.
    ///
    /// So: no wording of ours. `question.header`, `question.caveat` and `question.line`
    /// are rendered as they arrive, the caveat unconditionally and never behind a
    /// disclosure. What this view chooses is colour and layout, the same latitude the
    /// CLI's asker takes.
    ///
    /// And it is built to *look* unlike an approval, not merely to differ in text. The
    /// approval is a warning triangle or a raised hand in red or yellow over a
    /// monospaced command with Approve and Deny under it. This is a tinted speech
    /// bubble over a sentence in prose, and under it a text field — which is the
    /// strongest signal available, because an approval has never had one and cannot
    /// grow one: there is nothing to type at a question that is answered yes or no.
    private func questionPrompt(_ question: AskUserTool.Question) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(.tint)
                Text(question.header)
                    .font(.system(size: 14, weight: .semibold))
                // Never conditional, never truncated away. This line is the difference
                // between a question and a consent the model was never granted.
                Text(question.caveat)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // Prose, not monospace: the approval shows a command, this shows a
            // sentence, and the typeface is part of telling them apart. Already one
            // line, already sanitised, already prefixed — see `Question.line`.
            Text(question.line)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.tint)
                // The tool's own answer prompt as the placeholder, so "Return to skip"
                // is stated by the same constant the CLI prints and cannot drift from
                // what this field actually does.
                TextField(question.answerPrompt, text: $model.answer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...3)
                    .focused($answerFocused)
                    .onSubmit { model.onAnswer(model.answer) }
                    .onAppear { answerFocused = true }
                // Visible, because a skip that only exists as a keystroke is a skip
                // most people will not find — and a question nobody can get out of is
                // a blocked run. Plain and secondary: it is a way past, not a choice
                // being offered, and nothing here should read as a pair of options.
                Button("Skip") { model.onAnswer("") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .help("Answer nothing and let the run continue")
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
            if activityIsExpanded, !model.activity.isEmpty {
                ActivityListView(
                    entries: model.activity.entries, elided: model.activity.elided
                )
            }
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
        return "\(count) · \(latest.line)"
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
            // On the row that is on screen for the whole of a run, and for the verdict
            // after it. This is where "the agent is not asking before it acts" is a live
            // fact rather than a setting somebody chose once.
            autoApproveBadge
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}

/// The expanded log, as its own view.
///
/// Extracted from `OverlayView` for one reason, and it is the main fix here: an
/// activity update writes `OverlayModel.activity`, which fires `objectWillChange` on
/// the whole model — so every tool event invalidated the input field, the
/// configuration line, the status row and the approval prompt along with the log. A
/// child view whose inputs are `Equatable` is compared before its body runs, so a
/// state change that leaves the entries alone no longer rebuilds the list, and an
/// entry appended no longer rebuilds the rest of the overlay.
private struct ActivityListView: View {

    let entries: [ActivityLog.Entry]
    let elided: Int

    /// Height of the pane while it is open.
    ///
    /// Fixed, not content-derived, and that is deliberate. `OverlayPanel` sets
    /// `sizingOptions = [.preferredContentSize]`, so the window is exactly as tall as
    /// what is inside it — which meant every appended row resized the panel, and since
    /// it is positioned by its bottom-left corner, growth walked the window upward
    /// under the pointer while the user was reading it. A pane that is one size the
    /// whole time it is open costs some blank space on a short log and removes an
    /// entire class of window-server churn from the middle of a run.
    private static let height: CGFloat = 190

    /// Whether the pointer is resting on the log.
    ///
    /// Auto-scroll is suspended while it is. The panel exists to show what the agent
    /// did and *especially* what it was refused, and a list that jumps to the bottom
    /// on every event is one you cannot read a denial in — the line you are looking at
    /// leaves the screen while you are looking at it. Hovering is what someone does
    /// when they stop watching and start reading, so it is the signal to hold still;
    /// moving the pointer away resumes and catches up.
    @State private var isPointerOver = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, not a plain `VStack`. The log holds up to
                // `ActivityLog.capacity` entries and about thirteen of them fit, so an
                // eager stack built two hundred rows on every update to show fourteen
                // — during exactly the bursts of tool activity where the main thread
                // has least to spare.
                LazyVStack(alignment: .leading, spacing: 3) {
                    if elided > 0 {
                        // Said, not hidden. What is on screen is the end of the run,
                        // and a panel that quietly dropped the beginning would read as
                        // the whole of it.
                        Text("… \(elided) earlier steps are no longer kept")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 2)
                    }
                    // `ForEach` over `Identifiable` already keys on `entry.id`; the
                    // explicit `.id(entry.id)` that used to be here was redundant, and
                    // an `.id` inside a `ForEach` is a good way to get a teardown
                    // rather than a move the day the two disagree.
                    ForEach(entries) { entry in
                        ActivityRow(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.height)
            .onHover { isPointerOver = $0 }
            .onChange(of: entries.last?.id) { _, id in
                guard let id, !isPointerOver else { return }
                scroll(proxy, to: id)
            }
            .onChange(of: isPointerOver) { _, over in
                // Catch up on the way out, so pausing to read never leaves the pane
                // stranded in the middle of a run that has moved on.
                guard !over, let id = entries.last?.id else { return }
                scroll(proxy, to: id)
            }
            .onAppear {
                // Deferred a tick on purpose. A `LazyVStack` has not laid out its rows
                // when `onAppear` fires, and `scrollTo` for a row that does not exist
                // yet does nothing at all — silently, which is how a pane opens showing
                // the oldest entry in a two-hundred-line log. Re-read at the point it
                // runs rather than captured, so opening the pane during a burst lands
                // on whatever is newest by then.
                Task { @MainActor in
                    if let id = entries.last?.id { scroll(proxy, to: id) }
                }
            }
        }
    }

    /// Scrolls with animation explicitly off.
    ///
    /// A `scrollTo` inherits whatever transaction is in flight, and during a burst the
    /// enclosing state change frequently is one — so each append started an animated
    /// scroll that the next append retargeted a few milliseconds later, which is the
    /// stutter this panel was reported for. There is nothing to animate anyway: the
    /// destination is one row further down, every time.
    private func scroll(_ proxy: ScrollViewProxy, to id: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
    }
}

/// One entry, as its own view so `LazyVStack` can skip the ones that are off screen.
///
/// `Equatable` inputs again: an entry is immutable once appended, so a row that is
/// already on screen never has to be rebuilt, whatever else the overlay is doing.
private struct ActivityRow: View {

    let entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.symbol(for: entry.kind))
                .font(.system(size: 9))
                .foregroundStyle(Self.tint(for: entry.kind))
                .frame(width: 11, alignment: .center)
            Text(entry.line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.kind == .instruction ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    static func symbol(for kind: ActivityLog.Entry.Kind) -> String {
        switch kind {
        case .instruction: return "text.cursor"
        case .started: return "arrow.right"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .denied: return "hand.raised.fill"
        case .skipped: return "minus"
        }
    }

    static func tint(for kind: ActivityLog.Entry.Kind) -> Color {
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
}
