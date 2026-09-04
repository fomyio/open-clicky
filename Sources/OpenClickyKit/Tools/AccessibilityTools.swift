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

    Use this before taking a screenshot. It is far cheaper, and acting on an \
    element id is reliable in a way that clicking a predicted coordinate is not. \
    Take a screenshot only when this does not tell you what you need — a canvas, \
    an image, a custom-drawn UI, or anything where visual appearance is the point.

    Ids are only valid until the UI changes. Re-capture after anything that \
    redraws the window.
    """

    public var inputSchema: JSONValue {
        .schema([
            "bundle_identifier": .string(describing: "Read this app instead of the frontmost one, e.g. com.apple.Safari."),
            "interactive_only": .boolean(describing: "Return only actionable controls, omitting layout containers. Default false."),
            "max_depth": .integer(describing: "How deep to descend the tree. Default 12."),
        ], required: [])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        do {
            let capture = try await AXCapture.shared.capture(
                bundleIdentifier: input["bundle_identifier"]?.stringValue,
                maxDepth: input.int("max_depth", default: 12),
                interactiveOnly: input.bool("interactive_only", default: false)
            )
            guard !capture.nodes.isEmpty else {
                return .text("\(capture.app): no accessible elements. The app may draw a custom UI — take a screenshot instead.")
            }
            let body = capture.nodes.map(\.line).joined(separator: "\n")
            return .text("""
            \(capture.app) — \(capture.nodes.count) elements
            Ids after # are usable with ax_press / ax_set_value. Coordinates after @ are screen points.

            \(body)
            """)
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
    """

    public var inputSchema: JSONValue {
        .schema([
            "element_id": .string(describing: "Element id from ax_capture, e.g. e12."),
            "action": .string(
                describing: "Accessibility action to perform. Defaults to AXPress.",
                enum: ["AXPress", "AXIncrement", "AXDecrement", "AXShowMenu", "AXConfirm", "AXCancel", "AXPick"]
            ),
        ], required: ["element_id"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        let id = input["element_id"]?.stringValue ?? "?"
        return .write(summary: "activate element \(id) via accessibility")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let id = try input.string("element_id")
        let action = input.string("action", default: kAXPressAction)
        do {
            try await AXCapture.shared.perform(action: action, on: id)
            return .text("Performed \(action) on \(id). Call ax_capture again to see the result.")
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
        return .write(summary: "set element \(id) to \"\(value.truncated(60))\"")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let id = try input.string("element_id")
        let value = try input.string("value")
        do {
            try await AXCapture.shared.setValue(value, on: id)
            return .text("Set \(id) to \"\(value.truncated(80))\".")
        } catch let error as AXCapture.Error {
            return .failure(error.description)
        }
    }
}
