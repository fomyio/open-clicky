import Foundation
import CoreGraphics

/// Holds the most recent screenshot so pixel coordinates from the model can be
/// mapped back onto the screen.
///
/// Without this, a click at coordinates read off a downscaled image lands in the
/// wrong place — the single most common computer-use bug.
public actor ScreenContext {
    public static let shared = ScreenContext()

    /// One screenshot per screen, rather than one screenshot.
    ///
    /// A single slot did not merely forget the older image, it silently repointed the
    /// mapping: capturing a second monitor threw away the first monitor's `screenRect`,
    /// so a click aimed at something still plainly visible on screen 0 was converted
    /// through screen 1's rect and landed on the other monitor. No error, and nothing
    /// in the transcript the model could have read to notice.
    private var shots: [ScreenIndex: Screenshot] = [:]

    /// The screens the last observation covered — usually one, and then a coordinate
    /// that names no screen behaves exactly as it did when there was only one slot to
    /// look in. A whole-desktop `screenshot` covers several at once, and then there is
    /// no such thing as "the last image" to convert against.
    private var latest: [ScreenIndex] = []

    public func record(_ screenshot: Screenshot) { record([screenshot]) }

    /// Records one observation, which may have taken in several screens at once.
    public func record(_ screenshots: [Screenshot]) {
        guard !screenshots.isEmpty else { return }
        for screenshot in screenshots { shots[screenshot.screen] = screenshot }
        latest = screenshots.map(\.screen)
    }

    /// The most recent capture, when the most recent capture was of one screen.
    ///
    /// Nil after a capture that covered several, because there is no honest answer:
    /// picking one of them is a coin toss whose losing side is a click on the wrong
    /// monitor, reported as a success.
    public var mostRecent: Screenshot? {
        latest.count == 1 ? latest.first.flatMap { shots[$0] } : nil
    }

    /// Whether anything has been captured. Used to assert that the screenshot tool
    /// records what it takes — without which every later coordinate has nothing to
    /// convert against, and the pixel tier fails one call later. Deliberately not
    /// `mostRecent`: a two-monitor capture records two mappings and has no single
    /// most-recent one, but it has certainly recorded something.
    var lastScreenshotForTesting: Screenshot? { latest.first.flatMap { shots[$0] } }

    /// The mapping held for one screen, so a test can show that a later capture of a
    /// different screen did not displace it.
    func screenshotForTesting(of screen: ScreenIndex) -> Screenshot? { shots[screen] }

    /// Maps an image-space point to screen space.
    ///
    /// - Parameter screen: which screen's image the point was read off. Omitted means
    ///   the most recent capture — the single-monitor case, and the behaviour before
    ///   there was anything else to mean.
    ///
    /// Fails loudly on every way this can be wrong, because each produces a click that
    /// lands somewhere plausible and reports success:
    ///
    /// - No screenshot at all, so image pixels would be treated as screen points.
    /// - A named screen that was never captured. Falling back to the most recent image
    ///   here would convert a coordinate read off one monitor through another
    ///   monitor's rect, which is the whole failure this dictionary exists to stop.
    /// - A screenshot larger than the provider preserves. The provider resamples it on
    ///   arrival, so the model's coordinates are in the resampled space while
    ///   `imageSize` records the space we encoded. Inverting the recorded ratio then
    ///   scales every point by the wrong factor — the whole reason `ImageSpace` is a
    ///   per-provider value and not the 1568 that used to be hard-coded here.
    public func screenPoint(
        fromImage point: CGPoint, onScreen screen: ScreenIndex? = nil
    ) throws -> CGPoint {
        let shot: Screenshot
        if let screen {
            guard let named = shots[screen] else {
                throw ScreenToolError.screenNotCaptured(
                    screen, captured: shots.keys.sorted()
                )
            }
            shot = named
        } else if latest.count > 1 {
            throw ScreenToolError.screenNotNamed(captured: latest)
        } else {
            guard let mostRecent else { throw ScreenToolError.noScreenshot }
            shot = mostRecent
        }
        guard shot.reachesTheModelIntact else {
            throw ScreenToolError.rescaledByProvider(
                imageSize: shot.imageSize, space: shot.space
            )
        }
        return shot.screenPoint(fromImage: point)
    }
}

