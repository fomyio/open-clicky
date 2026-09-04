import Foundation
import CoreGraphics

/// Holds the most recent screenshot so pixel coordinates from the model can be
/// mapped back onto the screen.
///
/// Without this, a click at coordinates read off a downscaled image lands in the
/// wrong place — the single most common computer-use bug.
public actor ScreenContext {
    public static let shared = ScreenContext()
    private var last: Screenshot?

    public func record(_ screenshot: Screenshot) { last = screenshot }

    /// Maps an image-space point to screen space using the last screenshot.
    ///
    /// Fails loudly when no screenshot has been taken: silently treating image
    /// pixels as screen points would click somewhere plausible but wrong.
    public func screenPoint(fromImage point: CGPoint) throws -> CGPoint {
        guard let last else {
            throw ScreenToolError.noScreenshot
        }
        return last.screenPoint(fromImage: point)
    }

    public var lastScreenshot: Screenshot? { last }
}

public enum ScreenToolError: Swift.Error, CustomStringConvertible {
    case noScreenshot
    public var description: String {
        "No screenshot has been taken yet, so image coordinates cannot be mapped to the screen. Call `screenshot` first."
    }
}

/// Tier 3 — capture the screen.
public struct ScreenshotTool: Tool {
    public let name = "screenshot"
    public let tier = Tier.pixels
    public let description = """
    Capture the screen as an image. This is the most expensive capability — roughly \
    1,500 vision tokens per call and about a second of latency — so reach for it only \
    after `shell`, `app_script` and `ax_capture` have come up short, or when what \
    matters is genuinely visual (a chart, an image, a canvas, a custom-drawn UI, or \
    confirming that something looks right).

    The image is downscaled, so fine text may be unreadable; use `zoom` on a region \
    to read it rather than capturing the whole screen at higher resolution.

    Coordinates you read off this image are in its pixel space, and `click`, `drag` \
    and `scroll` expect exactly that — do not try to convert them yourself.
    """

    public var inputSchema: JSONValue {
        .schema([
            "region": .string(describing: "Optional area of the desktop as \"x,y,width,height\" in global screen points. Omit to capture a whole display. On a multi-monitor setup the display containing the region is used."),
            "display_id": .integer(describing: "Which display to capture. Omit for the main display, or give a region instead."),
        ], required: [])
    }

    private let excludedBundleIDs: [String]

    public init(excludedBundleIDs: [String] = []) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        do {
            let shot = try await ScreenCapture.shared.capture(
                displayID: input["display_id"]?.intValue.map(CGDirectDisplayID.init),
                region: input["region"]?.stringValue.flatMap(parseRect),
                excludingBundleIDs: excludedBundleIDs
            )
            await ScreenContext.shared.record(shot)
            return .image(
                mediaType: "image/jpeg",
                base64: shot.jpegBase64,
                note: "Screenshot: \(shot.summary). Give coordinates in this image's pixel space."
            )
        } catch let error as ScreenCapture.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — full-resolution crop of a region.
public struct ZoomTool: Tool {
    public let name = "zoom"
    public let tier = Tier.pixels
    public let description = """
    Capture part of the last screenshot again at full resolution. Use this to read \
    text too small to make out, or to inspect a control closely — far cheaper than \
    raising the resolution of a whole-screen capture, and the right way to recover \
    detail you are missing.

    Give the region in the last screenshot's pixel space, exactly as you would for \
    `click`. The crop that comes back has its own pixel space, so coordinates read \
    from it apply to it.
    """

