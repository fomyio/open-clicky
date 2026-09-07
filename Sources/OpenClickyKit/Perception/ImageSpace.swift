import Foundation
import CoreGraphics

/// The pixel space a provider hands the model — and the only space the coordinates
/// it reads back mean anything in.
///
/// This was a constant. `ScreenCapture.defaultLongEdge = 1568` is *Anthropic's*
/// number: the largest edge that API preserves, above which it resamples the image
/// server-side. Point the same capture path at OpenAI, Ollama or Groq and the number
/// is wrong, and wrong in the worst available way — the provider silently rescales
/// what we sent, the model reads coordinates off a picture whose pixel dimensions are
/// not the ones `Screenshot.imageSize` recorded, and `screenPoint(fromImage:)` then
/// inverts a ratio that never applied. Every click lands short of its target by the
/// difference. Nothing errors: a click always "succeeds".
///
/// So the cap travels with the provider, from `ModelCapabilities` down through the
/// capture and back out through the coordinate translation. Deliberately a value and
/// not a global: a shared constant is exactly what let one provider's number become
/// every provider's number.
public struct ImageSpace: Sendable, Equatable {

    /// For diagnostics — `doctor` and capture notes name it, because "the image was
    /// rescaled" is unactionable without knowing which space was expected.
    public let name: String

    /// Longest edge, in pixels, the provider passes through untouched.
    public let longEdge: CGFloat

    /// Shortest edge the provider passes through untouched, when it constrains that
    /// separately. `nil` when only the long edge matters.
    ///
    /// OpenAI is the reason this exists: a high-detail image is fitted inside 2048²
    /// *and then* scaled so the short side is 768. Honouring only the long edge would
    /// send a 2048×1330 image and get a 1182×768 one back, which is the same silent
    /// mis-scaling as ignoring the cap entirely — just harder to spot.
    public let shortEdge: CGFloat?

    public init(name: String, longEdge: CGFloat, shortEdge: CGFloat? = nil) {
        self.name = name
        self.longEdge = longEdge
        self.shortEdge = shortEdge
    }

    /// Anthropic: 1568 on the long edge, nothing separate on the short one.
    ///
    /// Measured on a 3024×1964 display, 1568 produced 241KB of base64 for ~2,130
    /// vision tokens where 1920 produced 297KB for ~2,129 — the same cost to the
    /// model and 19% fewer bytes, resent on every subsequent turn.
    public static let anthropic = ImageSpace(name: "Anthropic 1568", longEdge: 1568)

    /// OpenAI high-detail: fitted inside 2048², then the short side reduced to 768.
    ///
    /// The short-side rule is what actually binds on a desktop screenshot. A 3:2
    /// display clamps at 1152×768, not 2048×1365, so sending the long edge alone
    /// would hand the model an image 1.8× larger than the one it sees.
    public static let openAI = ImageSpace(name: "OpenAI 2048/768", longEdge: 2048, shortEdge: 768)

    /// Local vision models served by Ollama, and the conservative choice for anything
    /// else that claims vision.
    ///
    /// 1120 is llama3.2-vision's tile size; llava tiles at 336 and qwen-vl resamples
    /// dynamically. There is no single true number here, so this takes the largest one
    /// a common local model keeps, and the direction of a guess is *smaller* — an
    /// image below the cap is passed through unchanged, an image above it is not.
    public static let localVision = ImageSpace(name: "local 1120", longEdge: 1120)

    /// No claim about any provider. The default for a `Screenshot` built by hand.
    ///
    /// Distinct from a real space rather than defaulting to Anthropic's: a screenshot
    /// nobody supplied a space for has not been checked against one, and saying so is
    /// more useful than asserting a cap that may not be the one in force.
    public static let unconstrained = ImageSpace(name: "unconstrained", longEdge: .infinity)

    /// The long edge a source of this size must be reduced to so that both caps hold.
    ///
    /// Expressed against the source because the short-edge rule is a function of the
    /// aspect ratio: the same 768px short side is 1152 long on a 3:2 display and 1365
    /// on a 16:9 one.
    public func longEdge(fitting source: CGSize) -> CGFloat {
        let long = max(source.width, source.height)
        let short = min(source.width, source.height)
        guard long > 0, short > 0 else { return longEdge }
        guard let shortEdge else { return longEdge }
        // The ratio is preserved by the resample, so capping the short side at
        // `shortEdge` is the same as capping the long side at `shortEdge × ratio`.
        return min(longEdge, shortEdge * (long / short))
    }

    /// Whether an image of this size reaches the model as-is.
    ///
    /// The question `screenPoint(fromImage:)` depends on: if the answer is no, the
    /// provider resampled it and the recorded `imageSize` is not the space the model's
    /// coordinates are in.
    public func preserves(_ size: CGSize) -> Bool {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        // A tolerance of one pixel: Core Image's rounding of the resample can land a
        // pixel over the target, and refusing a whole capture over that would be a
        // guard that fires on nothing but itself.
        guard long <= longEdge + 1 else { return false }
        guard let shortEdge else { return true }
        return short <= shortEdge + 1
    }
}