public enum ScreenToolError: Swift.Error, CustomStringConvertible {
    case noScreenshot
    /// A screen was named that nothing has been captured of. Carries the screens that
    /// have been, because the model cannot correct itself from "no".
    case screenNotCaptured(ScreenIndex, captured: [ScreenIndex])
    /// The last observation covered several screens and the coordinate named none of
    /// them, so there is no "the last image" to convert it against.
    case screenNotNamed(captured: [ScreenIndex])
    case rescaledByProvider(imageSize: CGSize, space: ImageSpace)

    public var description: String {
        switch self {
        case .noScreenshot:
            return "No screenshot has been taken yet, so image coordinates cannot be mapped to the screen. Call `screenshot` first."
        case let .screenNotCaptured(screen, captured):
            let held = captured.map(\.description).joined(separator: ", ")
            return captured.isEmpty
                ? "No screenshot has been taken yet, so a coordinate on \(screen) cannot be mapped to it. Call `screenshot` first."
                : "No screenshot of \(screen) has been taken, so a coordinate read off one cannot be mapped to it. Captured so far: \(held). Take a `screenshot` of \(screen) first."
        case let .screenNotNamed(captured):
            let held = captured.map(\.description).joined(separator: ", ")
            return "The last screenshot covered \(captured.count) screens (\(held)), so a coordinate on its own does not say where to act. Pass `screen` with the number in the caption above the image you read it from."
        case let .rescaledByProvider(imageSize, space):
            return """
            The last screenshot is \(Int(imageSize.width))×\(Int(imageSize.height)) px, \
            larger than this provider keeps (\(space.name)), so it was resized before \
            you saw it and any coordinate read off it would land in the wrong place. \
            Take a fresh `screenshot` and work from that, or use `ax_capture` and \
            `ax_press` instead.
            """
        }
    }
}

/// Tier 3 — capture the screen.
public struct ScreenshotTool: Tool {
    public let name = "screenshot"
    public let tier = Tier.pixels
    public let description = """
    Capture the screen as an image. The most expensive capability — about 2,000 vision \
    tokens and roughly a second — so reach for it after `shell`, `app_script` and \
    `ax_capture` have come up short, or when what matters is genuinely visual (a \
    chart, an image, a canvas, a custom-drawn UI, or confirming something looks right).

    The image is downscaled, so fine text may be unreadable; use `zoom` on a region \
    to read it rather than capturing the whole screen at higher resolution.

    With no arguments this photographs every screen, one image each, captioned with \
    the screen number to give `click`, `drag`, `scroll` and `zoom`. That costs the \
    vision tokens again per screen, so name a `screen` once you know which one the \
    work is on.

    Coordinates you read off an image are in that image's pixel space, and `click`, \
    `drag` and `scroll` expect exactly that — do not try to convert them yourself.
    """

    public var inputSchema: JSONValue {
        .schema([
            "region": .string(describing: "Optional area of the desktop as \"x,y,width,height\" in global screen points. Omit to capture a whole screen. On a multi-monitor setup the screen containing the region is used."),
            "screen": .integer(describing: "Which screen to capture, numbered from 0 left to right across the desktop as listed in the environment block. Omit for the main screen, or give a region instead."),
            "display_id": .integer(describing: "A display's system id, as an alternative to `screen`. Prefer `screen`."),
        ], required: [])
    }

    /// Windows left out of every capture, so the agent never sees its own overlay.
    let excludedBundleIDs: [String]
    let capture: any ScreenCapturing
    let context: ScreenContext
    /// The pixel space this run's provider hands the model. See `ImageSpace`.
    let space: ImageSpace

