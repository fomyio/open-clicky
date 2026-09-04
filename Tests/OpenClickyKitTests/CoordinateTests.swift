import Testing
import CoreGraphics
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
