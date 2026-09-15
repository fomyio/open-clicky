import Foundation
import CoreGraphics
import AppKit

/// A display's place in a stable, speakable ordering of the desktop.
///
/// The model has to be able to say *which screen* it means, and every word available
/// before this was unusable for that. `CGDirectDisplayID` is an opaque number that
/// changes when a monitor is replugged, so it cannot be carried between turns, let
/// alone between runs. `NSScreen.screens` is in an order AppKit does not promise and
/// which is not the order the displays are physically arranged in. Both would have
/// the model naming one screen and acting on another.
///
/// So: 0, 1, 2… left to right across the desktop, top to bottom for a stack. It
/// matches how the user would point at their own monitors, and it is the same word in
/// the environment block, in the tool schemas, and at the point a capture is routed.
public struct ScreenIndex: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: Int

    public init(_ value: Int) { self.value = value }

    public static func < (lhs: ScreenIndex, rhs: ScreenIndex) -> Bool {
        lhs.value < rhs.value
    }

    /// The word used everywhere the model can read it. Kept in one place so the
    /// environment block, the tool descriptions and the error text cannot drift apart.
    public var description: String { "screen \(value)" }

    /// The same word starting a sentence, so a caption is not a second spelling.
    public var capitalized: String { "Screen \(value)" }
}

/// Every display, in `ScreenIndex` order, with the frames to route by.
///
/// The single place a screen index becomes a `CGDirectDisplayID` or a `CGRect`. It is
/// built from a plain list of frames rather than reading the system itself, so the
/// ordering — the part that has to agree across three call sites — can be pinned by a
/// test on a machine with one monitor.
public struct ScreenLayout: Sendable, Equatable {
    public struct Screen: Sendable, Equatable {
        public let index: ScreenIndex
        public let displayID: CGDirectDisplayID
        /// Global points, **top-left origin** — the space `Screenshot.screenRect`,
        /// `SCDisplay.frame` and CGEvent all work in. `NSScreen` does not; see
        /// `ScreenLayout.current()`.
        public let frame: CGRect
        public let isMain: Bool

        /// How this screen is described to the model.
        public var summary: String {
            "\(index): \(Int(frame.width))×\(Int(frame.height)) pt at "
            + "(\(Int(frame.origin.x)),\(Int(frame.origin.y)))\(isMain ? " (main)" : "")"
        }
    }

    public let screens: [Screen]

    public init(displays: [(id: CGDirectDisplayID, frame: CGRect, isMain: Bool)]) {
        self.screens = Self.ordered(displays)
    }

    /// Orders displays by where they sit on the desktop, left to right and then top to
    /// bottom.
    ///
    /// The `displayID` tie-break is not decoration: without a total order, two screens
    /// sharing an origin would sort differently on different calls, and the index the
    /// model was given one turn would name a different monitor the next.
    static func ordered(
        _ displays: [(id: CGDirectDisplayID, frame: CGRect, isMain: Bool)]
    ) -> [Screen] {
        displays
            .sorted {
                if $0.frame.origin.x != $1.frame.origin.x {
                    return $0.frame.origin.x < $1.frame.origin.x
                }
                if $0.frame.origin.y != $1.frame.origin.y {
                    return $0.frame.origin.y < $1.frame.origin.y
                }
                return $0.id < $1.id
            }
            .enumerated()
            .map { position, display in
                Screen(
                    index: ScreenIndex(position),
                    displayID: display.id,
                    frame: display.frame,
                    isMain: display.isMain
                )
            }
    }

    public var isEmpty: Bool { screens.isEmpty }

    public func screen(at index: ScreenIndex) -> Screen? {
        screens.first { $0.index == index }
    }

    public func screen(displayID: CGDirectDisplayID) -> Screen? {
        screens.first { $0.displayID == displayID }
    }

    public func index(of displayID: CGDirectDisplayID) -> ScreenIndex? {
        screen(displayID: displayID)?.index
    }

    /// The screen a global point falls on — how a region routes to the right monitor.
    public func screen(containing point: CGPoint) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    /// Every screen, one line each, for the environment block and for error text that
    /// has to tell the model what it *could* have asked for.
    public var summaries: [String] { screens.map(\.summary) }

    /// The live layout, from AppKit.
    ///
    /// Read here rather than from ScreenCaptureKit because the environment block is
    /// built before any capability check and must not need Screen Recording. The flip
    /// is the whole reason this is a function and not a `map`: `NSScreen.frame` has a
    /// bottom-left origin while everything downstream — captures, clicks, the accessibility
    /// API — is top-left. Ordering the raw AppKit frames would number a vertical stack
    /// upside down relative to the numbering a capture routes by.
    public static func current() -> ScreenLayout {
        let screens = NSScreen.screens
        // The screen whose origin is (0,0) defines the flip. `NSScreen.screens.first`
        // is that screen; with no screens at all there is nothing to flip and nothing
        // to describe.
        guard let zero = screens.first else { return ScreenLayout(displays: []) }
        let originHeight = zero.frame.height

        return ScreenLayout(displays: screens.map { screen in
            let frame = screen.frame
            return (
                id: displayID(of: screen),
                frame: CGRect(
                    x: frame.origin.x,
                    y: originHeight - frame.origin.y - frame.height,
                    width: frame.width,
                    height: frame.height
                ),
                isMain: screen == NSScreen.main
            )
        })
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }
}
