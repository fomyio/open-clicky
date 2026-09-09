import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// A captured screenshot plus the mapping back to screen coordinates.
public struct Screenshot: Sendable {
    public let jpegBase64: String
    /// Size of the image handed to the model, in pixels.
    public let imageSize: CGSize
    /// Region of the screen the image covers, in points (top-left origin).
    public let screenRect: CGRect
    public let displayID: CGDirectDisplayID
    /// Which screen this is of, in the numbering the model was given.
    ///
    /// Carried rather than looked up later for the same reason as `space`: the display
    /// this was captured from can be unplugged mid-run, after which resolving the id
    /// again would either fail or — worse — resolve to whatever now holds that index.
    /// The number recorded here is the number the model saw beside the image.
    public let screen: ScreenIndex
    /// The provider space this image was sized for.
    ///
    /// Carried on the screenshot rather than looked up at click time because the two
    /// have to be the same value: a capture taken for one provider and converted
    /// against another's cap is precisely the mis-scaling `ImageSpace` exists to stop.
    public let space: ImageSpace

    public init(
        jpegBase64: String,
        imageSize: CGSize,
        screenRect: CGRect,
        displayID: CGDirectDisplayID,
        screen: ScreenIndex = ScreenIndex(0),
        space: ImageSpace = .unconstrained
    ) {
        self.jpegBase64 = jpegBase64
        self.imageSize = imageSize
        self.screenRect = screenRect
        self.displayID = displayID
        self.screen = screen
        self.space = space
    }

    /// Whether the model sees this image at the size we recorded for it.
    ///
    /// False means the provider resampled it on arrival, so `imageSize` is not the
    /// space the coordinates coming back are expressed in.
    public var reachesTheModelIntact: Bool { space.preserves(imageSize) }

    /// Converts a point the model expressed in image pixels to a screen point.
    ///
    /// The model reports coordinates in the pixel space of the image it was sent.
    /// Because we downscale before sending, those are not screen points — skipping
    /// this conversion is the classic computer-use misclick, and it gets worse the
    /// more aggressively we downscale.
    public func screenPoint(fromImage point: CGPoint) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return point }
        let scaleX = screenRect.width / imageSize.width
        let scaleY = screenRect.height / imageSize.height
        return CGPoint(
            x: screenRect.origin.x + point.x * scaleX,
            y: screenRect.origin.y + point.y * scaleY
        )
    }

    public var summary: String {
        "\(Int(imageSize.width))×\(Int(imageSize.height)) px covering \(Int(screenRect.width))×\(Int(screenRect.height)) pt at (\(Int(screenRect.origin.x)),\(Int(screenRect.origin.y)))"
    }
}

/// Where screenshots come from.
///
/// A seam, so a test can see the arguments a tool passed without needing Screen
/// Recording. Without it nothing could verify that `screenshot` forwarded its
/// exclusions, its region or its display — each of which fails silently: the agent
/// photographs its own overlay, or captures the wrong part of the wrong screen.
public protocol ScreenCapturing: Sendable {
    func capture(
        screen: ScreenIndex?,
        displayID: CGDirectDisplayID?,
        region: CGRect?,
        space: ImageSpace,
        quality: CGFloat,
        excludingBundleIDs: [String]
    ) async throws -> Screenshot

    /// The displays, in `ScreenIndex` order. On the seam so a test can describe a
    /// multi-monitor desktop without owning one.
    func layout() async throws -> ScreenLayout
}