    public var inputSchema: JSONValue {
        .schema([
            "x": .integer(describing: "Left edge, in the last screenshot's pixel space."),
            "y": .integer(describing: "Top edge, in the last screenshot's pixel space."),
            "width": .integer(describing: "Width of the region, in the last screenshot's pixels."),
            "height": .integer(describing: "Height of the region, in the last screenshot's pixels."),
        ], required: ["x", "y", "width", "height"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let width = try input.double("width")
        let height = try input.double("height")
        guard width >= 1, height >= 1 else {
            return .failure("`width` and `height` must each be at least 1.")
        }

        do {
            // Converted through the same mapping `click` uses. Asking the model for
            // screen points here while every other tool speaks image pixels would put
            // the conversion on its side of the boundary, which is precisely where
            // coordinate errors come from.
            let origin = try await ScreenContext.shared.screenPoint(
                fromImage: CGPoint(x: try input.double("x"), y: try input.double("y"))
            )
            let corner = try await ScreenContext.shared.screenPoint(
                fromImage: CGPoint(x: try input.double("x") + width,
                                   y: try input.double("y") + height)
            )
            let rect = CGRect(
                x: origin.x, y: origin.y,
                width: max(corner.x - origin.x, 1), height: max(corner.y - origin.y, 1)
            )

            // No downscale: the whole point is to recover the detail the overview lost.
            let shot = try await ScreenCapture.shared.capture(
                region: rect, longEdge: 2400, quality: 0.9
            )
            await ScreenContext.shared.record(shot)
            return .image(
                mediaType: "image/jpeg",
                base64: shot.jpegBase64,
                note: "Zoom: \(shot.summary). Coordinates you read here are in this crop's pixel space."
            )
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch let error as ScreenCapture.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — synthetic mouse click at image coordinates.
public struct ClickTool: Tool {
    public let name = "click"
    public let tier = Tier.pixels
    public let description = """
    Click at a point on the most recent screenshot, in that image's pixel space. \
    Prefer `ax_press` when the target appears in an `ax_capture` — pressing an element \
    by id always hits, whereas a predicted coordinate may not.

    After clicking, verify the result (`ax_capture` is cheapest) rather than assuming \
    it worked.
    """

    public var inputSchema: JSONValue {
        .schema([
            "x": .integer(describing: "X coordinate in the last screenshot's pixel space."),
            "y": .integer(describing: "Y coordinate in the last screenshot's pixel space."),
            "button": .string(describing: "Which button. Defaults to left.", enum: ["left", "right", "middle"]),
            "count": .integer(describing: "Click count: 1 for single, 2 for double. Default 1."),
        ], required: ["x", "y"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        let x = input["x"]?.intValue ?? 0, y = input["y"]?.intValue ?? 0
        let button = input["button"]?.stringValue ?? "left"
        let count = input["count"]?.intValue ?? 1
        return .write(summary: "\(count > 1 ? "double-" : "")\(button)-click at (\(x), \(y)) in the screenshot")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let imagePoint = CGPoint(x: try input.double("x"), y: try input.double("y"))
        let button = InputInjector.MouseButton(
            rawValue: input.string("button", default: "left")
        ) ?? .left
        let count = min(max(input.int("count", default: 1), 1), 3)

        do {
            let screenPoint = try await ScreenContext.shared.screenPoint(fromImage: imagePoint)
            // Show where the click is going before it lands, so the action is legible
            // and the user has a moment to stop it.
            await CursorStage.shared.travel(to: screenPoint)
            let outcome = try await Verified.act(
                describing: "Clicked (\(Int(imagePoint.x)), \(Int(imagePoint.y))) in image space → screen (\(Int(screenPoint.x)), \(Int(screenPoint.y)))"
            ) {
                try InputInjector.click(at: screenPoint, button: button, count: count)
            }
            return .text(outcome)
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — drag between two image-space points.
public struct DragTool: Tool {
    public let name = "drag"
    public let tier = Tier.pixels
    public let description = """
    Press at one point, move to another, and release — for sliders, selections, \
    reordering, and drag-and-drop. Both points are in the last screenshot's pixel space.
    """

    public var inputSchema: JSONValue {
        .schema([
            "from_x": .integer(describing: "Starting X in the last screenshot's pixel space."),
            "from_y": .integer(describing: "Starting Y in the last screenshot's pixel space."),
            "to_x": .integer(describing: "Ending X in the last screenshot's pixel space."),
            "to_y": .integer(describing: "Ending Y in the last screenshot's pixel space."),
        ], required: ["from_x", "from_y", "to_x", "to_y"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "drag from (\(input["from_x"]?.intValue ?? 0), \(input["from_y"]?.intValue ?? 0)) to (\(input["to_x"]?.intValue ?? 0), \(input["to_y"]?.intValue ?? 0))")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let from = CGPoint(x: try input.double("from_x"), y: try input.double("from_y"))
        let to = CGPoint(x: try input.double("to_x"), y: try input.double("to_y"))
        do {
            let start = try await ScreenContext.shared.screenPoint(fromImage: from)
            let end = try await ScreenContext.shared.screenPoint(fromImage: to)
            await CursorStage.shared.travel(to: start)
            let outcome = try await Verified.act(
                describing: "Dragged to (\(Int(to.x)), \(Int(to.y))) in image space"
            ) {
                try InputInjector.drag(from: start, to: end)
            }
            return .text(outcome)
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — type literal text into whatever holds focus.
public struct TypeTool: Tool {
    public let name = "type"
    public let tier = Tier.pixels
    public let description = """
    Type text into the focused control. Text longer than a line is pasted via the \
    clipboard (the previous clipboard contents are restored afterwards).

    Prefer `ax_set_value` when the field appears in an `ax_capture` — setting a value \
    directly cannot drop characters or land in the wrong field.
    """

    public var inputSchema: JSONValue {
        .schema(["text": .string(describing: "The literal text to type.")], required: ["text"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "type \"\((input["text"]?.stringValue ?? "").truncated(80))\"")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let text = try input.string("text")
        do {
            let outcome = try await Verified.act(describing: "Typed \(text.count) characters") {
                try InputInjector.type(text)
            }
            return .text(outcome)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — key combinations.
public struct KeyTool: Tool {
    public let name = "key"
    public let tier = Tier.pixels
    public let description = """
    Send a key or key combination, e.g. `cmd+s`, `cmd+shift+4`, `Return`, `Escape`, \
    `Tab`, `Left`. Modifiers are cmd, ctrl, alt/option, shift and fn, joined with `+`.

    Keyboard shortcuts are often the most reliable way to drive a Mac app — usually \
    better than hunting for a button to click.
    """

    public var inputSchema: JSONValue {
        .schema([
            "combo": .string(describing: "The key or combination, e.g. \"cmd+s\" or \"Escape\"."),
            "repeat_count": .integer(describing: "How many times to send it. Default 1."),
        ], required: ["combo"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        let combo = input["combo"]?.stringValue ?? ""
        // Shortcuts that quit, close or delete lose work, and a mistaken one is
        // not recoverable — hold these to the destructive bar.
        let destructive = ["cmd+q", "cmd+w", "cmd+shift+q", "cmd+delete", "cmd+shift+delete"]
        return destructive.contains(combo.lowercased())
            ? .dangerous(summary: "press \(combo)")
            : .write(summary: "press \(combo)")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let combo = try input.string("combo")
        let count = min(max(input.int("repeat_count", default: 1), 1), 50)
        do {
            let outcome = try await Verified.act(
                describing: "Pressed \(combo)\(count > 1 ? " ×\(count)" : "")"
            ) {
                try InputInjector.key(combo: combo, repeatCount: count)
            }
            return .text(outcome)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — scroll wheel.
public struct ScrollTool: Tool {
    public let name = "scroll"
    public let tier = Tier.pixels
    public let description = """
    Scroll at a point on the last screenshot. Positive `delta_y` scrolls up, \
    negative scrolls down.
    """

    public var inputSchema: JSONValue {
        .schema([
            "x": .integer(describing: "X in the last screenshot's pixel space."),
            "y": .integer(describing: "Y in the last screenshot's pixel space."),
            "delta_y": .integer(describing: "Vertical scroll in pixels. Negative scrolls down."),
            "delta_x": .integer(describing: "Horizontal scroll in pixels. Default 0."),
        ], required: ["x", "y", "delta_y"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "scroll \(input["delta_y"]?.intValue ?? 0)px")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let imagePoint = CGPoint(x: try input.double("x"), y: try input.double("y"))
        do {
            let screenPoint = try await ScreenContext.shared.screenPoint(fromImage: imagePoint)
            try InputInjector.scroll(
                deltaX: input.int("delta_x", default: 0),
                deltaY: try input.int("delta_y"),
                at: screenPoint
            )
            return .text("Scrolled at (\(Int(imagePoint.x)), \(Int(imagePoint.y))).")
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — wait for the UI to settle.
public struct WaitTool: Tool {
    public let name = "wait"
    public let tier = Tier.pixels
    public let description = """
    Pause before observing again — for a window to open, a page to load, or an \
    animation to finish. Cheaper than re-screenshotting in a loop.
    """

    public var inputSchema: JSONValue {
        .schema([
            "seconds": .integer(describing: "How long to wait, 1 to 30."),
        ], required: ["seconds"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let seconds = min(max(try input.int("seconds"), 1), 30)
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        return .text("Waited \(seconds)s.")
    }
}

/// Parses `"x,y,width,height"` into a rect.
private func parseRect(_ text: String) -> CGRect? {
    let parts = text.split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}
