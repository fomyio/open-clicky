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

    /// When the pixels were taken off the screen.
    ///
    /// A mapping is only true of the desktop it was photographed on, and nothing else
    /// here records when that was. The image number catches a mapping this process
    /// *replaced*; it cannot catch one nothing replaced and the world moved on from —
    /// a screenshot taken before a long shell command, or before the user answered a
    /// question, converts a coordinate against a desktop that has since scrolled,
    /// switched app or gone to a different Space. See `ScreenContext.maximumAge`.
    public let capturedAt: Date

    /// Which image this is, in the order `ScreenContext` recorded them. Zero until it
    /// has recorded one.
    ///
    /// The transcript is append-only, so every image the model has been sent is still
    /// in front of it and reading a coordinate off an older one is ordinary behaviour.
    /// A `zoom` replaces the mapping for the screen it crops, and without a number on
    /// each image a point read off the overview was converted through the crop: on a
    /// 3440-wide screen zoomed into its top-left quarter, a click meant for (3072,1254)
    /// landed at (1536,768) — 1500 points out, no error, and the verifier saw *some*
    /// change and called it done.
    public let generation: Int

    /// The region that was asked for, when what came back does not cover all of it.
    ///
    /// `nil` when the capture covers exactly what was requested. A region reaching past
    /// the edge of the display it is captured from is clipped to that display, and a
    /// model told only the size of what came back concludes the missing half of the
    /// window is not on screen.
    public let clippedFrom: CGRect?

    public init(
        jpegBase64: String,
        imageSize: CGSize,
        screenRect: CGRect,
        displayID: CGDirectDisplayID,
        screen: ScreenIndex = ScreenIndex(0),
        space: ImageSpace = .unconstrained,
        capturedAt: Date = Date(),
        generation: Int = 0,
        clippedFrom: CGRect? = nil
    ) {
        self.jpegBase64 = jpegBase64
        self.imageSize = imageSize
        self.screenRect = screenRect
        self.displayID = displayID
        self.screen = screen
        self.space = space
        self.capturedAt = capturedAt
        self.generation = generation
        self.clippedFrom = clippedFrom
    }

    /// The same capture, stamped with the number the model will see beside it.
    ///
    /// Stamped on the way into `ScreenContext` rather than at capture time: the number
    /// has to come from the store that answers coordinates, or two stores would hand
    /// out the same number for different images.
    func numbered(_ generation: Int) -> Screenshot {
        Screenshot(
            jpegBase64: jpegBase64, imageSize: imageSize, screenRect: screenRect,
            displayID: displayID, screen: screen, space: space,
            // Carried, never restamped. Recording is what ages a screenshot *from*, so
            // a fresh `Date()` here would reset the clock on every image at the moment
            // it entered the store and no mapping could ever be old enough to refuse.
            capturedAt: capturedAt,
            generation: generation, clippedFrom: clippedFrom
        )
    }

    /// How an image tells the model to name it when reading a coordinate off it.
    ///
    /// Empty for a screenshot nothing has recorded: it has no number, and inventing a
    /// sentence about one would have the model pass a number that matches nothing.
    public var imageHint: String {
        generation > 0
            ? " Pass `image: \(generation)` with any coordinate you read off it."
            : ""
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
    ///
    /// - Returns: `nil` when there is no ratio to invert. This used to return the point
    ///   it was handed, which is the same misclick wearing a fallback: a degenerate
    ///   `imageSize` on a screenshot of a display at x=3440 turned image (640,400) into
    ///   screen (640,400) — a click on the *primary* monitor, reported as a success.
    ///   An Optional is what stops that answer being reachable again.
    public func screenPoint(fromImage point: CGPoint) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scaleX = screenRect.width / imageSize.width
        let scaleY = screenRect.height / imageSize.height
        return CGPoint(
            x: screenRect.origin.x + point.x * scaleX,
            y: screenRect.origin.y + point.y * scaleY
        )
    }

    public var summary: String {
        var text = "\(Int(imageSize.width))×\(Int(imageSize.height)) px covering \(Int(screenRect.width))×\(Int(screenRect.height)) pt at (\(Int(screenRect.origin.x)),\(Int(screenRect.origin.y)))"
        // Stated, not implied. A region that overhangs its display comes back trimmed,
        // and the only difference between that and the region the model asked for was
        // two numbers it had no reason to re-read.
        if let clippedFrom {
            text += ", clipped from the \(Int(clippedFrom.width))×\(Int(clippedFrom.height)) pt asked for at (\(Int(clippedFrom.origin.x)),\(Int(clippedFrom.origin.y)))"
        }
        if generation > 0 { text += ", image #\(generation)" }
        return text
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
        /// ScreenCaptureKit refused for a reason that is not a missing grant. Carries
        /// its words, because the alternative was the model reading `SCStreamErrorDomain
        /// error -3811` — a number, where every other failure here is a sentence.
        case captureFailed(String)

        /// The two ScreenCaptureKit codes that mean the grant is not there.
        ///
        /// Hard-coded rather than read back from `SCStreamError.Code` because what
        /// actually arrives is an `NSError` carrying this domain and code, and the
        /// mapping has to be checkable from a synthesised one — a test that needs the
        /// Screen Recording grant revoked mid-run is a test that never runs.
        private static let scStreamDomain = "SCStreamErrorDomain"
        private static let userDeclined = -3801
        private static let missingEntitlements = -3803

        /// Turns whatever ScreenCaptureKit threw into something the model can act on.
        ///
        /// `isPermitted` is `CGPreflightScreenCaptureAccess()`, whose answer is cached
        /// for the life of the process. Revoke the grant after launch — or run the CLI
        /// from a terminal whose own grant changed — and it still says yes while every
        /// SCK call throws. That throw is neither `ScreenCapture.Error` nor
        /// `Policy.Violation`, so it used to fall past the tools' catches and reach the
        /// model as a bare error number, three lines from the text that tells a user
        /// which System Settings pane to open.
        ///
        /// Static and pure so it can be checked with an `NSError` built by hand.
        public static func from(_ underlying: Swift.Error) -> Error {
            if let ours = underlying as? Error { return ours }
            let error = underlying as NSError
            if error.domain == scStreamDomain,
               error.code == userDeclined || error.code == missingEntitlements {
                return .notPermitted
            }
            return .captureFailed(error.localizedDescription)
        }

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
            case let .captureFailed(reason):
                return """
                The screen could not be captured: \(reason). Try again, or read the \
                window with `ax_capture` instead.
                """
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

        let content = try await Self.shareableContent()
        let layout = Self.layout(of: content.displays)
        let target = try Self.resolve(
            screen: screen, displayID: displayID, region: region, in: layout
        )

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

        // Stamped around the sample, not after the encode: the ~3ms of downscaling
        // and JPEG is irrelevant, but taking the time *before* the shutter means the
        // age covers the capture itself, and an age can only ever be rounded up.
        let capturedAt = Date()
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            throw Error.from(error)
        }

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
            space: space,
            capturedAt: capturedAt,
            // What was asked for, when it is not what came back. A region reaching over
            // the edge of its display is captured trimmed, and saying so in the summary
            // is the difference between the model knowing its crop was cut short and it
            // reporting that what it was looking for is not on screen.
            clippedFrom: geometry.clippedFrom
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
    /// - Returns: `nil` when the region does not overlap the display. `clippedFrom`
    ///   carries the region that was asked for when the capture could not cover all of
    ///   it, so the difference is stated in the screenshot's summary rather than left
    ///   as two numbers the model had no reason to re-read. Decided here, with the
    ///   clipping itself, so it can be checked without Screen Recording.
    static func geometry(
        displayFrame: CGRect, globalRegion: CGRect?
    ) -> (sourceRect: CGRect, globalRect: CGRect, clippedFrom: CGRect?)? {
        guard let globalRegion else {
            return (
                CGRect(origin: .zero, size: displayFrame.size),
                displayFrame,
                nil
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
            clipped,
            clipped == globalRegion ? nil : globalRegion
        )
    }

    /// Which screen a capture request names.
    ///
    /// Every named screen is resolved here, and a name that matches nothing is an
    /// error rather than a fallback.
    ///
    /// This used to end in `?? content.displays.first`, which meant asking for a
    /// display that was not attached captured *some other monitor* and returned it with
    /// that monitor's `screenRect` — a screenshot of the wrong screen, reported as a
    /// success, and every coordinate read off it landing there too. Nothing about it
    /// was visible to the model. A region names a place on the desktop rather than a
    /// screen, so it still routes by containment; falling back to the main display for
    /// one would capture the wrong screen the same way.
    ///
    /// Pulled out of `capture` and made pure so it can be checked without Screen
    /// Recording. What it does with a name that matches nothing is the whole point of
    /// it, and a test that only runs on a granted machine is a test that does not run.
    static func resolve(
        screen: ScreenIndex?,
        displayID: CGDirectDisplayID?,
        region: CGRect?,
        in layout: ScreenLayout
    ) throws -> ScreenLayout.Screen {
        if let screen {
            guard let match = layout.screen(at: screen) else {
                throw Error.unknownScreen(
                    requested: screen.description, available: layout.summaries
                )
            }
            return match
        }
        if let displayID {
            guard let match = layout.screen(displayID: displayID) else {
                throw Error.unknownScreen(
                    requested: "display \(displayID)", available: layout.summaries
                )
            }
            return match
        }
        if let region {
            // Total, rather than falling through to the main display when nothing
            // matched. It used to fall through, which on an L-shaped desktop — where a
            // region's midpoint can be on neither monitor — captured a clipped corner of
            // the wrong screen, exactly the fallback the paragraph above says was
            // removed. Routing by overlap rather than by midpoint also picks the right
            // monitor for a region that straddles two.
            guard let match = layout.screen(overlapping: region) else {
                throw Error.unknownScreen(
                    requested: "screen under the region at "
                        + "(\(Int(region.origin.x)),\(Int(region.origin.y))) "
                        + "\(Int(region.width))×\(Int(region.height)) pt",
                    available: layout.summaries
                )
            }
            return match
        }
        // The layout carries which display is main, so this needs nothing from the
        // window server and the function stays checkable off a real desktop.
        guard let main = layout.screens.first(where: \.isMain) ?? layout.screens.first
        else { throw Error.noDisplay }
        return main
    }

    /// Every display, in `ScreenIndex` order.
    public func layout() async throws -> ScreenLayout {
        Self.layout(of: try await Self.shareableContent().displays)
    }

    /// The one call into `SCShareableContent`.
    ///
    /// Both routes into capture ask for it, and both used to let its `SCStreamError`
    /// escape untranslated — so a revoked grant reached the model as an error number.
    /// One call site is one place for that to be wrong.
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw Error.from(error)
        }
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
