import Foundation
import CoreGraphics

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
        /// `SCDisplay.frame`, `CGDisplayBounds` and CGEvent all work in. `NSScreen`
        /// does not, which is why it is no longer read here; see
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

    /// The screen a region mostly falls on, by overlapping area.
    ///
    /// Routing a region by its midpoint answered the wrong question twice. On an
    /// L-shaped desktop the midpoint of a perfectly capturable region can be on no
    /// display at all, and the caller then fell through to the main one and captured a
    /// clipped corner of somewhere else. And a region straddling two monitors has its
    /// midpoint on one of them by an arbitrary pixel, where what the model asked to see
    /// is mostly on the other.
    ///
    /// Containment is kept as the fallback for the one case area cannot answer: a
    /// zero-width or zero-height region overlaps nothing but still names a place.
    public func screen(overlapping region: CGRect) -> Screen? {
        let overlaps = screens
            .map { ($0, $0.frame.intersection(region)) }
            .filter { !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 }
        // `max(by:)` on a tie returns the later element; comparing the index second
        // keeps two equally-overlapped screens resolving to the lower-numbered one
        // every time, for the same reason `ordered` breaks its ties.
        let largest = overlaps.max {
            let left = $0.1.width * $0.1.height, right = $1.1.width * $1.1.height
            return left == right ? $0.0.index > $1.0.index : left < right
        }
        return largest?.0
            ?? screen(containing: CGPoint(x: region.midX, y: region.midY))
    }

    /// Every screen, one line each, for the environment block and for error text that
    /// has to tell the model what it *could* have asked for.
    public var summaries: [String] { screens.map(\.summary) }

    /// The live layout, from Core Graphics.
    ///
    /// Read here rather than from ScreenCaptureKit because the environment block is
    /// built before any capability check and must not need Screen Recording — and
    /// `CGGetActiveDisplayList`/`CGDisplayBounds` need no grant either, while already
    /// answering in the global, top-left space every consumer works in.
    ///
    /// This used to read `NSScreen` and flip each frame by
    /// `NSScreen.screens.first.frame.height`, which made the block the model reads a
    /// *second* computation of something the capture path already computes — and two
    /// computations of one thing drift. Both divergences were real:
    ///
    /// - The flip constant assumed `NSScreen.screens.first` is the screen at the
    ///   origin. Nothing promises that. When it is not, every `y` in the `<screens>`
    ///   block is off by a constant while capture routing stays right, so the model
    ///   reasons about a desktop laid out differently from the one it acts on.
    /// - `isMain` was `screen == NSScreen.main`, which is the screen holding the *key
    ///   window*, while `ScreenCapture.resolve` sends an unnamed capture to
    ///   `CGMainDisplayID()`. With the user focused on a secondary display the block
    ///   labelled one monitor "(main)" and the screenshot came back from another.
    ///
    /// There is one source now, and it is the one capture routes by.
    public static func current() -> ScreenLayout {
        describing(
            displays: activeDisplayIDs(),
            main: CGMainDisplayID(),
            bounds: CGDisplayBounds
        )
    }

    /// The pure half of `current()`, kept separate for the same reason
    /// `ScreenLayout(displays:)` takes a plain list: the part that has to agree with
    /// the capture path is decidable arithmetic, and a machine with one monitor can
    /// exhibit neither the flip nor the focus-follows-main divergence.
    static func describing(
        displays ids: [CGDirectDisplayID],
        main: CGDirectDisplayID,
        bounds: (CGDirectDisplayID) -> CGRect
    ) -> ScreenLayout {
        ScreenLayout(displays: ids.map {
            // No flip. `CGDisplayBounds` is already global top-left, the space
            // `Screenshot.screenRect` and CGEvent are in.
            (id: $0, frame: bounds($0), isMain: $0 == main)
        })
    }

    /// Every attached, awake display.
    ///
    /// Asked for its size first, because the count is the caller's to allocate and a
    /// list read into a buffer sized by a guess would silently truncate a desktop —
    /// a monitor the model is never told about is one it can never ask to look at.
    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        // `count` is written again with how many were actually filled in, which can be
        // fewer than were counted if a display went away between the two calls.
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
