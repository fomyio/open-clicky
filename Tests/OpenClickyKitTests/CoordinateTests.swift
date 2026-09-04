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
