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

/// Screenshots via ScreenCaptureKit.
public actor ScreenCapture {
    public static let shared = ScreenCapture()

    public enum Error: Swift.Error, CustomStringConvertible {
        case notPermitted
        case noDisplay
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
            case .encodingFailed: return "The captured image could not be encoded."
            }
        }
    }

    /// Long edge, in pixels, of the image sent to the model.
    ///
    /// 1920 is the documented balance of accuracy against cost: the models accept up
    /// to 2576 px (~4784 vision tokens), but 1080p performs nearly as well for a
    /// fraction of the tokens. `zoom` recovers detail on demand instead.
    public static let defaultLongEdge: CGFloat = 1920

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
    ///   - longEdge: downscale target. Pass a large value for a full-resolution crop.
    ///   - excludingBundleIDs: windows to leave out — used to hide our own overlay
    ///     so the agent never sees, and reacts to, its own cursor.
    public func capture(
        displayID: CGDirectDisplayID? = nil,
        region: CGRect? = nil,
        longEdge: CGFloat? = nil,
        quality: CGFloat = 0.75,
        excludingBundleIDs: [String] = []
    ) async throws -> Screenshot {
        guard isPermitted else { throw Error.notPermitted }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        // A region names a place on the desktop, which may not be the main display.
        // Defaulting to the main one would silently capture the wrong screen and then
        // hand back coordinates for it.
        let resolvedID = displayID ?? region.flatMap { rect in
            Self.display(
                containing: CGPoint(x: rect.midX, y: rect.midY),
                among: content.displays.map { ($0.displayID, $0.frame) }
            )
        } ?? CGMainDisplayID()

        guard let display = content.displays.first(where: { $0.displayID == resolvedID })
                ?? content.displays.first else {
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

        let target = longEdge ?? Self.defaultLongEdge
        let (jpeg, finalSize) = try encode(cgImage, longEdge: target, quality: quality)

        return Screenshot(
            jpegBase64: jpeg.base64EncodedString(),
            imageSize: finalSize,
            // Global, not display-local. `screenPoint(fromImage:)` feeds CGEvent,
            // which works in the global display space — returning a display-local
            // rect meant every click on a secondary monitor landed on the primary.
            screenRect: geometry.globalRect,
            displayID: display.displayID
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

    /// The display containing `point`, for routing a capture to the right screen.
    static func display(containing point: CGPoint, among frames: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        frames.first { $0.frame.contains(point) }?.id
    }

    /// Every display, for multi-monitor setups.
    public func displays() async throws -> [(id: CGDirectDisplayID, frame: CGRect)] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map { ($0.displayID, $0.frame) }
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
        let targetSize = CGSize(
            width: (width * scale).rounded(.down), height: (height * scale).rounded(.down)
        )

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
        return (data, targetSize)
    }
}