    /// Where the focused window is, for narrowing a capture too coarse to read.
    /// Injected so the behaviour can be tested without Accessibility or a real desktop.
    let focusedWindow: @Sendable () -> CGRect?

    /// Screen points per image pixel, past which UI text stops being readable.
    ///
    /// Ordinary macOS UI text is about 13 points. Vision models need roughly ten
    /// pixels of glyph height to read reliably, so 13 / 1.5 ≈ 8.7 px is already
    /// marginal and anything coarser is guesswork dressed as observation. Measured
    /// against real displays: a 1512-point laptop screen lands at 0.96 and is never
    /// narrowed, a 1920 at 1.22, a 2560 at 1.63, and a 3440 ultrawide at 2.19 — six
    /// pixels a glyph, which is what made every screenshot in this investigation
    /// useless.
    static let legibleceiling: CGFloat = 1.5

    public init(
        excludedBundleIDs: [String] = [],
        capture: any ScreenCapturing = ScreenCapture.shared,
        context: ScreenContext = .shared,
        space: ImageSpace = ScreenCapture.defaultSpace,
        focusedWindow: @escaping @Sendable () -> CGRect? = { AXCapture.focusedWindowFrame() }
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.capture = capture
        self.context = context
        self.space = space
        self.focusedWindow = focusedWindow
    }

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let screen = input["screen"]?.intValue.map(ScreenIndex.init)
        let displayID = input["display_id"]?.intValue.map(CGDirectDisplayID.init)
        let region = input["region"]?.stringValue.flatMap(parseRect)