/// Screenshots via ScreenCaptureKit.
public actor ScreenCapture: ScreenCapturing {
    public static let shared = ScreenCapture()

    public enum Error: Swift.Error, CustomStringConvertible {
        case notPermitted
        case noDisplay
        /// A display was named that is not attached. Carries what *is* attached,
        /// because the model cannot correct itself from "no".
        case unknownScreen(requested: String, available: [String])
        case encodingFailed

        public var description: String {
            switch self {
            case .notPermitted:
                return """
                Screen Recording permission is not granted. OpenClicky needs it to see \
                the screen. Grant it in System Settings ▸ Privacy & Security ▸ Screen \
                & System Audio Recording, then restart OpenClicky.
                """
            case .noDisplay: return "No matching display was found."
            case let .unknownScreen(requested, available):
                return available.isEmpty
                    ? "There is no \(requested): no displays are attached."
                    : """
                      There is no \(requested). The displays attached are:
                      \(available.map { "  • \($0)" }.joined(separator: "\n"))
                      """
            case .encodingFailed: return "The captured image could not be encoded."
            }
        }
    }

    /// The space a capture is sized for when the caller names none.
    ///
    /// This used to be `defaultLongEdge = 1568`, a bare number that read as a
    /// universal truth and was in fact Anthropic's cap. Naming the provider in the
    /// value is the point: the next reader can see whose number it is, and a run
    /// against a different provider passes its own rather than inheriting this one.
    public static let defaultSpace: ImageSpace = .anthropic

    private let ciContext = CIContext()

    /// Whether Screen Recording is granted. Cheap and side-effect free.
    public nonisolated var isPermitted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system's Screen Recording consent prompt.
    public nonisolated func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Captures a display, or a sub-region of one.
    ///
    /// - Parameters:
    ///   - region: rect to capture, in *global* screen points. `nil` captures the
    ///     whole display. If it falls on a secondary display, that display is used.
    ///   - space: the provider pixel space to size the image for. A crop smaller than
    ///     the space keeps its native pixels — `encode` never upscales — which is
    ///     where `zoom`'s extra detail comes from.
    ///   - excludingBundleIDs: windows to leave out — used to hide our own overlay
    ///     so the agent never sees, and reacts to, its own cursor.
    public func capture(
        screen: ScreenIndex? = nil,
        displayID: CGDirectDisplayID? = nil,
        region: CGRect? = nil,
        space: ImageSpace = ScreenCapture.defaultSpace,
        quality: CGFloat = 0.75,
        excludingBundleIDs: [String] = []
    ) async throws -> Screenshot {
        guard isPermitted else { throw Error.notPermitted }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let layout = Self.layout(of: content.displays)

        // Every named screen is resolved here, and a name that matches nothing is an
        // error rather than a fallback.
        //
        // This used to end in `?? content.displays.first`, which meant asking for a
        // display that was not attached captured *some other monitor* and returned it
        // with that monitor's `screenRect` — a screenshot of the wrong screen,
        // reported as a success, and every coordinate read off it landing there too.
        // Nothing about it was visible to the model. A region names a place on the
        // desktop rather than a screen, so it still routes by containment; falling
        // back to the main display for one would capture the wrong screen the same way.
        let target: ScreenLayout.Screen
        if let screen {
            guard let match = layout.screen(at: screen) else {
                throw Error.unknownScreen(
                    requested: screen.description, available: layout.summaries
                )
            }
            target = match
        } else if let displayID {
            guard let match = layout.screen(displayID: displayID) else {
                throw Error.unknownScreen(
                    requested: "display \(displayID)", available: layout.summaries
                )
            }
            target = match
        } else if let region,
                  let match = layout.screen(
                      containing: CGPoint(x: region.midX, y: region.midY)
                  ) {
            target = match
        } else if let main = layout.screen(displayID: CGMainDisplayID()) {
            target = main
        } else {
            throw Error.noDisplay
        }

        guard let display = content.displays
            .first(where: { $0.displayID == target.displayID }) else {
            throw Error.noDisplay
        }
        let targetID = display.displayID

        let excluded = content.applications.filter {
            excludingBundleIDs.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: excluded, exceptingWindows: []
        )

        guard let geometry = Self.geometry(displayFrame: display.frame, globalRegion: region) else {
            throw Error.noDisplay
        }
        let sourceRect = geometry.sourceRect

        let config = SCStreamConfiguration()
        // Capture at the display's true backing resolution, then downscale ourselves,
        // so a Retina screen is sampled at full fidelity before we lose any of it.
        let scale = backingScale(for: targetID)
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        // The long edge is derived from the space and the source's own proportions,
        // never from a constant: a provider that constrains the short side clamps a
        // wide screenshot far below its nominal long edge, and sending the nominal
        // one hands the model an image it will silently resample.
        let source = CGSize(width: cgImage.width, height: cgImage.height)
        let (jpeg, finalSize) = try encode(
            cgImage, longEdge: space.longEdge(fitting: source), quality: quality
        )

        return Screenshot(
            jpegBase64: jpeg.base64EncodedString(),
            imageSize: finalSize,
            // Global, not display-local. `screenPoint(fromImage:)` feeds CGEvent,
            // which works in the global display space — returning a display-local
            // rect meant every click on a secondary monitor landed on the primary.
            screenRect: geometry.globalRect,
            displayID: display.displayID,
            screen: target.index,
            space: space
        )
    }

    /// Converts a requested global region into the display-local rect ScreenCaptureKit
    /// wants, plus the global rect the resulting image actually covers.
    ///
    /// The two coordinate spaces are the crux: `SCStreamConfiguration.sourceRect` is
    /// relative to its display's own origin, while CGEvent and the accessibility API
    /// both work in the global space where a second monitor might start at x=3440.
    /// Conflating them produces clicks that land on the wrong screen entirely.
    ///
    /// - Returns: `nil` when the region does not overlap the display.
    static func geometry(
        displayFrame: CGRect, globalRegion: CGRect?
    ) -> (sourceRect: CGRect, globalRect: CGRect)? {
        guard let globalRegion else {
            return (
                CGRect(origin: .zero, size: displayFrame.size),
                displayFrame
            )
        }

        let clipped = globalRegion.intersection(displayFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }

        return (
            CGRect(
                x: clipped.origin.x - displayFrame.origin.x,
                y: clipped.origin.y - displayFrame.origin.y,
                width: clipped.width,
                height: clipped.height
            ),
            clipped
        )
    }

    /// Every display, in `ScreenIndex` order.
    public func layout() async throws -> ScreenLayout {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return Self.layout(of: content.displays)
    }

    /// `SCDisplay.frame` is already the global top-left space `ScreenLayout` expects,
    /// so the ordering here is the same ordering `ContextProbe` shows the user.
    private static func layout(of displays: [SCDisplay]) -> ScreenLayout {
        let main = CGMainDisplayID()
        return ScreenLayout(displays: displays.map {
            ($0.displayID, $0.frame, $0.displayID == main)
        })
    }

    private func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? 2.0
    }

    /// Downscales to the long-edge budget and JPEG-encodes.
    ///
    /// Capturing at the display's backing resolution and downscaling here — rather
    /// than asking ScreenCaptureKit for the target size directly — was measured at
    /// 3ms for a 6880×2880 source, the same as encoding an already-small image. Core
    /// Image does the resample on the GPU, so the extra pixels cost nothing worth
    /// reclaiming, and sampling at full fidelity first keeps `zoom` sharp.
    ///
    /// Internal so both the cost and the output properties can be checked against a
    /// synthetic image, on a machine without Screen Recording granted.
    func encode(
        _ image: CGImage, longEdge: CGFloat, quality: CGFloat
    ) throws -> (Data, CGSize) {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1.0, longEdge / max(width, height))

        let source = CIImage(cgImage: image)
        let scaled = scale < 1.0
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: scaled, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
              ) else {
            throw Error.encodingFailed
        }

        // The size of what was rendered, not a separate prediction of it.
        //
        // Computing the target independently — multiplying by the scale and rounding
        // down — disagreed with Core Image's own rounding: a 6880×2880 display
        // downscaled to a 1920 long edge produced an 804-pixel-tall JPEG while this
        // reported 803. Every coordinate the model read off that image was then
        // scaled by the wrong ratio, by a fraction of a pixel near the top and
        // increasingly toward the bottom. Small, silent, and exactly the class of
        // error the whole coordinate path exists to avoid.
        return (data, scaled.extent.size)
    }
}
