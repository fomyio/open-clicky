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
    func scalesUpFromDownscaledImage() throws {
        // A 3440×1440 display captured at a 1920 long edge.
        let shot = screenshot(
            imageSize: CGSize(width: 1920, height: 803),
            screenRect: CGRect(x: 0, y: 0, width: 3440, height: 1440)
        )
        let centre = try #require(shot.screenPoint(fromImage: CGPoint(x: 960, y: 401)))
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

    /// A degenerate image has no ratio to invert, and returning the point unchanged
    /// was the same misclick wearing a fallback: on a screenshot of the display at
    /// x=3440, image (640,400) became screen (640,400) — a click on the *primary*
    /// monitor, reported as a success. `requiresAScreenshotFirst` demands a throw for
    /// the same "cannot convert", and this is that condition arriving a step later.
    @Test("A zero-sized image is refused rather than converted to itself")
    func refusesToConvertAZeroSizedImage() async throws {
        let shot = screenshot(
            imageSize: .zero, screenRect: CGRect(x: 3440, y: 0, width: 2560, height: 1600)
        )
        #expect(shot.screenPoint(fromImage: CGPoint(x: 640, y: 400)) == nil)

        // And the store turns that into a refusal rather than a point on the wrong
        // monitor, which is the only place the Optional can be undone.
        let context = ScreenContext()
        await context.record(shot)
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 640, y: 400))
        }
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

        let bottomRight = try #require(shot.screenPoint(
            fromImage: CGPoint(x: size.width - 1, y: size.height - 1)
        ))
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
        // And what was cut is carried, so the summary can say it rather than leave the
        // model to compare two rects it has no reason to re-read.
        #expect(geometry.clippedFrom == straddling)
    }

    /// The other half of that: a capture that covered everything asked for must not
    /// claim it was trimmed, or the warning means nothing when it appears.
    @Test("A capture that covered the whole request reports no clipping")
    func unclippedCaptureSaysNothing() throws {
        let primary = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let inside = try #require(ScreenCapture.geometry(
            displayFrame: primary, globalRegion: CGRect(x: 100, y: 100, width: 400, height: 200)
        ))
        #expect(inside.clippedFrom == nil)

        let whole = try #require(
            ScreenCapture.geometry(displayFrame: primary, globalRegion: nil)
        )
        #expect(whole.clippedFrom == nil)
    }

    /// And the difference is stated in the words the model reads, not merely stored.
    @Test("A clipped capture says so in its summary")
    func clippedCaptureStatesItsSummary() {
        let shot = Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 140, height: 200),
            screenRect: CGRect(x: 3300, y: 100, width: 140, height: 200), displayID: 1,
            clippedFrom: CGRect(x: 3300, y: 100, width: 400, height: 200)
        )
        #expect(shot.summary.contains("clipped from the 400×200 pt"))
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
        let layout = ScreenLayout(displays: [
            (1, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
            (2, CGRect(x: 3440, y: 0, width: 2560, height: 1600), false),
        ])
        #expect(layout.screen(containing: CGPoint(x: 100, y: 100))?.displayID == 1)
        #expect(layout.screen(containing: CGPoint(x: 4000, y: 800))?.displayID == 2)
        #expect(layout.screen(containing: CGPoint(x: 9000, y: 9000)) == nil)
    }

    /// A region that spans two monitors belongs to the one it is mostly on. Routing it
    /// by its midpoint answers a different question, and the losing side is a capture
    /// of the sliver instead of the part the model asked to see.
    @Test("A region straddling two displays goes to the one it mostly covers")
    func straddlingRegionPicksTheLargerShare() {
        let layout = ScreenLayout(displays: [
            (1, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
            (2, CGRect(x: 3440, y: 0, width: 2560, height: 1600), false),
        ])
        #expect(layout.screen(
            overlapping: CGRect(x: 3340, y: 100, width: 400, height: 200)
        )?.displayID == 2, "300 of its 400 points are on the second display")
        #expect(layout.screen(
            overlapping: CGRect(x: 3140, y: 100, width: 400, height: 200)
        )?.displayID == 1, "300 of its 400 points are on the first display")
        #expect(layout.screen(
            overlapping: CGRect(x: 8000, y: 0, width: 100, height: 100)
        ) == nil)
        // A region with no area at all still names a place, and containment is what
        // answers for it — otherwise a degenerate rect would route nowhere.
        #expect(layout.screen(
            overlapping: CGRect(x: 4000, y: 800, width: 0, height: 0)
        )?.displayID == 2)
    }

    /// The desktop shape the midpoint rule could not describe: a laptop below and left
    /// of an external display, with a notch between them. A region over that notch has
    /// its midpoint on neither monitor, and the region branch *fell through* to the
    /// main display — the very fallback the function's own comment says was removed —
    /// capturing a clipped corner of the wrong screen and reporting it as the crop.
    @Test("A region whose midpoint is on no display routes by what it overlaps")
    func regionOnAnLShapedDesktop() throws {
        let layout = ScreenLayout(displays: [
            (1, CGRect(x: 0, y: 900, width: 1512, height: 982), true),
            (2, CGRect(x: 1512, y: 0, width: 3440, height: 1440), false),
        ])
        let region = CGRect(x: 1112, y: 500, width: 600, height: 600)
        #expect(layout.screen(containing: CGPoint(x: region.midX, y: region.midY)) == nil,
                "the midpoint has to fall in the notch, or this pins nothing")

        let resolved = try ScreenCapture.resolve(
            screen: nil, displayID: nil, region: region, in: layout
        )
        #expect(resolved.displayID == 2,
                "routed to the main display rather than the one the region is mostly on")
    }

    /// And a region on no display at all is refused, for the same reason naming an
    /// unattached screen is: a capture of somewhere else, returned as a success.
    @Test("A region over no display is refused rather than captured elsewhere")
    func regionOverNoDisplayIsRefused() {
        let layout = ScreenLayout(displays: [
            (1, CGRect(x: 0, y: 900, width: 1512, height: 982), true),
            (2, CGRect(x: 1512, y: 0, width: 3440, height: 1440), false),
        ])
        #expect(throws: ScreenCapture.Error.self) {
            _ = try ScreenCapture.resolve(
                screen: nil, displayID: nil,
                region: CGRect(x: 1012, y: 300, width: 400, height: 400), in: layout
            )
        }
    }

    // MARK: - Screen numbering

    /// The index the environment block shows and the index `screenshot` routes by are
    /// the same number only because both come from this ordering. A display id is
    /// opaque and `NSScreen.screens` is in no promised order, so either alone would
    /// let the model name one monitor and act on another.
    @Test("Screens are numbered left to right, then top to bottom")
    func numbersScreensByPosition() {
        let layout = ScreenLayout(displays: [
            (7, CGRect(x: 3440, y: 0, width: 2560, height: 1600), false),
            (3, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
            (9, CGRect(x: 0, y: 1440, width: 3440, height: 1440), false),
        ])
        #expect(layout.screens.map(\.displayID) == [3, 9, 7])
        #expect(layout.index(of: 3) == ScreenIndex(0))
        #expect(layout.index(of: 9) == ScreenIndex(1))
        #expect(layout.index(of: 7) == ScreenIndex(2))
        #expect(layout.screen(at: ScreenIndex(2))?.displayID == 7)
        #expect(layout.screen(at: ScreenIndex(3)) == nil)
    }

    /// Two screens at the same origin cannot be ordered by position, and a sort that
    /// leaves them tied returns them in whatever order it was handed them — so the
    /// index given to the model one turn would name the other monitor the next.
    @Test("Screens sharing an origin still get a stable order")
    func breaksTiesDeterministically() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let forwards = ScreenLayout(displays: [(4, frame, false), (2, frame, true)])
        let backwards = ScreenLayout(displays: [(2, frame, true), (4, frame, false)])
        #expect(forwards.screens.map(\.displayID) == backwards.screens.map(\.displayID))
    }

    @Test("A screen describes itself with the number the model uses")
    func summaryNamesTheIndex() {
        let layout = ScreenLayout(displays: [
            (1, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
            (2, CGRect(x: 3440, y: 0, width: 2560, height: 1600), false),
        ])
        #expect(layout.summaries[0] == "screen 0: 3440×1440 pt at (0,0) (main)")
        #expect(layout.summaries[1] == "screen 1: 2560×1600 pt at (3440,0)")
    }

    /// The `<screens>` block the model reads and the routing a capture does have to be
    /// one computation, and they were two.
    ///
    /// The block was built from `NSScreen` frames flipped by
    /// `NSScreen.screens.first.frame.height` — a constant nothing asserts is the screen
    /// at the origin — while captures route by `SCDisplay.frame`/`CGDisplayBounds`,
    /// which are already global top-left. A display stacked *above* the origin is where
    /// the two part company: the frame below has a negative `y`, and a flip through the
    /// wrong screen's height moves every `y` in the block by a constant while the click
    /// path stays correct.
    ///
    /// The main display is deliberately neither the first id nor the first frame: it was
    /// `NSScreen.main`, the *key window's* screen, while an unnamed capture goes to
    /// `CGMainDisplayID()`. Focus a window on the secondary display and the block
    /// labelled one monitor "(main)" while the screenshot came back from another.
    @Test("The layout the model is shown is the one captures route by")
    func layoutIsOneComputationOverOneSource() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            9: CGRect(x: 0, y: 0, width: 1512, height: 982),
            4: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        ]
        let layout = ScreenLayout.describing(
            displays: [9, 4], main: 4, bounds: { bounds[$0] ?? .zero }
        )

        // Top to bottom, so the display above the origin is screen 0 — which it can
        // only be if its negative `y` survived to the sort.
        #expect(layout.screens.map(\.displayID) == [4, 9])
        #expect(layout.screen(displayID: 4)?.frame == bounds[4])
        #expect(layout.screen(displayID: 9)?.frame == bounds[9])
        #expect(layout.screens.filter(\.isMain).map(\.displayID) == [4])
    }

    /// And the live layout is really built from those values, on whatever desktop this
    /// is running on. Needs no grant — `CGDisplayBounds` and `CGMainDisplayID` are free,
    /// which is why the environment block can be built before any capability check.
    @Test("The live layout agrees with Core Graphics, display for display")
    func liveLayoutAgreesWithCoreGraphics() {
        let layout = ScreenLayout.current()
        #expect(!layout.isEmpty)
        for screen in layout.screens {
            #expect(screen.frame == CGDisplayBounds(screen.displayID))
            #expect(screen.isMain == (screen.displayID == CGMainDisplayID()))
        }
        // Exactly one, because `ScreenCapture.resolve` sends an unnamed capture to the
        // single screen this flags. None, and it falls through to whichever display
        // sorted first; two, and the label means nothing.
        #expect(layout.screens.filter(\.isMain).count == 1)
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

    // MARK: - One mapping per screen

    private func shot(on screen: ScreenIndex, screenRect: CGRect) -> Screenshot {
        Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 500),
            screenRect: screenRect, displayID: CGDirectDisplayID(screen.value + 1),
            screen: screen
        )
    }

    /// The failure a single slot produced: capturing the second monitor repointed the
    /// mapping, so a coordinate read off the first monitor's still-visible image was
    /// converted through the second monitor's rect and landed there.
    @Test("Capturing one screen does not displace another screen's mapping")
    func keepsAMappingPerScreen() async throws {
        let context = ScreenContext()
        await context.record(shot(
            on: ScreenIndex(0), screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000)
        ))
        await context.record(shot(
            on: ScreenIndex(1), screenRect: CGRect(x: 3440, y: 0, width: 2000, height: 1000)
        ))

        let onFirst = try await context.screenPoint(
            fromImage: CGPoint(x: 500, y: 250), onScreen: ScreenIndex(0)
        )
        #expect(onFirst == CGPoint(x: 1000, y: 500),
                "screen 0 converted through screen 1's rect")

        let onSecond = try await context.screenPoint(
            fromImage: CGPoint(x: 500, y: 250), onScreen: ScreenIndex(1)
        )
        #expect(onSecond == CGPoint(x: 4440, y: 500))
    }

    /// Every coordinate written before there was a screen to name omits one, so an
    /// omitted screen has to keep meaning exactly what it meant then.
    @Test("A point naming no screen uses the most recent capture")
    func omittedScreenUsesTheMostRecent() async throws {
        let context = ScreenContext()
        await context.record(shot(
            on: ScreenIndex(0), screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000)
        ))
        #expect(await context.mostRecent?.screen == ScreenIndex(0))

        await context.record(shot(
            on: ScreenIndex(1), screenRect: CGRect(x: 3440, y: 0, width: 2000, height: 1000)
        ))
        #expect(await context.mostRecent?.screen == ScreenIndex(1))

        let point = try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
        #expect(point == CGPoint(x: 4440, y: 500))

        // And the displaced screen is still there to be asked for by name.
        #expect(await context.screenshotForTesting(of: ScreenIndex(0)) != nil)
    }

    /// Falling back to the most recent image for a screen nothing was captured of is
    /// the same bug in a different place: a plausible point on the wrong monitor.
    @Test("A screen nothing was captured of is an error, not the nearest guess")
    func namingAnUncapturedScreenFails() async throws {
        let context = ScreenContext()
        await context.record(shot(
            on: ScreenIndex(0), screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000)
        ))

        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(
                fromImage: CGPoint(x: 10, y: 10), onScreen: ScreenIndex(2)
            )
        }

        // The model cannot correct itself from "no", so the error says what is held.
        let error = ScreenToolError.screenNotCaptured(
            ScreenIndex(2), captured: [ScreenIndex(0), ScreenIndex(1)]
        )
        #expect(error.description.contains("screen 2"))
        #expect(error.description.contains("screen 0, screen 1"))
    }

    // MARK: - Acting on a named screen

    /// Two screens captured, and a coordinate read off the *earlier* one. Every tool
    /// here converts, so each has its own chance to ignore the name and reach for the
    /// most recent mapping instead — which lands the action on the other monitor and
    /// reports success.
    private func twoScreens() async -> ScreenContext {
        let context = ScreenContext()
        await context.record(shot(
            on: ScreenIndex(0), screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000)
        ))
        await context.record(shot(
            on: ScreenIndex(1), screenRect: CGRect(x: 3440, y: 0, width: 2000, height: 1000)
        ))
        return context
    }

    @Test("A click on a named screen aims at that screen")
    func clickHonoursItsScreen() async throws {
        let spy = Spy()
        _ = try await ClickTool(pointer: spy, context: await twoScreens()).run(.object([
            "x": .number(500), "y": .number(250), "screen": .number(0),
        ]))

        let aimed = try #require(spy.aimedAt.first)
        #expect(aimed == CGPoint(x: 1000, y: 500),
                "aimed at \(aimed) — that is the most recent screen, not the named one")
    }

    @Test("A drag on a named screen converts both ends through it")
    func dragHonoursItsScreen() async throws {
        let spy = Spy()
        _ = try await DragTool(pointer: spy, context: await twoScreens()).run(.object([
            "from_x": .number(0), "from_y": .number(0),
            "to_x": .number(1000), "to_y": .number(500),
            "screen": .number(0),
        ]))

        #expect(spy.aimedAt == [CGPoint(x: 0, y: 0), CGPoint(x: 2000, y: 1000)])
    }

    @Test("A scroll on a named screen acts at that screen")
    func scrollHonoursItsScreen() async throws {
        let spy = Spy()
        _ = try await ScrollTool(pointer: spy, context: await twoScreens()).run(.object([
            "x": .number(500), "y": .number(250), "delta_y": .number(-100),
            "screen": .number(0),
        ]))

        #expect(spy.aimedAt.first == CGPoint(x: 1000, y: 500))
    }

    /// Zoom converts a rect rather than a point, so ignoring the name here crops the
    /// wrong monitor and returns an image of something the model never asked about.
    @Test("A zoom on a named screen crops from that screen")
    func zoomHonoursItsScreen() async throws {
        let spy = ZoomCaptureSpy()
        _ = try await ZoomTool(capture: spy, context: await twoScreens()).run(.object([
            "x": .number(0), "y": .number(0),
            "width": .number(500), "height": .number(250),
            "screen": .number(0),
        ]))

        let region = try #require(await spy.regions.first)
        #expect(region == CGRect(x: 0, y: 0, width: 1000, height: 500),
                "cropped \(region) — that is the most recent screen, not the named one")
    }

    /// The approval prompt is the user's last look before an action lands, and on a
    /// multi-monitor desk "click at (500, 250)" does not say where.
    @Test("An approval names the screen the action lands on")
    func approvalNamesTheScreen() {
        let onScreen = ClickTool().risk(for: .object([
            "x": .number(500), "y": .number(250), "screen": .number(1),
        ]))
        guard case let .write(summary) = onScreen else {
            Issue.record("a click should be a plain write, got \(onScreen)"); return
        }
        #expect(summary.contains("screen 1"))

        // And with no screen named it still reads as it always did.
        let unnamed = ClickTool().risk(for: .object(["x": .number(5), "y": .number(5)]))
        guard case let .write(plain) = unnamed else {
            Issue.record("a click should be a plain write, got \(unnamed)"); return
        }
        #expect(plain.contains("in the screenshot"))
    }

    // MARK: - A whole desktop, end to end

    /// A desktop of whatever shape, captured the way the real one is.
    ///
    /// Halves each screen into its image, so the conversion back is exact arithmetic
    /// rather than a tolerance — a mapping that came out slightly wrong and a mapping
    /// that came out of the wrong screen must not be able to look alike here.
    private actor DesktopSpy: ScreenCapturing {
        private let displays: [(id: CGDirectDisplayID, frame: CGRect, isMain: Bool)]

        init(_ displays: [(id: CGDirectDisplayID, frame: CGRect, isMain: Bool)]) {
            self.displays = displays
        }

        func layout() async throws -> ScreenLayout { ScreenLayout(displays: displays) }

        func capture(
            screen: ScreenIndex?, displayID: CGDirectDisplayID?, region: CGRect?,
            space: ImageSpace, quality: CGFloat, excludingBundleIDs: [String]
        ) async throws -> Screenshot {
            let layout = ScreenLayout(displays: displays)
            guard let target = screen.flatMap({ layout.screen(at: $0) })
                ?? displayID.flatMap({ layout.screen(displayID: $0) })
                ?? region.flatMap({
                    layout.screen(containing: CGPoint(x: $0.midX, y: $0.midY))
                })
                ?? layout.screens.first
            else { throw ScreenCapture.Error.noDisplay }

            let rect = region ?? target.frame
            return Screenshot(
                jpegBase64: "jpeg-\(target.index.value)",
                imageSize: CGSize(width: rect.width / 2, height: rect.height / 2),
                screenRect: rect,
                displayID: target.displayID,
                screen: target.index,
                space: space
            )
        }
    }

    /// An ultrawide beside a portrait secondary: different shapes, different origins,
    /// and a click on either that must not be converted through the other's rect.
    private static let ultrawideAndSecondary:
        [(id: CGDirectDisplayID, frame: CGRect, isMain: Bool)] = [
            (11, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
            (12, CGRect(x: 3440, y: 0, width: 1600, height: 2560), false),
        ]

    /// The whole point of the branch, driven through the tools rather than the store:
    /// look at one screen, look at another, then act on the first. Before this, the
    /// second `screenshot` replaced the only mapping there was, and the click landed
    /// on the second monitor while reporting success.
    @Test("A screen captured two turns ago can still be acted on")
    func actsOnAScreenCapturedEarlier() async throws {
        let capture = DesktopSpy(Self.ultrawideAndSecondary)
        let context = ScreenContext()
        let screenshot = ScreenshotTool(
            capture: capture, context: context, space: .unconstrained
        )

        _ = try await screenshot.run(.object(["screen": .number(0)]))
        _ = try await screenshot.run(.object(["screen": .number(1)]))

        let pointer = Spy()
        _ = try await ClickTool(pointer: pointer, context: context).run(.object([
            "x": .number(860), "y": .number(360), "screen": .number(0),
        ]))

        let aimed = try #require(pointer.aimedAt.first)
        #expect(aimed == CGPoint(x: 1720, y: 720),
                "aimed at \(aimed) — the later capture displaced screen 0's mapping")
    }

    /// And both shapes convert in their own space after one whole-desktop capture.
    /// A single ratio applied to both would put the portrait screen's clicks wrong by
    /// its aspect ratio, which is a plausible-looking point every time.
    @Test("One capture of the desktop maps each screen by its own geometry")
    func mapsEachScreenByItsOwnGeometry() async throws {
        let capture = DesktopSpy(Self.ultrawideAndSecondary)
        let context = ScreenContext()
        _ = try await ScreenshotTool(
            capture: capture, context: context, space: .unconstrained
        ).run(.object([:]))

        let onUltrawide = try await context.screenPoint(
            fromImage: CGPoint(x: 860, y: 360), onScreen: ScreenIndex(0)
        )
        #expect(onUltrawide == CGPoint(x: 1720, y: 720))

        let onSecondary = try await context.screenPoint(
            fromImage: CGPoint(x: 400, y: 640), onScreen: ScreenIndex(1)
        )
        #expect(onSecondary == CGPoint(x: 4240, y: 1280))
    }

    /// The captions are read positionally, so each one has to sit immediately above
    /// the image it describes. Gathered into a preamble they would be a list the model
    /// has to match up by guesswork — and guessing which monitor it is looking at is
    /// the failure this whole path removes.
    @Test("Every image in a whole-desktop result is preceded by its own caption")
    func captionsAlternateWithImages() async throws {
        let capture = DesktopSpy(Self.ultrawideAndSecondary)
        let output = try await ScreenshotTool(
            capture: capture, context: ScreenContext(), space: .unconstrained
        ).run(.object([:]))

        var captions: [String] = []
        for (index, block) in output.content.enumerated() where block.isImage {
            guard index > 0, case let .text(caption) = output.content[index - 1] else {
                Issue.record("the image at \(index) has no caption above it"); return
            }
            captions.append(caption)
        }
        #expect(captions.count == 2)
        #expect(captions[0].hasPrefix("Screen 0:"))
        #expect(captions[1].hasPrefix("Screen 1:"))
    }

    // MARK: - A display that is not there

    /// The error a model has to act on. "No matching display" leaves it to guess what
    /// would have matched, and guessing is what the numbering exists to stop.
    @Test("Naming a display that is not attached says which ones are")
    func unknownScreenErrorNamesTheAttachedOnes() {
        let error = ScreenCapture.Error.unknownScreen(
            requested: "screen 4",
            available: ScreenLayout(displays: Self.ultrawideAndSecondary).summaries
        )
        #expect(error.description.contains("screen 4"))
        #expect(error.description.contains("screen 0: 3440×1440 pt"))
        #expect(error.description.contains("screen 1: 1600×2560 pt"))
    }

    /// The regression itself: resolution used to end in `?? content.displays.first`,
    /// so an id nothing matched returned a screenshot of a different monitor carrying
    /// that monitor's rect — a wrong-screen image reported as a success, with every
    /// coordinate read off it landing there too.
    @Test("An unattached display is refused rather than swapped for another")
    func unattachedDisplayIsRefused() throws {
        let layout = ScreenLayout(displays: Self.ultrawideAndSecondary)

        #expect(throws: ScreenCapture.Error.self) {
            _ = try ScreenCapture.resolve(
                screen: nil, displayID: 999_999, region: nil, in: layout
            )
        }
        #expect(throws: ScreenCapture.Error.self) {
            _ = try ScreenCapture.resolve(
                screen: ScreenIndex(4), displayID: nil, region: nil, in: layout
            )
        }

        // And the names that do match still resolve, or the refusals above would be
        // indistinguishable from a resolver that refuses everything.
        #expect(try ScreenCapture.resolve(
            screen: ScreenIndex(1), displayID: nil, region: nil, in: layout
        ).displayID == 12)
        #expect(try ScreenCapture.resolve(
            screen: nil, displayID: 12, region: nil, in: layout
        ).index == ScreenIndex(1))
    }

    /// A region names a place on the desktop rather than a screen, so it routes by
    /// containment — and naming nothing at all is the main screen, which on this
    /// layout is not the one a bare `first` would have picked either.
    @Test("A region routes to the screen it falls on, and nothing names the main one")
    func resolutionRoutesRegionsAndDefaults() throws {
        let layout = ScreenLayout(displays: [
            (21, CGRect(x: -1920, y: 0, width: 1920, height: 1080), false),
            (22, CGRect(x: 0, y: 0, width: 3440, height: 1440), true),
        ])

        let onLeft = try ScreenCapture.resolve(
            screen: nil, displayID: nil,
            region: CGRect(x: -1800, y: 100, width: 200, height: 200), in: layout
        )
        #expect(onLeft.displayID == 21)

        let unnamed = try ScreenCapture.resolve(
            screen: nil, displayID: nil, region: nil, in: layout
        )
        #expect(unnamed.displayID == 22, "the main screen, not merely the first one")
    }

    /// And the tool surfaces it as a failure the model can read, rather than an image.
    @Test("A screenshot of a display that is not there fails with the reason",
          .enabled(if: ScreenCapture.shared.isPermitted, "needs Screen Recording"))
    func screenshotOfMissingDisplayFails() async throws {
        let output = try await ScreenshotTool(context: ScreenContext())
            .run(.object(["display_id": .number(999_999)]))

        #expect(output.isError)
        #expect(output.content.filter(\.isImage).isEmpty,
                "an image for a display that is not attached")
    }

    /// A revoked grant, from the tools' point of view.
    ///
    /// `isPermitted` is `CGPreflightScreenCaptureAccess()`, whose answer is cached for
    /// the life of the process: revoke Screen Recording after launch — or run the CLI
    /// from a terminal whose own grant changed — and it still says yes while every
    /// ScreenCaptureKit call throws. That throw is neither `ScreenCapture.Error` nor
    /// `Policy.Violation`, so it fell past the tools' catches and reached the model as
    /// `SCStreamErrorDomain error -3801`: a number, three lines from carefully written
    /// text naming the pane to open. Checked against a synthesised `NSError` because a
    /// test that needs the grant revoked mid-run is a test that never runs.
    @Test("A declined capture is reported as the missing grant", arguments: [
        -3801,  // SCStreamErrorUserDeclined
        -3803,  // SCStreamErrorMissingEntitlements
    ])
    func declinedCaptureBecomesTheGrantMessage(code: Int) {
        let mapped = ScreenCapture.Error.from(
            NSError(domain: "SCStreamErrorDomain", code: code)
        )
        guard case .notPermitted = mapped else {
            Issue.record("code \(code) mapped to \(mapped)"); return
        }
        #expect(mapped.description.contains("Screen Recording"))
        #expect(mapped.description.contains("System Settings"))
    }

    /// Everything else keeps its own words. A failure with no sentence is one the model
    /// can only respond to by trying the identical call again.
    @Test("Any other capture failure carries its reason rather than its number")
    func otherCaptureFailuresCarryTheirReason() {
        let mapped = ScreenCapture.Error.from(NSError(
            domain: "SCStreamErrorDomain", code: -3811,
            userInfo: [NSLocalizedDescriptionKey: "the window server went away"]
        ))
        guard case .captureFailed = mapped else {
            Issue.record("mapped to \(mapped), which loses the reason"); return
        }
        #expect(mapped.description.contains("the window server went away"))
        #expect(!mapped.description.contains("-3811"), "an error number reached the model")
    }

    /// And our own errors pass through, or every carefully worded refusal above would
    /// be rewrapped as a capture failure on its way out.
    @Test("An error of our own is not rewrapped by the mapping")
    func ourOwnErrorsPassThroughTheMapping() {
        guard case .noDisplay = ScreenCapture.Error.from(ScreenCapture.Error.noDisplay)
        else { Issue.record("our own error was rewrapped"); return }
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
    ///
    /// And the other side of the same fact, which is why images are numbered: the crop
    /// replaces the whole screen's mapping, while the overview it refines is still in
    /// the append-only transcript where reading another coordinate off it is ordinary.
    /// A point that says which image it came from is checked; one that came off the
    /// image the crop replaced is refused rather than converted through the crop.
    @Test("A zoom becomes the mapping for coordinates read from it")
    func zoomBecomesTheActiveMapping() async throws {
        let context = ScreenContext()
        let overview = await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 1000),
            screenRect: CGRect(x: 0, y: 0, width: 2000, height: 2000), displayID: 1
        ))

        // Zoom into a small region; the spy returns a crop covering it.
        let spy = ZoomCaptureSpy()
        _ = try await ZoomTool(capture: spy, context: context).run(.object([
            "x": .number(100), "y": .number(100),
            "width": .number(50), "height": .number(50),
            "image": .number(Double(overview.generation)),
        ]))

        // A coordinate read off the crop must now map through the crop's rect.
        let mapped = try await context.screenPoint(fromImage: CGPoint(x: 0, y: 0))
        #expect(mapped == CGPoint(x: 200, y: 200),
                "coordinates still map through the earlier screenshot, not the zoom")

        // Named as the crop, it converts the same way — otherwise the refusal below
        // would be indistinguishable from a number nothing ever matches.
        let crop = try #require(await context.screenshotForTesting(of: ScreenIndex(0)))
        #expect(crop.generation == overview.generation + 1)
        #expect(try await context.screenPoint(
            fromImage: CGPoint(x: 0, y: 0), fromImageNumber: crop.generation
        ) == CGPoint(x: 200, y: 200))

        // Named as the overview, it is refused rather than silently converted.
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(
                fromImage: CGPoint(x: 0, y: 0), fromImageNumber: overview.generation
            )
        }
    }

    // MARK: - Which image a coordinate was read off

    /// The failure the numbering exists to catch, driven through the tools.
    ///
    /// Screenshot of a 3440×1440 screen at 1568×804, then a zoom into its top-left
    /// quarter — after which screen 0's mapping covers (0,0,1720,720). The model then
    /// clicks (1400,700) read off the *overview*, meaning screen (3072,1254). Converted
    /// through the crop it landed around 1500 points away, no error, and the verifier
    /// saw *some* change and called the run fulfilled.
    @Test("A coordinate from the image a zoom replaced is refused, not converted")
    func staleCoordinateFromTheOverviewIsRefused() async throws {
        let context = ScreenContext()
        let overview = await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1568, height: 804),
            screenRect: CGRect(x: 0, y: 0, width: 3440, height: 1440), displayID: 1
        ))

        _ = try await ZoomTool(capture: ZoomCaptureSpy(), context: context).run(.object([
            "x": .number(0), "y": .number(0),
            "width": .number(784), "height": .number(402),
            "image": .number(Double(overview.generation)),
        ]))

        let pointer = Spy()
        let output = try await ClickTool(pointer: pointer, context: context).run(.object([
            "x": .number(1400), "y": .number(700),
            "image": .number(Double(overview.generation)),
        ]))

        #expect(output.isError)
        #expect(pointer.aimedAt.isEmpty,
                "clicked at \(pointer.aimedAt) using the mapping the zoom left behind")

        // The refusal has to say which image is current, or the model cannot correct
        // itself from "no" any more than it can for a screen it never captured.
        let error = ScreenToolError.staleImage(requested: 1, current: 2)
        #expect(error.description.contains("image #1"))
        #expect(error.description.contains("image #2"))
    }

    /// The number has to reach the model, or nothing can pass it back. It is in the
    /// note beside a single screenshot and in each caption of a whole-desktop capture.
    @Test("Every image is captioned with the number a coordinate must name")
    func imagesAreNumberedWhereTheModelCanReadIt() async throws {
        let context = ScreenContext()
        let one = try await ScreenshotTool(
            capture: DesktopSpy([Self.ultrawideAndSecondary[0]]),
            context: context, space: .unconstrained
        ).run(.object([:]))
        #expect(captions(of: one).contains { $0.contains("image #1") },
                "a single screenshot never says which image it is")

        let desktop = try await ScreenshotTool(
            capture: DesktopSpy(Self.ultrawideAndSecondary),
            context: context, space: .unconstrained
        ).run(.object([:]))
        let text = captions(of: desktop)
        #expect(text.contains { $0.hasPrefix("Screen 0:") && $0.contains("image #2") })
        #expect(text.contains { $0.hasPrefix("Screen 1:") && $0.contains("image #3") })
    }

    private func captions(of output: ToolOutput) -> [String] {
        output.content.compactMap {
            if case let .text(caption) = $0 { return caption }
            return nil
        }
    }

    /// One number names one image, and one image is of one screen — so a coordinate
    /// carrying its number has already said which monitor it means, including after a
    /// whole-desktop capture where nothing else in the point does.
    @Test("An image number settles which screen a coordinate belongs to")
    func imageNumberNamesItsScreen() async throws {
        let context = ScreenContext()
        _ = try await ScreenshotTool(
            capture: DesktopSpy(Self.ultrawideAndSecondary),
            context: context, space: .unconstrained
        ).run(.object([:]))

        // Unqualified, it is refused: two screens were seen at once.
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 860, y: 360))
        }

        #expect(try await context.screenPoint(
            fromImage: CGPoint(x: 860, y: 360), fromImageNumber: 1
        ) == CGPoint(x: 1720, y: 720))
        #expect(try await context.screenPoint(
            fromImage: CGPoint(x: 400, y: 640), fromImageNumber: 2
        ) == CGPoint(x: 4240, y: 1280))
    }

    /// The counter never goes back. A number that came round again would make a
    /// coordinate read off a replaced image look current, which is the entire failure
    /// the number exists to catch.
    @Test("An image number is never handed out twice")
    func imageNumbersAreNotReused() async throws {
        let context = ScreenContext()
        _ = try await ScreenshotTool(
            capture: DesktopSpy(Self.ultrawideAndSecondary),
            context: context, space: .unconstrained
        ).run(.object([:]))

        _ = try await ZoomTool(capture: ZoomCaptureSpy(), context: context).run(.object([
            "x": .number(0), "y": .number(0),
            "width": .number(100), "height": .number(100),
            "screen": .number(0), "image": .number(1),
        ]))

        let crop = try #require(await context.screenshotForTesting(of: ScreenIndex(0)))
        #expect(crop.generation == 3, "the zoom reused a number the desktop capture gave out")
        // And the number the crop replaced is now refused for that screen.
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(
                fromImage: CGPoint(x: 10, y: 10),
                onScreen: ScreenIndex(0), fromImageNumber: 1
            )
        }
        // The screen the zoom did not touch keeps both its mapping and its number.
        #expect(try await context.screenPoint(
            fromImage: CGPoint(x: 400, y: 640),
            onScreen: ScreenIndex(1), fromImageNumber: 2
        ) == CGPoint(x: 4240, y: 1280))
    }

    /// Every coordinate written before images were numbered omits the number, so an
    /// omitted one has to keep meaning exactly what it meant then.
    @Test("A coordinate that names no image behaves as it always did")
    func anUnnumberedCoordinateStillConverts() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 500),
            screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000), displayID: 1
        ))
        #expect(try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
                == CGPoint(x: 1000, y: 500))
    }

    private actor ZoomCaptureSpy: ScreenCapturing {
        private(set) var regions: [CGRect] = []

        func capture(
            screen: ScreenIndex?, displayID: CGDirectDisplayID?, region: CGRect?,
            space: ImageSpace, quality: CGFloat, excludingBundleIDs: [String]
        ) async throws -> Screenshot {
            if let region { regions.append(region) }
            return Screenshot(
                jpegBase64: "", imageSize: CGSize(width: 400, height: 400),
                screenRect: region ?? .zero, displayID: 1, space: space
            )
        }

        func layout() async throws -> ScreenLayout {
            ScreenLayout(displays: [(1, CGRect(x: 0, y: 0, width: 3440, height: 1440), true)])
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

    // MARK: - A mapping that has outlived the desktop it describes

    /// A 1000×500 image of a 2000×1000 screen, taken `age` seconds ago. Halved, so a
    /// conversion that did happen is exact arithmetic rather than a tolerance.
    private func aged(_ age: TimeInterval) -> Screenshot {
        Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 500),
            screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000), displayID: 1,
            capturedAt: Date(timeIntervalSinceNow: -age)
        )
    }

    /// The defect: `ScreenContext.shared` is process-global and nothing dropped it.
    /// `startFreshConversation` ends the loop, the transcript, the generation counter
    /// and the pending prompts, and the first `click` of the next conversation — made
    /// without a fresh screenshot — was still converted through the previous one's
    /// mapping. Every check on that path passed: `mostRecent` answered, and
    /// `reachesTheModelIntact` compares an image against the space it was itself
    /// encoded for, so it is true by construction and true at any age.
    @Test("A mapping does not survive the conversation that took it")
    func forgettingDropsEveryMapping() async throws {
        let context = ScreenContext()
        await context.record(aged(0))
        #expect(try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
                == CGPoint(x: 1000, y: 500))

        await context.forget()

        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
        }
    }

    /// Every screen, not merely whichever was captured last. A second monitor's mapping
    /// left behind is the same wrong-desktop click one display over — and the store
    /// deliberately keeps one slot per screen, so forgetting the latest is not
    /// forgetting anything.
    @Test("Forgetting drops the screens the last capture did not cover")
    func forgettingDropsEveryScreenNotJustTheLatest() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 1000, height: 500),
            screenRect: CGRect(x: 0, y: 0, width: 2000, height: 1000), displayID: 1,
            screen: ScreenIndex(0)
        ))
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 800, height: 500),
            screenRect: CGRect(x: 2000, y: 0, width: 1600, height: 1000), displayID: 2,
            screen: ScreenIndex(1)
        ))

        await context.forget()

        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(
                fromImage: CGPoint(x: 500, y: 250), onScreen: ScreenIndex(0)
            )
        }
        #expect(await context.screenshotForTesting(of: ScreenIndex(1)) == nil)
    }

    /// The other half, which `forget()` cannot reach: within one conversation there was
    /// no age bound at all. A screenshot taken before a long build, or before the user
    /// spent a minute reading an approval dialog, described a desktop that has since
    /// scrolled, switched app or changed Space — and was converted without complaint.
    ///
    /// Also pins that recording a screenshot does not restart its clock: `record`
    /// rebuilds it through `numbered`, and a fresh `Date()` there would make every
    /// stored mapping permanently young.
    @Test("A coordinate from a screenshot older than the bound is refused")
    func refusesAnExpiredMapping() async throws {
        let context = ScreenContext()
        await context.record(aged(ScreenContext.maximumAge + 60))

        do {
            let converted = try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
            Issue.record("converted to \(converted) through a mapping that had expired")
        } catch let error as ScreenToolError {
            guard case let .expired(age) = error else {
                Issue.record("refused as \(error), which is not the age")
                return
            }
            #expect(age > ScreenContext.maximumAge)
            // The model has to be able to act on it, and the only action is a new
            // capture.
            #expect(error.description.contains("fresh `screenshot`"))
        }
    }

    /// And the bound has to leave legitimate work alone. The gap this has to survive is
    /// not model latency but a human reading an approval dialog between the model
    /// choosing the click and the click being converted — refusing that is refusing the
    /// click the user just approved.
    @Test("A coordinate from a screenshot inside the bound still converts")
    func convertsInsideTheBound() async throws {
        let context = ScreenContext()
        await context.record(aged(ScreenContext.maximumAge - 30))
        #expect(try await context.screenPoint(fromImage: CGPoint(x: 500, y: 250))
                == CGPoint(x: 1000, y: 500))
    }
}
