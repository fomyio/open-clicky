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

    /// How many images have been recorded. The number stamped on the next one.
    ///
    /// Monotonic and never reset, including across the screens it hands numbers to: a
    /// number that came round again would make a coordinate read off a replaced image
    /// look current, which is the whole failure the number exists to catch.
    private var generations = 0

    @discardableResult
    public func record(_ screenshot: Screenshot) -> Screenshot {
        record([screenshot]).first ?? screenshot
    }

    /// Records one observation, which may have taken in several screens at once.
    ///
    /// - Returns: the screenshots as stored, each stamped with the number the model is
    ///   shown beside it — which is the number a coordinate read off it has to name.
    @discardableResult
    public func record(_ screenshots: [Screenshot]) -> [Screenshot] {
        guard !screenshots.isEmpty else { return [] }
        let stamped = screenshots.map { shot -> Screenshot in
            generations += 1
            return shot.numbered(generations)
        }
        for screenshot in stamped { shots[screenshot.screen] = screenshot }
        latest = stamped.map(\.screen)
        return stamped
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
    /// - A coordinate read off an image that has since been replaced. A `zoom` of the
    ///   top-left quarter of screen 0 leaves that screen's mapping covering a quarter
    ///   of it, while the overview is still in the append-only transcript and is a
    ///   perfectly normal thing to read from. Converted silently, a point meant for
    ///   (3072,1254) landed at (1536,768).
    /// - A screenshot with no pixel size, which has no ratio to invert at all.
    ///
    /// - Parameter image: the number beside the image the point was read off, when the
    ///   model gave one. Omitted keeps exactly the behaviour there was before images
    ///   were numbered, because every coordinate written then omits it.
    public func screenPoint(
        fromImage point: CGPoint,
        onScreen screen: ScreenIndex? = nil,
        fromImageNumber image: Int? = nil
    ) throws -> CGPoint {
        let shot: Screenshot
        if let screen {
            guard let named = shots[screen] else {
                throw ScreenToolError.screenNotCaptured(
                    screen, captured: shots.keys.sorted()
                )
            }
            shot = named
        } else if let image,
                  let numbered = shots.values.first(where: { $0.generation == image }) {
            // A number names one image and one image is of one screen, so a coordinate
            // carrying the number has already said which screen it means — including
            // after a whole-desktop capture, where nothing else in the point does.
            shot = numbered
        } else if latest.count > 1 {
            throw ScreenToolError.screenNotNamed(captured: latest)
        } else {
            guard let mostRecent else { throw ScreenToolError.noScreenshot }
            shot = mostRecent
        }
        if let image, image != shot.generation {
            throw ScreenToolError.staleImage(
                requested: image, current: shot.generation
            )
        }
        guard shot.reachesTheModelIntact else {
            throw ScreenToolError.rescaledByProvider(
                imageSize: shot.imageSize, space: shot.space
            )
        }
        guard let converted = shot.screenPoint(fromImage: point) else {
            throw ScreenToolError.degenerateImage
        }
        return converted
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
    /// A coordinate named an image that is no longer the mapping for its screen —
    /// most often a point read off an overview a later `zoom` replaced.
    case staleImage(requested: Int, current: Int)
    /// A screenshot that recorded no pixel size, so there is no ratio to invert.
    case degenerateImage

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
        case let .staleImage(requested, current):
            return """
            That coordinate says image #\(requested), but image #\(current) is what \
            covers that screen now — a later `zoom` or `screenshot` replaced the \
            mapping. Converting a point from the older image would land it somewhere \
            plausible and wrong, so read the coordinate off image #\(current), or take \
            a fresh `screenshot` of the area you mean.
            """
        case .degenerateImage:
            return """
            The last screenshot recorded no pixel size, so a coordinate read off it \
            cannot be scaled to the screen. Take a fresh `screenshot` and work from that.
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
    `drag` and `scroll` expect exactly that — do not try to convert them yourself. \
    Each image is numbered ("image #3"); pass that number as `image` with any \
    coordinate you read off it, so a point read off a picture something has since \
    replaced is caught rather than converted against the wrong one.
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

    public init(
        excludedBundleIDs: [String] = [],
        capture: any ScreenCapturing = ScreenCapture.shared,
        context: ScreenContext = .shared,
        space: ImageSpace = ScreenCapture.defaultSpace
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.capture = capture
        self.context = context
        self.space = space
    }

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let screen = input["screen"]?.intValue.map(ScreenIndex.init)
        let displayID = input["display_id"]?.intValue.map(CGDirectDisplayID.init)

        // Present but unparseable is not absent. `"100 200 300 400"`, `"100,200,300"`,
        // a zero width and a JSON object are all plausible model output and all used to
        // read as "no region at all" — so the tool photographed every screen, at ~2,000
        // vision tokens each, while the model believed its crop had been honoured.
        let region: CGRect?
        switch input["region"] {
        case .none, .some(.null):
            region = nil
        case let .some(raw):
            guard let parsed = raw.stringValue.flatMap(parseRect) else {
                return .failure("""
                `region` must be a string of four comma-separated numbers, \
                "x,y,width,height" in global screen points, with a width and height \
                above zero — for example "100,200,300,400". Received \(echo(raw)). \
                Omit `region` to capture a whole screen.
                """)
            }
            region = parsed
        }

        do {
            // Naming nothing means the whole desktop, which on more than one monitor
            // is more than one image. It used to mean the main display alone, so a
            // model asked to find something had no way to learn that the other screens
            // existed — it saw one screen, reported the thing was not there, and was
            // wrong without anything looking wrong.
            guard screen == nil, displayID == nil, region == nil else {
                let shot = await context.record(try await shoot(
                    screen: screen, displayID: displayID, region: region
                ))
                return .image(
                    mediaType: "image/jpeg",
                    base64: shot.jpegBase64,
                    note: "Screenshot: \(shot.summary). Give coordinates in this image's pixel space.\(shot.imageHint)"
                )
            }
            return try await captureEveryScreen()
        } catch {
            // Terminal, not `catch let error as ScreenCapture.Error`. ScreenCaptureKit
            // throws `SCStreamError`, which is neither ours nor a `Policy.Violation`, so
            // a grant revoked since launch used to reach the model as
            // `SCStreamErrorDomain error -3801` — a number, where `Error.from` has a
            // sentence naming the System Settings pane to open.
            return .failure(ScreenCapture.Error.from(error).description)
        }
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
        for screen in layout.screens {
            shots.append(try await shoot(
                screen: screen.index, displayID: nil, region: nil
            ))
        }
        // Recorded as one observation. Two calls would leave the context believing the
        // last thing seen was the last monitor alone, and an unnamed coordinate would
        // then convert against it rather than being refused.
        //
        // Recorded *before* the captions are written, because the number each image is
        // known by is the number this stamps on it.
        let recorded = await context.record(shots)

        // The desk most people have, and the result this tool has always returned for
        // it. A caption naming a screen number would be noise where there is only one.
        if recorded.count == 1, let only = recorded.first {
            return .image(
                mediaType: "image/jpeg",
                base64: only.jpegBase64,
                note: "Screenshot: \(only.summary). Give coordinates in this image's pixel space.\(only.imageHint)"
            )
        }

        return .images(
            recorded.map {
                (caption: "\($0.screen.capitalized): \($0.summary).",
                 mediaType: "image/jpeg",
                 base64: $0.jpegBase64)
            },
            trailing: "Each image has its own pixel space. Pass `screen` with the number above the image you read a coordinate from, and `image` with that image's number."
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
    `click`. The crop that comes back has its own pixel space and its own number, and \
    it replaces the mapping for the screen it came from — so coordinates read from it \
    apply to it, and a coordinate still read off the overview must say `image` with \
    the overview's number.
    """

    public var inputSchema: JSONValue {
        .schema([
            "x": .integer(describing: "Left edge, in the last screenshot's pixel space."),
            "y": .integer(describing: "Top edge, in the last screenshot's pixel space."),
            "width": .integer(describing: "Width of the region, in the last screenshot's pixels."),
            "height": .integer(describing: "Height of the region, in the last screenshot's pixels."),
            "screen": screenParameter,
            "image": imageParameter,
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
        // Read before the `do`, so the terminal catch below is about the capture and
        // cannot dress a missing argument up as a capture failure.
        let x = try input.double("x")
        let y = try input.double("y")

        do {
            // Converted through the same mapping `click` uses. Asking the model for
            // screen points here while every other tool speaks image pixels would put
            // the conversion on its side of the boundary, which is precisely where
            // coordinate errors come from.
            let screen = requestedScreen(input)
            let image = requestedImage(input)
            let origin = try await context.screenPoint(
                fromImage: CGPoint(x: x, y: y),
                onScreen: screen, fromImageNumber: image
            )
            let corner = try await context.screenPoint(
                fromImage: CGPoint(x: x + width, y: y + height),
                onScreen: screen, fromImageNumber: image
            )
            let rect = CGRect(
                x: origin.x, y: origin.y,
                width: max(corner.x - origin.x, 1), height: max(corner.y - origin.y, 1)
            )

            // No downscale, and higher quality than the overview: recovering detail
            // the overview lost is the tool's entire purpose, so a zoom that resampled
            // like a screenshot would return the same unreadable pixels at a different
            // size and cost a turn for nothing.
            let shot = await context.record(try await capture.capture(
                screen: nil, displayID: nil, region: rect,
                space: space, quality: Self.detailQuality,
                excludingBundleIDs: []
            ))
            return .image(
                mediaType: "image/jpeg",
                base64: shot.jpegBase64,
                note: "Zoom: \(shot.summary). Coordinates you read here are in this crop's pixel space.\(shot.imageHint)"
            )
        } catch let error as ScreenToolError {
            return .failure(error.description)
        } catch {
            // Terminal, for the same reason as `screenshot`: ScreenCaptureKit's own
            // errors are neither ours nor a `Policy.Violation`, and one reaching the
            // model unmapped is an error number where a sentence should be.
            return .failure(ScreenCapture.Error.from(error).description)
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
            "image": imageParameter,
        ], required: ["x", "y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = []
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
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
                fromImage: imagePoint, onScreen: screen,
                fromImageNumber: requestedImage(input)
            )
            // Show where the click is going before it lands, so the action is legible
            // and the user has a moment to stop it.
            await cursor.travel(to: screenPoint)
            let outcome = try await Verified.act(
                describing: "Clicked (\(Int(imagePoint.x)), \(Int(imagePoint.y))) in image space\(located(screen)) → screen (\(Int(screenPoint.x)), \(Int(screenPoint.y)))",
                selfBundleIDs: selfBundleIDs
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
            "image": imageParameter,
        ], required: ["from_x", "from_y", "to_x", "to_y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = []
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
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
        let image = requestedImage(input)
        do {
            let start = try await context.screenPoint(
                fromImage: from, onScreen: screen, fromImageNumber: image
            )
            let end = try await context.screenPoint(
                fromImage: to, onScreen: screen, fromImageNumber: image
            )
            await cursor.travel(to: start)
            let outcome = try await Verified.act(
                describing: "Dragged to (\(Int(to.x)), \(Int(to.y))) in image space\(located(screen))",
                selfBundleIDs: selfBundleIDs
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

    public init(selfBundleIDs: [String] = []) {
        self.selfBundleIDs = selfBundleIDs
    }

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "type \"\((input["text"]?.stringValue ?? "").truncated(80))\"")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let text = try input.string("text")
        do {
            let outcome = try await Verified.act(
                describing: "Typed \(text.count) characters", selfBundleIDs: selfBundleIDs
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

    public init(selfBundleIDs: [String] = []) {
        self.selfBundleIDs = selfBundleIDs
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
                selfBundleIDs: selfBundleIDs
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
            "image": imageParameter,
        ], required: ["x", "y", "delta_y"])
    }

    public init(
        pointer: any PointerActing = SystemPointer(),
        context: ScreenContext = .shared,
        cursor: CursorStage = .shared,
        selfBundleIDs: [String] = []
    ) {
        self.pointer = pointer
        self.context = context
        self.cursor = cursor
        self.selfBundleIDs = selfBundleIDs
    }

    public func risk(for input: JSONValue) -> Risk {
        .write(summary: "scroll \(input["delta_y"]?.intValue ?? 0)px\(located(requestedScreen(input)))")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let imagePoint = CGPoint(x: try input.double("x"), y: try input.double("y"))
        let screen = requestedScreen(input)
        do {
            let screenPoint = try await context.screenPoint(
                fromImage: imagePoint, onScreen: screen,
                fromImageNumber: requestedImage(input)
            )
            let deltaY = try input.int("delta_y")
            // Verified like every other action: a scroll that moves nothing — because
            // the view is already at its end, or the pointer is not over a scrollable
            // area — looks identical to one that worked, and the model would keep
            // scrolling a view that cannot move.
            let outcome = try await Verified.act(
                describing: "Scrolled \(deltaY)px at (\(Int(imagePoint.x)), \(Int(imagePoint.y)))\(located(screen))",
                selfBundleIDs: selfBundleIDs
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

/// The `image` field, worded once for the four tools that convert a coordinate, for
/// the same reason as `screenParameter`.
private let imageParameter = JSONValue.integer(describing: "Which image these coordinates were read off — the number in that image's note or caption, as in \"image #3\". Pass it whenever you have it: a `zoom` replaces the mapping for the screen it crops, and this is what catches a coordinate read off the picture it replaced instead of converting it against the crop.")

/// The screen a tool was told its coordinates belong to, if any.
private func requestedScreen(_ input: JSONValue) -> ScreenIndex? {
    input["screen"]?.intValue.map(ScreenIndex.init)
}

/// The image a tool was told its coordinates were read off, if any.
private func requestedImage(_ input: JSONValue) -> Int? { input["image"]?.intValue }

/// What arrived, echoed back in a refusal.
///
/// A refusal that only states the expected format leaves the model to guess which part
/// of what it sent was wrong, and its next attempt is usually the same shape again.
private func echo(_ value: JSONValue) -> String {
    switch value {
    case let .string(text): return "\"\(text.truncated(60))\""
    case let .number(number): return "the number \(number)"
    case let .bool(flag): return "\(flag)"
    case .array: return "a list"
    case .object: return "an object"
    case .null: return "null"
    }
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
