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
    ///   - region: screen-space rect to capture, in points. `nil` captures the whole display.
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
        let targetID = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == targetID })
                ?? content.displays.first else {
            throw Error.noDisplay
        }

        let excluded = content.applications.filter {
            excludingBundleIDs.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: excluded, exceptingWindows: []
        )

        let displayRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let sourceRect = region.map { $0.intersection(displayRect) } ?? displayRect
        guard !sourceRect.isNull, sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw Error.noDisplay
        }

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
            screenRect: sourceRect,
            displayID: display.displayID
        )
    }

    /// Every display, for multi-monitor setups.
    public func displays() async throws -> [(id: CGDirectDisplayID, frame: CGRect)] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return content.displays.map {
            ($0.displayID, CGRect(x: $0.frame.origin.x, y: $0.frame.origin.y,
                                  width: CGFloat($0.width), height: CGFloat($0.height)))
        }
    }

    private func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
        return screen?.backingScaleFactor ?? 2.0
    }

    /// Downscales to the long-edge budget and JPEG-encodes.
    private func encode(
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
