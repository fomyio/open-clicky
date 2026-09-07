import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import OpenClickyKit

/// The model reports coordinates in the pixel space of the image it was sent, and
/// we downscale before sending. Getting this conversion wrong produces clicks that
/// land plausibly but incorrectly — no error, just the wrong button. These pin it down.
@Suite("Image → screen coordinate mapping")
struct CoordinateTests {

    private func screenshot(
        imageSize: CGSize, screenRect: CGRect
    ) -> Screenshot {
        Screenshot(jpegBase64: "", imageSize: imageSize, screenRect: screenRect, displayID: 1)
    }

    @Test("A downscaled full-screen capture scales coordinates back up")
    func scalesUpFromDownscaledImage() {
        // A 3440×1440 display captured at a 1920 long edge.
        let shot = screenshot(
            imageSize: CGSize(width: 1920, height: 803),
            screenRect: CGRect(x: 0, y: 0, width: 3440, height: 1440)
        )
        let centre = shot.screenPoint(fromImage: CGPoint(x: 960, y: 401))
        #expect(abs(centre.x - 1720) < 2)
        #expect(abs(centre.y - 719) < 2)
    }

    @Test("The image origin maps to the screen origin")
    func mapsOrigin() {
        let shot = screenshot(
            imageSize: CGSize(width: 1920, height: 1080),
            screenRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)
        )
        let point = shot.screenPoint(fromImage: .zero)
        #expect(point == .zero)
    }

    /// A region capture's coordinates are relative to the crop, so the region's
    /// own origin has to be added back or every click is offset by it.
    @Test("A region capture offsets by the region origin")
    func offsetsByRegionOrigin() {
        let shot = screenshot(
            imageSize: CGSize(width: 600, height: 200),
            screenRect: CGRect(x: 400, y: 300, width: 600, height: 200)
        )
        let topLeft = shot.screenPoint(fromImage: .zero)
        #expect(topLeft == CGPoint(x: 400, y: 300))

        let middle = shot.screenPoint(fromImage: CGPoint(x: 300, y: 100))
        #expect(middle == CGPoint(x: 700, y: 400))
    }

    @Test("A secondary display's offset is preserved")
    func handlesSecondaryDisplayOffset() {
        let shot = screenshot(
            imageSize: CGSize(width: 1280, height: 800),
            screenRect: CGRect(x: 3440, y: 0, width: 2560, height: 1600)
        )
        let point = shot.screenPoint(fromImage: CGPoint(x: 640, y: 400))
        #expect(point == CGPoint(x: 3440 + 1280, y: 800))
    }

    @Test("An unscaled capture is the identity mapping")
    func identityWhenNotScaled() {
        let shot = screenshot(
            imageSize: CGSize(width: 1000, height: 500),
            screenRect: CGRect(x: 0, y: 0, width: 1000, height: 500)
        )
        let point = CGPoint(x: 123, y: 456)
        #expect(shot.screenPoint(fromImage: point) == point)
    }

    @Test("A zero-sized image cannot divide by zero")
    func degradesGracefullyOnEmptyImage() {
        let shot = screenshot(imageSize: .zero, screenRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let point = CGPoint(x: 10, y: 10)
        #expect(shot.screenPoint(fromImage: point) == point)
    }

    // MARK: - Encoding

    private func synthetic(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The downscale ratio is what `screenPoint(fromImage:)` inverts, so an image
    /// that comes back a different size than expected puts every click off by that
    /// factor — silently, since the coordinates still look plausible.
    @Test("Downscaling respects the long-edge budget and keeps the aspect ratio")
    func encodeRespectsLongEdge() async throws {
        let capture = ScreenCapture()
        let source = synthetic(width: 6880, height: 2880)
        let (_, size) = try await capture.encode(source, longEdge: 1920, quality: 0.75)

        #expect(max(size.width, size.height) <= 1920)
        let sourceRatio = 6880.0 / 2880.0
        let outputRatio = size.width / size.height
        #expect(abs(sourceRatio - outputRatio) < 0.01, "aspect ratio drifted")
    }

    /// The reported size is what every click coordinate is scaled by, so it must be
    /// the size of the image the model actually receives. Computing it separately —
    /// multiplying by the scale and rounding down — disagreed with Core Image's own
    /// rounding: a 6880×2880 source reported 803 pixels tall and produced 804.
    @Test("The reported size is the size of the image produced", arguments: [
        (6880, 2880, 1920.0),   // a 3440×1440 display at 2x backing scale
        (3024, 1964, 1920.0),   // a 14-inch MacBook Pro
        (2560, 1600, 1920.0),
        (5120, 2880, 1920.0),   // 5K
        (1000, 1000, 700.0),
        (1440, 900, 1920.0),    // smaller than the budget: unscaled
    ])
    func reportedSizeMatchesTheEncodedImage(dimensions: (Int, Int, Double)) async throws {
        let capture = ScreenCapture()
        let (data, reported) = try await capture.encode(
            synthetic(width: dimensions.0, height: dimensions.1),
            longEdge: CGFloat(dimensions.2), quality: 0.75
        )

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let actualWidth = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let actualHeight = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(Int(reported.width) == actualWidth,
                "reported \(Int(reported.width)) wide, produced \(actualWidth)")
        #expect(Int(reported.height) == actualHeight,
                "reported \(Int(reported.height)) tall, produced \(actualHeight)")
    }

    /// What the mismatch actually cost: a coordinate at the bottom of the image maps
    /// past the bottom of the display.
    @Test("A coordinate at the image edge maps inside the screen")
    func edgeCoordinatesStayOnScreen() async throws {
        let capture = ScreenCapture()
        let screen = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let (_, size) = try await capture.encode(
            synthetic(width: 6880, height: 2880), longEdge: 1920, quality: 0.75
        )
        let shot = Screenshot(jpegBase64: "", imageSize: size, screenRect: screen, displayID: 1)

        let bottomRight = shot.screenPoint(
            fromImage: CGPoint(x: size.width - 1, y: size.height - 1)
        )
        #expect(bottomRight.x < screen.maxX, "x ran past the display")
        #expect(bottomRight.y < screen.maxY, "y ran past the display")
    }

    @Test("A small image is never upscaled")
    func encodeNeverUpscales() async throws {
        let capture = ScreenCapture()
        let source = synthetic(width: 640, height: 480)
        let (_, size) = try await capture.encode(source, longEdge: 1920, quality: 0.75)
        #expect(size == CGSize(width: 640, height: 480))
    }

    @Test("A tall image is bounded by its long edge, not its width")
    func encodeHandlesPortrait() async throws {
        let capture = ScreenCapture()
        let (_, size) = try await capture.encode(
            synthetic(width: 1200, height: 3600), longEdge: 1800, quality: 0.75
        )
        #expect(size.height <= 1800)
        #expect(size.width <= 700)
    }

    @Test("The output is a real JPEG and quality affects its size")
    func encodeProducesJPEG() async throws {
        let capture = ScreenCapture()
        let source = synthetic(width: 1920, height: 1080)
        let (high, _) = try await capture.encode(source, longEdge: 1920, quality: 0.9)
        let (low, _) = try await capture.encode(source, longEdge: 1920, quality: 0.3)

        // JPEG magic number.
        #expect(high.prefix(2) == Data([0xFF, 0xD8]))
        #expect(low.count <= high.count)
    }

    // MARK: - Multi-display geometry

    /// `SCStreamConfiguration.sourceRect` is relative to its own display's origin,
    /// while CGEvent works in the global space where a second monitor might start at
    /// x=3440. Returning a display-local rect meant `screenPoint(fromImage:)` produced
    /// display-local coordinates, so every click on a secondary monitor landed on the
    /// primary one instead.
    @Test("A full capture of a secondary display reports its global position")
    func fullCaptureOfSecondaryDisplayIsGlobal() throws {
        let secondary = CGRect(x: 3440, y: 0, width: 2560, height: 1600)
        let geometry = try #require(ScreenCapture.geometry(displayFrame: secondary, globalRegion: nil))

        // ScreenCaptureKit is asked for the whole display, in its own coordinates.
        #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 2560, height: 1600))
        // What comes back covers the display's real place on the desktop.
        #expect(geometry.globalRect == secondary)
    }

    @Test("A region on a secondary display converts to display-local and back")
    func regionOnSecondaryDisplay() throws {
        let secondary = CGRect(x: 3440, y: 0, width: 2560, height: 1600)
        let region = CGRect(x: 3640, y: 300, width: 400, height: 200)
        let geometry = try #require(ScreenCapture.geometry(displayFrame: secondary, globalRegion: region))

        #expect(geometry.sourceRect == CGRect(x: 200, y: 300, width: 400, height: 200),
                "the capture request is display-local")
        #expect(geometry.globalRect == region, "the reported coverage stays global")

        // And a click read off that image lands where it should.
        let shot = Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 400, height: 200),
            screenRect: geometry.globalRect, displayID: 2
        )
        #expect(shot.screenPoint(fromImage: CGPoint(x: 200, y: 100)) == CGPoint(x: 3840, y: 400))
    }

    @Test("A region straddling a display edge is clipped to what was captured")
    func regionIsClippedToTheDisplay() throws {
        let primary = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let straddling = CGRect(x: 3300, y: 100, width: 400, height: 200)
        let geometry = try #require(ScreenCapture.geometry(displayFrame: primary, globalRegion: straddling))

        #expect(geometry.globalRect == CGRect(x: 3300, y: 100, width: 140, height: 200))
        #expect(geometry.sourceRect == CGRect(x: 3300, y: 100, width: 140, height: 200))
    }

    @Test("A region entirely off the display is refused rather than silently moved")
    func regionOffDisplayIsRefused() {
        let primary = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        #expect(ScreenCapture.geometry(
            displayFrame: primary, globalRegion: CGRect(x: 4000, y: 0, width: 100, height: 100)
        ) == nil)
    }

    @Test("A capture is routed to the display the region is on")
    func regionSelectsItsDisplay() {
        let frames: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 3440, height: 1440)),
            (2, CGRect(x: 3440, y: 0, width: 2560, height: 1600)),
        ]
        #expect(ScreenCapture.display(containing: CGPoint(x: 100, y: 100), among: frames) == 1)
        #expect(ScreenCapture.display(containing: CGPoint(x: 4000, y: 800), among: frames) == 2)
        #expect(ScreenCapture.display(containing: CGPoint(x: 9000, y: 9000), among: frames) == nil)
    }

    // MARK: - The conversion, applied

    /// Records where a tool aimed, without a mouse moving.
    private final class Spy: PointerActing, @unchecked Sendable {
        private let lock = NSLock()
        private var points: [CGPoint] = []

        var aimedAt: [CGPoint] { lock.lock(); defer { lock.unlock() }; return points }
        private func record(_ point: CGPoint) { lock.lock(); points.append(point); lock.unlock() }

        func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {
            record(point)
        }
        func drag(from start: CGPoint, to end: CGPoint) throws { record(start); record(end) }
        func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {
            if let point { record(point) }
        }
    }

    /// The conversion existing and the tools applying it are separate facts. Found by
    /// mutation: a `click` treating image pixels as screen points passed the whole
    /// suite, because every coordinate test drove the mapping directly and none went
    /// through the tool.
    @Test("A click aims at the converted screen point, not the image point")
    func clickAppliesTheConversion() async throws {
        // A 3440×1440 display captured at a 1920 long edge.
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1920, height: 804),
            screenRect: CGRect(x: 0, y: 0, width: 3440, height: 1440), displayID: 1
        ))

        let spy = Spy()
        _ = try await ClickTool(pointer: spy, context: context).run(
            .object(["x": .number(960), "y": .number(402)])
        )

        let aimed = try #require(spy.aimedAt.first)
        #expect(abs(aimed.x - 1720) < 2, "aimed at x=\(aimed.x), expected ~1720")
        #expect(abs(aimed.y - 720) < 2, "aimed at y=\(aimed.y), expected ~720")
        #expect(aimed != CGPoint(x: 960, y: 402), "the image point was used unconverted")
    }

    /// The case that would land on the wrong monitor entirely.
    @Test("A click on a secondary display aims at that display")
    func clickOnSecondaryDisplay() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1280, height: 800),
            screenRect: CGRect(x: 3440, y: 0, width: 2560, height: 1600), displayID: 2
        ))

        let spy = Spy()
        _ = try await ClickTool(pointer: spy, context: context).run(
            .object(["x": .number(640), "y": .number(400)])
        )

        let aimed = try #require(spy.aimedAt.first)
        #expect(aimed.x > 3440, "aimed at x=\(aimed.x) — that is the primary display")
        #expect(abs(aimed.x - 4720) < 2)
        #expect(abs(aimed.y - 800) < 2)
    }

    @Test("A drag converts both of its endpoints")
    func dragConvertsBothEnds() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 500),
            screenRect: CGRect(x: 100, y: 200, width: 2000, height: 1000), displayID: 1
        ))

        let spy = Spy()
        _ = try await DragTool(pointer: spy, context: context).run(.object([
            "from_x": .number(100), "from_y": .number(50),
            "to_x": .number(900), "to_y": .number(450),
        ]))

        #expect(spy.aimedAt.count == 2)
        #expect(spy.aimedAt[0] == CGPoint(x: 300, y: 300))
        #expect(spy.aimedAt[1] == CGPoint(x: 1900, y: 1100))
    }

    @Test("A scroll converts the point it acts at")
    func scrollConvertsItsPoint() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 960, height: 400),
            screenRect: CGRect(x: 0, y: 0, width: 1920, height: 800), displayID: 1
        ))

        let spy = Spy()
        _ = try await ScrollTool(pointer: spy, context: context).run(.object([
            "x": .number(480), "y": .number(200), "delta_y": .number(-100),
        ]))

        #expect(spy.aimedAt.first == CGPoint(x: 960, y: 400))
    }

    /// The animation exists so the user can see a click coming and stop it. Found by
    /// mutation: removing the call left every test passing while the pointer moved
    /// invisibly again — the exact behaviour the feature was built to prevent.
    @Test("A click animates the cursor to its target first")
    func clickAnimatesBeforeActing() async throws {
        final class Presenter: CursorPresenting, @unchecked Sendable {
            func show(at point: CGPoint) async {}
            func hide() async {}
        }

        let stage = CursorStage()
        await stage.install(Presenter())
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
            screenRect: CGRect(x: 0, y: 0, width: 200, height: 200), displayID: 1
        ))

        _ = try await ClickTool(pointer: SilentPointer(), context: context, cursor: stage).run(
            .object(["x": .number(25), "y": .number(50)])
        )

        let visited = await stage.visited
        #expect(visited.count == 1, "the click did not animate")
        #expect(visited.last == CGPoint(x: 50, y: 100), "it animated to the unconverted point")
    }

    private struct SilentPointer: PointerActing {
        func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {}
        func drag(from start: CGPoint, to end: CGPoint) throws {}
        func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {}
    }

    /// If a screenshot is not recorded, every later coordinate has nothing to convert
    /// against and the whole pixel tier stops working — silently, one call later.
    @Test("Taking a screenshot records it for later conversion",
          .enabled(if: ScreenCapture.shared.isPermitted, "needs Screen Recording"))
    func screenshotIsRecorded() async throws {
        let context = ScreenContext()
        #expect(await context.lastScreenshotForTesting == nil)

        let output = try await ScreenshotTool().run(.object([:]))
        #expect(!output.isError)

        // The shared context is what the tools use.
        let recorded = await ScreenContext.shared.lastScreenshotForTesting
        #expect(recorded != nil, "the capture was not recorded")
        #expect(recorded.map { $0.imageSize.width > 0 } == true)
    }

    /// Zoom exists to recover detail the overview lost, so it must sample a region
    /// more densely than a screenshot does. Found by mutation: dropping it to the
    /// overview's settings returned the same unreadable pixels at a different size,
    /// and nothing objected.
    ///
    /// This used to assert `fullResolutionEdge > defaultLongEdge`, which was a proxy
    /// for the density and stopped being one when both were set to the API's 1568
    /// cap. The density never came from the longer edge: it comes from cropping, and
    /// from `encode` never upscaling, so a crop keeps its native backing pixels while
    /// the overview is reduced to fit the whole screen into the same budget.
    @Test("Zoom samples more densely than the overview it refines", arguments: [
        400.0, 800.0, 1200.0,
    ])
    func zoomIsHigherFidelityThanAScreenshot(regionWidth: Double) {
        let screenPoints = 1512.0
        let backingScale = 2.0

        // The overview must fit the whole screen inside the cap.
        let space = ScreenCapture.defaultSpace
        let overviewPixels = min(space.longEdge, screenPoints * backingScale)
        let overviewDensity = overviewPixels / screenPoints

        // A crop keeps its native pixels up to the same cap — `encode` never upscales.
        let cropPixels = min(space.longEdge, regionWidth * backingScale)
        let zoomDensity = cropPixels / regionWidth

        #expect(zoomDensity > overviewDensity,
                "a \(Int(regionWidth))pt zoom resamples no more densely than the overview")
    }

    /// And it is compressed less, because artefacts are what make small text
    /// unreadable — a fidelity decision independent of the pixel count.
    @Test("Zoom is compressed less than the overview")
    func zoomIsCompressedLess() {
        #expect(ZoomTool.detailQuality > 0.75)
    }

    /// Neither path may send more pixels than the provider preserves. Anything
    /// longer is scaled down on arrival: it costs bytes on every turn of the
    /// conversation, buys nothing the model can see, and — the part that actually
    /// breaks things — leaves the model reading coordinates off an image whose size
    /// is not the one `Screenshot.imageSize` recorded.
    @Test("A capture in a space is an image that space preserves", arguments: [
        ImageSpace.anthropic, .openAI, .localVision,
    ])
    func neitherPathExceedsTheProviderCap(space: ImageSpace) async throws {
        let capture = ScreenCapture()
        // A 16:10 Retina display, the shape most likely to trip a short-edge cap.
        let source = synthetic(width: 3456, height: 2160)
        let (_, size) = try await capture.encode(
            source, longEdge: space.longEdge(fitting: CGSize(width: 3456, height: 2160)),
            quality: 0.75
        )
        #expect(space.preserves(size),
                "\(space.name) resamples a \(Int(size.width))×\(Int(size.height)) image")
    }

    /// The failure the per-provider space exists to prevent, stated directly: sizing
    /// a capture for Anthropic and sending it to OpenAI. 1568×980 is inside
    /// Anthropic's cap and half again outside OpenAI's 768-pixel short side, so the
    /// image the model reads is 1229×768 and every coordinate it returns is 27.6%
    /// short of where it meant to point.
    @Test("One provider's cap is not another's")
    func spacesDisagreeAboutTheSameImage() {
        let sized = CGSize(width: 1568, height: 980)
        #expect(ImageSpace.anthropic.preserves(sized))
        #expect(!ImageSpace.openAI.preserves(sized), "OpenAI would resample this")
        #expect(!ImageSpace.localVision.preserves(sized), "a local runtime would too")
    }

    /// The short-edge rule is a function of the aspect ratio, so it cannot be folded
    /// into a single long-edge constant: the same 768-pixel short side is 1152 long on
    /// a 3:2 display and 1365 on a 16:9 one.
    @Test("A short-edge cap binds through the aspect ratio", arguments: [
        (CGSize(width: 3000, height: 2000), 1152.0),   // 3:2
        (CGSize(width: 3840, height: 2160), 1365.33),  // 16:9
        (CGSize(width: 1000, height: 1000), 768.0),    // square
    ])
    func shortEdgeBindsThroughTheRatio(scenario: (CGSize, Double)) {
        let edge = ImageSpace.openAI.longEdge(fitting: scenario.0)
        #expect(abs(edge - scenario.1) < 1, "got \(edge), expected ~\(scenario.1)")
        #expect(edge < ImageSpace.openAI.longEdge,
                "the short side binds first on every real display shape")
    }

    /// With no short-edge rule the long edge is the whole answer, whatever the shape.
    @Test("A long-edge-only space ignores the aspect ratio")
    func longEdgeOnlySpaceIsFlat() {
        for size in [CGSize(width: 3440, height: 1440), CGSize(width: 100, height: 3000)] {
            #expect(ImageSpace.anthropic.longEdge(fitting: size) == 1568)
        }
    }

    /// A screenshot the provider resampled cannot be converted against, and the only
    /// safe answer is to refuse. Clicking anyway is the silent misclick this whole
    /// path exists to avoid: the coordinate is plausible, the click lands, and
    /// nothing anywhere reports that it hit the wrong thing.
    @Test("A screenshot the provider would resample is refused, not converted")
    func rescaledScreenshotIsRefused() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1568, height: 980),
            screenRect: CGRect(x: 0, y: 0, width: 3024, height: 1890),
            displayID: 1, space: .openAI
        ))
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 10, y: 10))
        }
    }

    /// And the same screenshot in the space it was actually sized for converts fine —
    /// otherwise the guard above would be indistinguishable from a broken mapping.
    @Test("The same screenshot converts inside the space it was sized for")
    func inSpaceScreenshotConverts() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1568, height: 980),
            screenRect: CGRect(x: 0, y: 0, width: 3136, height: 1960),
            displayID: 1, space: .anthropic
        ))
        let point = try await context.screenPoint(fromImage: CGPoint(x: 784, y: 490))
        #expect(point == CGPoint(x: 1568, y: 980))
    }

    /// The wiring, not the part: a space that reached `ImageSpace` and stopped there
    /// would leave both capture tools sizing for whatever the default happened to be.
    @Test("The registry hands its image space to both pixel-tier capture tools")
    func registryThreadsTheImageSpace() throws {
        let registry = ToolRegistry.standard(imageSpace: .localVision)
        let screenshot = try #require(registry["screenshot"] as? ScreenshotTool)
        let zoom = try #require(registry["zoom"] as? ZoomTool)
        #expect(screenshot.space == .localVision)
        #expect(zoom.space == .localVision, "a zoom in a different space than its overview")
    }
    /// And that the space follows the model rather than a constant. A run against
    /// OpenAI that captured at Anthropic's 1568 would misclick on every screenshot.
    @Test("An invocation's image space follows its model", arguments: [
        ("claude-opus-5", ImageSpace.anthropic),
        ("gpt-4o", ImageSpace.openAI),
        ("llava:13b", ImageSpace.localVision),
    ])
    func invocationImageSpaceFollowsTheModel(scenario: (String, ImageSpace)) throws {
        var invocation = Invocation()
        invocation.model = scenario.0
        let screenshot = try #require(invocation.registry["screenshot"] as? ScreenshotTool)
        #expect(screenshot.space == scenario.1)
    }


    /// The property that matters, against the real capture path.
    @Test("A zoomed region carries more pixels per screen point",
          .enabled(if: ScreenCapture.shared.isPermitted, "needs Screen Recording"))
    func zoomYieldsMorePixelsPerPoint() async throws {
        let region = CGRect(x: 0, y: 0, width: 400, height: 300)

        let overview = try await ScreenCapture.shared.capture(
            region: region, space: ScreenCapture.defaultSpace, quality: 0.75
        )
        let zoomed = try await ScreenCapture.shared.capture(
            region: region, space: ScreenCapture.defaultSpace, quality: ZoomTool.detailQuality
        )

        let overviewDensity = overview.imageSize.width / region.width
        let zoomedDensity = zoomed.imageSize.width / region.width
        #expect(zoomedDensity >= overviewDensity, "zoom returned no extra detail")
    }

    /// A zoom returns a crop with its own pixel space, so a click on what the crop
    /// shows must convert against the crop — not against the screenshot before it.
    /// Found by mutation: zoom could skip recording and a following click would land
    /// using the wrong mapping, somewhere plausible and wrong.
    @Test("A zoom becomes the mapping for coordinates read from it")
    func zoomBecomesTheActiveMapping() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 1000),
            screenRect: CGRect(x: 0, y: 0, width: 2000, height: 2000), displayID: 1
        ))

        // Zoom into a small region; the spy returns a crop covering it.
        let spy = ZoomCaptureSpy()
        _ = try await ZoomTool(capture: spy, context: context).run(.object([
            "x": .number(100), "y": .number(100),
            "width": .number(50), "height": .number(50),
        ]))

        // A coordinate read off the crop must now map through the crop's rect.
        let mapped = try await context.screenPoint(fromImage: CGPoint(x: 0, y: 0))
        #expect(mapped == CGPoint(x: 200, y: 200),
                "coordinates still map through the earlier screenshot, not the zoom")
    }

    private actor ZoomCaptureSpy: ScreenCapturing {
        func capture(
            displayID: CGDirectDisplayID?, region: CGRect?, space: ImageSpace,
            quality: CGFloat, excludingBundleIDs: [String]
        ) async throws -> Screenshot {
            Screenshot(
                jpegBase64: "", imageSize: CGSize(width: 400, height: 400),
                screenRect: region ?? .zero, displayID: 1, space: space
            )
        }
    }

    /// Acting on image coordinates with no screenshot to scale them by would
    /// silently treat them as screen points. It must fail instead.
    @Test("Mapping without a prior screenshot is an error")
    func requiresAScreenshotFirst() async {
        let context = ScreenContext()
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 10, y: 10))
        }
    }
}