        do {
            // Naming nothing means the whole desktop, which on more than one monitor
            // is more than one image. It used to mean the main display alone, so a
            // model asked to find something had no way to learn that the other screens
            // existed — it saw one screen, reported the thing was not there, and was
            // wrong without anything looking wrong.
            guard screen == nil, displayID == nil, region == nil else {
                let shot = try await shoot(
                    screen: screen, displayID: displayID, region: region
                )
                await context.record(shot)
                return .image(
                    mediaType: "image/jpeg",
                    base64: shot.jpegBase64,
                    note: "Screenshot: \(shot.summary). Give coordinates in this image's pixel space."
                )
            }
            return try await captureEveryScreen()
        } catch let error as ScreenCapture.Error {
            return .failure(error.description)
        }
    }

    /// How many screen points each image pixel stands for. Bigger is blurrier.
    static func pointsPerPixel(of shot: Screenshot) -> CGFloat {
        guard shot.imageSize.width > 0 else { return .infinity }
        return shot.screenRect.width / shot.imageSize.width
    }

    /// The window worth photographing instead of the whole screen, if any.
    ///
    /// Nil keeps the whole-screen capture, which is the answer whenever the picture is
    /// already readable, nothing owns a window, or the window is not on this screen —
    /// a rect belonging to another display would crop this one to nothing.
    static func windowToNarrowTo(
        from whole: Screenshot, on screen: ScreenLayout.Screen, focusedWindow: CGRect?
    ) -> CGRect? {
        guard pointsPerPixel(of: whole) > legibleceiling else { return nil }
        guard let window = focusedWindow, window.width >= 1, window.height >= 1 else {
            return nil
        }
        // Clipped to the screen it is on, since a window can straddle two.
        let onScreen = window.intersection(screen.frame)
        guard !onScreen.isNull, onScreen.width >= 1, onScreen.height >= 1 else { return nil }
        return onScreen
    }

    /// Says the frame is a window rather than the screen.
    ///
    /// Without it the image is indistinguishable from a whole-screen capture that
    /// happens to show one app, and a model reasoning about what is *not* on screen
    /// would be reasoning about a crop it did not know it had been given.
    static func narrowingNote(
        for shot: Screenshot, narrowed: [ScreenIndex: CGRect]
    ) -> String {
        guard narrowed[shot.screen] != nil else { return "" }
        return " This is the focused window, not the whole screen —"
            + " \(shot.screen.description) is too wide to photograph legibly."
            + " Ask for a `region` if you need the rest of it."
    }

    /// The one call into capture.
    ///
    /// Both routes went through their own copy of this, and the copies immediately
    /// drifted apart in what defends them: the sweep breaks the *first* occurrence of
    /// the exclusion argument, the only test asserting exclusions drives the other
    /// route, and so a screenshot that stopped hiding our own overlay was caught on
    /// neither. One call site is one place for that to be wrong.
    private func shoot(
        screen: ScreenIndex?, displayID: CGDirectDisplayID?, region: CGRect?
    ) async throws -> Screenshot {
        try await capture.capture(
            screen: screen, displayID: displayID, region: region,
            space: space, quality: 0.75,
            excludingBundleIDs: excludedBundleIDs
        )
    }

    /// One image per screen, in one result.
    private func captureEveryScreen() async throws -> ToolOutput {
        let layout = try await capture.layout()
        guard !layout.isEmpty else { throw ScreenCapture.Error.noDisplay }

        var shots: [Screenshot] = []
        var narrowed: [ScreenIndex: CGRect] = [:]
        for screen in layout.screens {
            let whole = try await shoot(screen: screen.index, displayID: nil, region: nil)
            if let window = Self.windowToNarrowTo(
                from: whole, on: screen, focusedWindow: focusedWindow()
            ) {
                // Per screen, not per desktop: on a mixed setup a laptop display stays
                // legible whole while the ultrawide beside it does not, and collapsing
                // both to one window would throw away the half that was fine.
                let closer = try await shoot(screen: nil, displayID: nil, region: window)
                // Only if it actually bought something. A window filling the display is
                // the same picture at the same scale, and swapping to it would lose the
                // rest of the screen for nothing.
                if Self.pointsPerPixel(of: closer) < Self.pointsPerPixel(of: whole) {
                    shots.append(closer)
                    narrowed[closer.screen] = window
                    continue
                }
            }
            shots.append(whole)
        }
        // Recorded as one observation. Two calls would leave the context believing the
        // last thing seen was the last monitor alone, and an unnamed coordinate would
        // then convert against it rather than being refused.
        await context.record(shots)

        // The desk most people have, and the result this tool has always returned for
        // it. A caption naming a screen number would be noise where there is only one.
        if shots.count == 1, let only = shots.first {
            return .image(
                mediaType: "image/jpeg",
                base64: only.jpegBase64,
                note: "Screenshot: \(only.summary)."
                    + Self.narrowingNote(for: only, narrowed: narrowed)
                    + " Give coordinates in this image's pixel space."
            )
        }

        return .images(
            shots.map {
                (caption: "\($0.screen.capitalized): \($0.summary)."
                    + Self.narrowingNote(for: $0, narrowed: narrowed),
                 mediaType: "image/jpeg",
                 base64: $0.jpegBase64)
            },
            trailing: "Each image has its own pixel space. Pass `screen` with the number above the image you read a coordinate from."
        )
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
            "screen": screenParameter,
        ], required: ["x", "y", "width", "height"])
    }

    /// Higher than the overview's 0.75: compression artefacts are what make small
    /// text unreadable, and this exists to read small text.
    static let detailQuality: CGFloat = 0.9

    let capture: any ScreenCapturing
    let context: ScreenContext
    /// The same space the overview was taken in.
    ///
    /// A zoom sent larger than the provider keeps is scaled back down on arrival, so
    /// the extra pixels buy nothing the model can see and cost bytes on every
    /// subsequent turn. The detail a zoom recovers comes from *cropping* — `encode`
    /// never upscales, so a small region keeps its native backing pixels while a
    /// whole-screen overview is reduced to fit the same budget.
    let space: ImageSpace

    public init(
        capture: any ScreenCapturing = ScreenCapture.shared,
        context: ScreenContext = .shared,
        space: ImageSpace = ScreenCapture.defaultSpace
    ) {
        self.capture = capture
        self.context = context
        self.space = space
    }

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
            let screen = requestedScreen(input)
            let origin = try await context.screenPoint(
                fromImage: CGPoint(x: try input.double("x"), y: try input.double("y")),
                onScreen: screen
            )
            let corner = try await context.screenPoint(
                fromImage: CGPoint(x: try input.double("x") + width,
                                   y: try input.double("y") + height),
                onScreen: screen
            )
            let rect = CGRect(
                x: origin.x, y: origin.y,
                width: max(corner.x - origin.x, 1), height: max(corner.y - origin.y, 1)
            )

            // No downscale, and higher quality than the overview: recovering detail
            // the overview lost is the tool's entire purpose, so a zoom that resampled
            // like a screenshot would return the same unreadable pixels at a different
            // size and cost a turn for nothing.
            let shot = try await capture.capture(
                screen: nil, displayID: nil, region: rect,
                space: space, quality: Self.detailQuality,
                excludingBundleIDs: []
            )
            await context.record(shot)
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
    /// Injectable so a test can see the screen point this computed.
    let pointer: any PointerActing
    let context: ScreenContext
    let cursor: CursorStage
    /// The agent's own surfaces, whose text changes with no action at all. Threaded
    /// in from the process that built the registry, exactly like
    /// `ScreenshotTool.excludedBundleIDs`; see `UIFingerprint.isSelfNoise`.
    let selfBundleIDs: [String]
    /// How this surface releases keyboard focus before input is posted. See
    /// `Verified.FocusYield`; nil for a surface with no window of its own.
    let yieldFocus: Verified.FocusYield?

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
            "count": .integer(describing: "Click count: 1 single, 2 double, 3 triple (selects a line or paragraph). Default 1."),
            "screen": screenParameter,
        ], required: ["x", "y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = [],
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
        self.yieldFocus = yieldFocus
    }

    public func risk(for input: JSONValue) -> Risk {
        let x = input["x"]?.intValue ?? 0, y = input["y"]?.intValue ?? 0
        let button = input["button"]?.stringValue ?? "left"
        let count = input["count"]?.intValue ?? 1
        let screen = requestedScreen(input)
        return .write(summary: "\(count > 1 ? "double-" : "")\(button)-click at (\(x), \(y))"
                      + (screen.map { " on \($0)" } ?? " in the screenshot"))
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let imagePoint = CGPoint(x: try input.double("x"), y: try input.double("y"))
        let button = InputInjector.MouseButton(
            rawValue: input.string("button", default: "left")
        ) ?? .left
        let count = min(max(input.int("count", default: 1), 1), 3)

        let screen = requestedScreen(input)

        do {
            let screenPoint = try await context.screenPoint(
                fromImage: imagePoint, onScreen: screen
            )
            // Show where the click is going before it lands, so the action is legible
            // and the user has a moment to stop it.
            await cursor.travel(to: screenPoint)
            let outcome = try await Verified.act(
                describing: "Clicked (\(Int(imagePoint.x)), \(Int(imagePoint.y))) in image space\(located(screen)) → screen (\(Int(screenPoint.x)), \(Int(screenPoint.y)))",
                selfBundleIDs: selfBundleIDs, yieldFocus: yieldFocus
            ) {
                try pointer.click(at: screenPoint, button: button, count: count)
            }
            return .verified(outcome)
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — drag between two image-space points.
public struct DragTool: Tool {
    /// Injectable so a test can see the screen point this computed.
    let pointer: any PointerActing
    let context: ScreenContext
    let cursor: CursorStage
    /// The agent's own surfaces, whose text changes with no action at all. Threaded
    /// in from the process that built the registry, exactly like
    /// `ScreenshotTool.excludedBundleIDs`; see `UIFingerprint.isSelfNoise`.
    let selfBundleIDs: [String]
    /// How this surface releases keyboard focus before input is posted. See
    /// `Verified.FocusYield`; nil for a surface with no window of its own.
    let yieldFocus: Verified.FocusYield?

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
            "screen": screenParameter,
        ], required: ["from_x", "from_y", "to_x", "to_y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = [],
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
        self.yieldFocus = yieldFocus
    }

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "drag from (\(input["from_x"]?.intValue ?? 0), \(input["from_y"]?.intValue ?? 0)) to (\(input["to_x"]?.intValue ?? 0), \(input["to_y"]?.intValue ?? 0))\(located(requestedScreen(input)))")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let from = CGPoint(x: try input.double("from_x"), y: try input.double("from_y"))
        let to = CGPoint(x: try input.double("to_x"), y: try input.double("to_y"))
        // One screen for both ends: they are two points in one image's pixel space, and
        // that image is of exactly one screen.
        let screen = requestedScreen(input)
        do {
            let start = try await context.screenPoint(fromImage: from, onScreen: screen)
            let end = try await context.screenPoint(fromImage: to, onScreen: screen)
            await cursor.travel(to: start)
            let outcome = try await Verified.act(
                describing: "Dragged to (\(Int(to.x)), \(Int(to.y))) in image space\(located(screen))",
                selfBundleIDs: selfBundleIDs, yieldFocus: yieldFocus
            ) {
                try pointer.drag(from: start, to: end)
            }
            return .verified(outcome)
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

    /// The agent's own surfaces, whose text changes with no action at all. Threaded
    /// in from the process that built the registry, exactly like
    /// `ScreenshotTool.excludedBundleIDs`; see `UIFingerprint.isSelfNoise`.
    let selfBundleIDs: [String]
    /// How this surface releases keyboard focus before input is posted. See
    /// `Verified.FocusYield`; nil for a surface with no window of its own.
    let yieldFocus: Verified.FocusYield?

    public init(
        selfBundleIDs: [String] = [],
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.selfBundleIDs = selfBundleIDs
        self.yieldFocus = yieldFocus
    }

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "type \"\((input["text"]?.stringValue ?? "").truncated(80))\"")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let text = try input.string("text")
        do {
            let outcome = try await Verified.act(
                describing: "Typed \(text.count) characters", selfBundleIDs: selfBundleIDs, yieldFocus: yieldFocus
            ) {
                try InputInjector.type(text)
            }
            return .verified(outcome)
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

    **Separate chords with a space to send a sequence**: `cmd+k cmd+t` is VS Code's \
    theme picker, and two-chord shortcuts are common in editors and chat apps. The \
    chords are sent in order, with a pause between them, because the app is waiting \
    for the second one.

    Keyboard shortcuts are often the most reliable way to drive a Mac app — usually \
    better than hunting for a button to click.
    """

    public var inputSchema: JSONValue {
        .schema([
            "combo": .string(describing: "The key or combination, e.g. \"cmd+s\" or \"Escape\"."),
            "repeat_count": .integer(describing: "How many times to send it. Default 1, maximum 50."),
        ], required: ["combo"])
    }

    /// The agent's own surfaces, whose text changes with no action at all. Threaded
    /// in from the process that built the registry, exactly like
    /// `ScreenshotTool.excludedBundleIDs`; see `UIFingerprint.isSelfNoise`.
    let selfBundleIDs: [String]
    /// How this surface releases keyboard focus before input is posted. See
    /// `Verified.FocusYield`; nil for a surface with no window of its own.
    let yieldFocus: Verified.FocusYield?

    public init(
        selfBundleIDs: [String] = [],
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.selfBundleIDs = selfBundleIDs
        self.yieldFocus = yieldFocus
    }

    public func risk(for input: JSONValue) -> Risk {
        let combo = input["combo"]?.stringValue ?? ""
        // Shortcuts that quit, close or delete lose work, and a mistaken one is
        // not recoverable — hold these to the destructive bar.
        let destructive = ["cmd+q", "cmd+w", "cmd+shift+q", "cmd+delete", "cmd+shift+delete"]
        // Every chord, not the whole string. This used to be an exact match on the
        // combo, which was correct only while a combo was always one chord — and the
        // moment sequences were supported, `cmd+k cmd+q` matched no entry, classified
        // as an ordinary write, and would have been auto-approved in `--mode auto`.
        // The capability and this check had to land together: adding the first without
        // the second is a gate bypass, not a feature.
        let chords = InputInjector.chords(in: combo).map { $0.lowercased() }
        return chords.contains(where: destructive.contains)
            ? .dangerous(summary: "press \(combo)")
            : .write(summary: "press \(combo)")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let combo = try input.string("combo")
        let count = min(max(input.int("repeat_count", default: 1), 1), 50)
        do {
            let outcome = try await Verified.act(
                describing: "Pressed \(combo)\(count > 1 ? " ×\(count)" : "")",
                selfBundleIDs: selfBundleIDs, yieldFocus: yieldFocus
            ) {
                try InputInjector.key(combo: combo, repeatCount: count)
            }
            return .verified(outcome)
        } catch let error as InputInjector.Error {
            return .failure(error.description)
        }
    }
}

/// Tier 3 — scroll wheel.
public struct ScrollTool: Tool {
    /// Injectable so a test can see the screen point this computed.
    let pointer: any PointerActing
    let context: ScreenContext
    let cursor: CursorStage
    /// The agent's own surfaces, whose text changes with no action at all. Threaded
    /// in from the process that built the registry, exactly like
    /// `ScreenshotTool.excludedBundleIDs`; see `UIFingerprint.isSelfNoise`.
    let selfBundleIDs: [String]
    /// How this surface releases keyboard focus before input is posted. See
    /// `Verified.FocusYield`; nil for a surface with no window of its own.
    let yieldFocus: Verified.FocusYield?

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
            "screen": screenParameter,
        ], required: ["x", "y", "delta_y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = [],
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
        self.yieldFocus = yieldFocus
    }

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "scroll \(input["delta_y"]?.intValue ?? 0)px\(located(requestedScreen(input)))")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let imagePoint = CGPoint(x: try input.double("x"), y: try input.double("y"))
        let screen = requestedScreen(input)
        do {
            let screenPoint = try await context.screenPoint(
                fromImage: imagePoint, onScreen: screen
            )
            let deltaY = try input.int("delta_y")
            // Verified like every other action: a scroll that moves nothing — because
            // the view is already at its end, or the pointer is not over a scrollable
            // area — looks identical to one that worked, and the model would keep
            // scrolling a view that cannot move.
            let outcome = try await Verified.act(
                describing: "Scrolled \(deltaY)px at (\(Int(imagePoint.x)), \(Int(imagePoint.y)))\(located(screen))",
                selfBundleIDs: selfBundleIDs, yieldFocus: yieldFocus
            ) {
                try pointer.scroll(
                    deltaX: input.int("delta_x", default: 0), deltaY: deltaY, at: screenPoint
                )
            }
            return .verified(outcome)
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

/// The `screen` field, worded once because four tools take it and four wordings is
/// four chances for the model to read it as four different things.
private let screenParameter = JSONValue.integer(describing: "Which screen these coordinates were read off, numbered as in the environment block and in each screenshot's note. Omit when you have only captured one screen; omitted means the most recent screenshot.")

/// The screen a tool was told its coordinates belong to, if any.
private func requestedScreen(_ input: JSONValue) -> ScreenIndex? {
    input["screen"]?.intValue.map(ScreenIndex.init)
}

/// How an approval prompt names where an action is about to land. The gate is the
/// user's last look at this, so on a multi-monitor desk it has to say which monitor.
private func located(_ screen: ScreenIndex?) -> String {
    screen.map { " on \($0)" } ?? ""
}

/// Parses `"x,y,width,height"` into a rect.
private func parseRect(_ text: String) -> CGRect? {
    let parts = text.split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}
