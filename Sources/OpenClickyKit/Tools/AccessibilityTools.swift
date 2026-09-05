import Foundation
import ApplicationServices

/// Tier 2 — dump the focused window's accessibility tree as labelled text.
///
/// The workhorse of the ladder: it tells the model what is actually on screen,
/// with an addressable id per control, for a fraction of a screenshot's tokens.
public struct AXCaptureTool: Tool {
    public let name = "ax_capture"
    public let tier = Tier.accessibility
    public let description = """
    Read the structure of the frontmost window as text: every control, its role, \
    label, value and centre point. Interactive elements are tagged with an id \
    (`#e12`) that `ax_press` and `ax_set_value` accept.

    Use this before taking a screenshot. About 1,000 tokens against a screenshot's \
    2,000, and — the part that matters more — acting on an element id hits what you \
    meant, where a coordinate predicted from an image may quietly miss. Take a \
    screenshot only when this does not tell you what you need: a canvas, an image, a \
    custom-drawn UI, or anything where visual appearance is the point.

    `interactive_only: true` drops layout containers, which helps on windows built \
    from deep nesting and barely at all on ones that are mostly controls.

    Ids are only valid until the UI changes. Re-capture after anything that \
    redraws the window.
    """

    public var inputSchema: JSONValue {
        .schema([
            "bundle_identifier": .string(describing: "Read this app instead of the frontmost one, e.g. com.apple.Safari."),
            "interactive_only": .boolean(describing: "Return only actionable controls, omitting layout containers. Default false."),
            "max_depth": .integer(describing: "How deep to descend the tree. Default 12."),
            "max_nodes": .integer(describing: "Cap on elements returned. Default 400, maximum 2000. Raise this if a capture reports being incomplete."),
        ], required: [])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        do {
            let capture = try await AXCapture.shared.capture(
                bundleIdentifier: input["bundle_identifier"]?.stringValue,
                maxDepth: input.int("max_depth", default: 12),
                maxNodes: min(max(input.int("max_nodes", default: 400), 1), 2_000),
                interactiveOnly: input.bool("interactive_only", default: false)
            )
            guard !capture.nodes.isEmpty else {
                return .text("\(capture.app): no accessible elements. The app may draw a custom UI — take a screenshot instead.")
            }

            var header = "\(capture.app) — \(capture.nodes.count) elements"
            if capture.filteredToInteractive {
                header += " (interactive only, of \(capture.totalNodesWalked) walked)"
            }

            var lines = [
                header,
                "Ids after # work with ax_press / ax_set_value; actions in [brackets] are what that element supports beyond a press. Coordinates after @ are screen points.",
            ]
            // Surfaced before the tree, so it is read rather than scrolled past.
            if let note = capture.truncationNote { lines.append("\n\(note)") }
            lines.append("")
            lines.append(capture.nodes.map(\.line).joined(separator: "\n"))

            return .text(lines.joined(separator: "\n"))
        } catch let error as AXCapture.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 2 — activate a control through the accessibility API.
public struct AXPressTool: Tool {
    public let name = "ax_press"
    public let tier = Tier.accessibility
    public let description = """
    Activate a control by the id from the most recent `ax_capture` — a real button \
    press through the accessibility API, not a synthetic click at a guessed point. \
    Prefer this over `click` whenever the element appears in a capture.

    Defaults to `AXPress`. When a capture shows other actions in square brackets \
    after the id — `#e12 [AXShowMenu,AXRaise]` — those are what that element supports, \
    and pressing an element that does not offer `AXPress` will fail.
    """

    public var inputSchema: JSONValue {
        .schema([
            "element_id": .string(describing: "Element id from ax_capture, e.g. e12."),
            // Not an enum: elements advertise actions beyond any fixed list — a live
            // window here offers AXRaise, which a closed enum made impossible to
            // invoke under strict tool use. The capture names each element's own
            // actions, which is a better source of valid values than a list here.
            "action": .string(describing: "Accessibility action to perform, as listed in square brackets beside the element in ax_capture. Defaults to AXPress."),
        ], required: ["element_id"])
    }

    public init() {}

    /// Actions known to be ordinary activations.
    ///
    /// Anything else is an app-defined verb — a row's "Delete", a custom control's
    /// own action — whose effect cannot be known from its name. Those are classified
    /// destructive so they cannot ride a session allowlist granted for a routine
    /// press, which is the guarantee `.dangerous` exists to provide.
    static let ordinaryActions: Set<String> = [
        kAXPressAction, kAXShowMenuAction, kAXPickAction, kAXRaiseAction,
        kAXCancelAction, kAXConfirmAction,
        // Not exported as a constant by ApplicationServices, but a standard action.
        "AXScrollToVisible",
    ]

    public func risk(for input: JSONValue) -> Risk {
        let id = input["element_id"]?.stringValue ?? "?"
        let action = input.string("action", default: kAXPressAction)
        // Name the action and the element: the summary previously read "activate
        // element e12" whatever the action was, which is not something a user can
        // meaningfully consent to.
        let summary = "\(action) on \(AXCapture.labels.describe(id))"

        return Self.ordinaryActions.contains(action)
            ? .write(summary: summary)
            : .dangerous(summary: "\(summary) — an app-defined action whose effect is not knowable from its name")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let id = try input.string("element_id")
        let action = input.string("action", default: kAXPressAction)
        do {
            let outcome = try await Verified.act(describing: "Performed \(action) on \(id)") {
                try await AXCapture.shared.perform(action: action, on: id)
            }
            return .text(outcome)
        } catch let error as AXCapture.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 2 — set a text field's value directly.
public struct AXSetValueTool: Tool {
    public let name = "ax_set_value"
    public let tier = Tier.accessibility
    public let description = """
    Set a text field's contents directly by element id. Faster and more reliable \
    than focusing the field and typing, and it cannot drop or reorder characters.
    """

    public var inputSchema: JSONValue {
        .schema([
            "element_id": .string(describing: "Element id from ax_capture, e.g. e12."),
            "value": .string(describing: "The text to set. Replaces the existing contents."),
        ], required: ["element_id", "value"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        let id = input["element_id"]?.stringValue ?? "?"
        let value = input["value"]?.stringValue ?? ""
        // The value can come from content the agent just read; `Risk.summary`
        // sanitises it on the way to the prompt.
        return .write(summary: "set \(AXCapture.labels.describe(id)) to \"\(value)\"")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let id = try input.string("element_id")
        let value = try input.string("value")
        do {
            // Verified like every other action. Setting a value through the
            // accessibility API can be accepted and ignored by the receiving control,
            // which looks exactly like success from here.
            let outcome = try await Verified.act(
                describing: "Set \(id) to \"\(value.truncated(80))\""
            ) {
                try await AXCapture.shared.setValue(value, on: id)
            }
            return .text(outcome)
        } catch let error as AXCapture.Error {
            return .failure(error.description)
        }
    }
}
