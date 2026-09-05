import Foundation
import ApplicationServices
import AppKit

/// A single node in a captured accessibility tree.
public struct AXNode: Sendable {
    /// Stable handle the model uses to act on this element (`e12`).
    public let id: String
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let help: String?
    public let enabled: Bool
    /// Screen frame in points, origin top-left, matching CGEvent's coordinate space.
    public let frame: CGRect?
    public let depth: Int
    public let actions: [String]

    /// Whether this element is something a user could act on.
    public var isInteractive: Bool {
        // An element is actionable if it advertises a press-like action, which is
        // more reliable than matching a hardcoded list of roles.
        actions.contains(where: { $0 != kAXShowMenuAction }) && enabled
    }

    /// A short description for an approval prompt: role and label, no coordinates.
    public var label: String {
        let cleanRole = role.replacingOccurrences(of: "AX", with: "")
        guard let title, !title.isEmpty else { return "\(cleanRole) \(id)" }
        return "\(cleanRole) \"\(title.truncated(40))\" (\(id))"
    }

    /// Whether this node tells the model anything.
    ///
    /// A leaf with no label, no value and nothing to press contributes a line saying
    /// only "a StaticText exists here" — tokens spent on nothing, in the tool whose
    /// cost decides whether the model grounds on the tree or gives up and screenshots.
    /// Containers are kept regardless: their nesting is the structure.
    public var isInformative: Bool {
        isInteractive
            || title?.isEmpty == false
            || value?.isEmpty == false
            || help?.isEmpty == false
    }

    /// One line of the rendered tree.
    public var line: String {
        var parts: [String] = []
        parts.append(String(repeating: "  ", count: depth) + role.replacingOccurrences(of: "AX", with: ""))
        if let subrole { parts.append("[\(subrole.replacingOccurrences(of: "AX", with: ""))]") }
        if let title, !title.isEmpty { parts.append("\"\(title.truncated(60))\"") }
        if let value, !value.isEmpty, value != title {
            // Text-bearing roles carry the content the model is being asked to read —
            // a dialog's message, a label — so they get room. A field's value is
            // usually short and only needs to be recognisable.
            let isProse = role.contains("StaticText") || role.contains("TextArea")
            parts.append("= \"\(value.truncated(isProse ? 240 : 60))\"")
        }
        if let help, !help.isEmpty, help != title { parts.append("(\(help.truncated(40)))") }
        if !enabled { parts.append("<disabled>") }
        if isInteractive {
            parts.append("#\(id)")
            // Name any action beyond a plain press. Without this the model can only
            // guess AXPress, and an element that offers just AXShowMenu or AXRaise
            // fails for a reason nothing on the line explains.
            let other = actions.filter { $0 != kAXPressAction }
            if !other.isEmpty { parts.append("[\(other.joined(separator: ","))]") }
        }
        if let frame {
            parts.append("@\(Int(frame.midX)),\(Int(frame.midY))")
        }
        return parts.joined(separator: " ")
    }
}

/// Captures accessibility trees and keeps the element handles addressable by id.
///
/// This is OpenClicky's grounding layer. Rather than asking the model to predict
/// pixel coordinates from an image — the known failure mode — a capture hands it a
/// labelled list of real elements and it acts on one by id. Same idea as
/// Set-of-Marks, at a fraction of the token cost, and deterministic when it hits.
public actor AXCapture {
    public static let shared = AXCapture()

    /// Element handles from the most recent capture, keyed by the id given to the model.
    ///
    /// Deliberately reset on each capture: an AXUIElement outlives its window only
    /// sometimes, and a stale handle silently acts on the wrong thing. Forcing a
    /// fresh capture before each action makes staleness an explicit error instead.
    private var elements: [String: AXUIElement] = [:]
    private var captureGeneration = 0

    /// Human-readable labels for the last capture's elements, readable without
    /// awaiting the actor.
    ///
    /// `Tool.risk(for:)` is synchronous — it has to be, since the gate consults it
    /// before deciding anything — so an approval prompt could only ever name an
    /// opaque id. "activate element e12" is not something a user can consent to.
    public static let labels = ElementLabels()

    public final class ElementLabels: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func replace(with labels: [String: String]) {
            lock.lock(); storage = labels; lock.unlock()
        }

        /// A description of the element, or the bare id if the capture is stale.
        public func describe(_ id: String) -> String {
            lock.lock(); defer { lock.unlock() }
            return storage[id] ?? id
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notTrusted
        case noFocusedApplication
        case unknownElement(String)
        case actionFailed(String, AXError)

        public var description: String {
            switch self {
            case .notTrusted:
                return """
                Accessibility permission is not granted. OpenClicky needs it to read \
                window contents and to click. Grant it in System Settings ▸ Privacy & \
                Security ▸ Accessibility, then try again.
                """
            case .noFocusedApplication:
                return "No frontmost application could be determined."
            case let .unknownElement(id):
                return "No element '\(id)' in the current capture. Call ax_capture again — the UI has changed since the last one."
            case let .actionFailed(action, code):
                return "Accessibility action '\(action)' failed (AXError \(code.rawValue))."
            }
        }
    }

    /// Whether the process holds the Accessibility (AXIsProcessTrusted) grant.
    public nonisolated var isTrusted: Bool { AXIsProcessTrusted() }

    /// The options key that makes `AXIsProcessTrustedWithOptions` show the system
    /// prompt rather than merely reporting the current state.
    ///
    /// Spelled out rather than read from `kAXTrustedCheckOptionPrompt`: that symbol is
    /// an imported C global, which Swift 6 rightly treats as shared mutable state and
    /// refuses to read across isolation domains. The value is documented, stable API.
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    /// Opens the Accessibility pane and asks the user to grant the permission.
    public nonisolated func requestTrust() {
        let options = [Self.trustedCheckOptionPrompt: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Captures the tree for the frontmost app's focused window.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: capture this app instead of the frontmost one.
    ///   - maxDepth: how deep to descend. Deep trees are mostly layout containers.
    ///   - interactiveOnly: keep only actionable elements and their ancestors.
    public func capture(
        bundleIdentifier: String? = nil,
        maxDepth: Int = 12,
        maxNodes: Int = 400,
        interactiveOnly: Bool = false
    ) throws -> Capture {
        guard isTrusted else { throw Error.notTrusted }

        let app: NSRunningApplication
        if let bundleIdentifier {
            guard let match = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) else {
                throw Error.noFocusedApplication
            }
            app = match
        } else {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                throw Error.noFocusedApplication
            }
            app = frontmost
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Unresponsive apps otherwise block the whole agent turn.
        AXUIElementSetMessagingTimeout(axApp, 2.0)

        captureGeneration += 1
        elements.removeAll(keepingCapacity: true)

        let root = focusedWindow(of: axApp) ?? axApp
        var nodes: [AXNode] = []
        var counter = 0
        var truncation = Truncation()
        walk(
            root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes,
            counter: &counter, truncation: &truncation, into: &nodes
        )

        let total = nodes.count
        if interactiveOnly {
            nodes = nodes.filter { $0.isInteractive || $0.role == kAXWindowRole as String }
        } else {
            // Drop leaves that say nothing, but keep anything with children so the
            // structure survives. A node's children follow it, so a deeper node
            // immediately after it means it is a container.
            nodes = nodes.enumerated().filter { index, node in
                if node.isInformative { return true }
                let next = index + 1 < nodes.count ? nodes[index + 1] : nil
                return next.map { $0.depth > node.depth } ?? false
            }.map(\.element)
        }

        Self.labels.replace(with: Dictionary(
            nodes.filter(\.isInteractive).map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        ))

        return Capture(
            app: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            nodes: nodes,
            totalNodesWalked: total,
            hitNodeLimit: truncation.hitNodeLimit,
            hitDepthLimit: truncation.hitDepthLimit,
            filteredToInteractive: interactiveOnly
        )
    }

    /// The result of a capture, including whether anything was left out.
    ///
    /// Truncation has to be reported. A silently-clipped tree looks complete, so the
    /// model concludes the control it wants does not exist — and then either falls
    /// back to an expensive screenshot or tells the user the control is not there.
    public struct Capture: Sendable {
        public let app: String
        public let nodes: [AXNode]
        public let totalNodesWalked: Int
        public let hitNodeLimit: Bool
        public let hitDepthLimit: Bool
        public let filteredToInteractive: Bool

        /// What the model needs to know about what it is not seeing, if anything.
        public var truncationNote: String? {
            var reasons: [String] = []
            if hitNodeLimit {
                reasons.append("the \(totalNodesWalked)-element limit was reached, so later elements are missing")
            }
            if hitDepthLimit {
                reasons.append("some branches were deeper than the depth limit and were not descended")
            }
            guard !reasons.isEmpty else { return nil }
            return """
                INCOMPLETE: \(reasons.joined(separator: ", and ")). If what you need is not \
                listed it may still exist. Narrow the capture with `interactive_only: true`, \
                raise `max_depth`, or target one app with `bundle_identifier` before \
                concluding the element is absent.
                """
        }
    }

    private struct Truncation {
        var hitNodeLimit = false
        var hitDepthLimit = false
    }

    /// Performs an accessibility action on a previously captured element.
    public func perform(action: String, on id: String) throws {
        guard let element = elements[id] else { throw Error.unknownElement(id) }
        let code = AXUIElementPerformAction(element, action as CFString)
        guard code == .success else { throw Error.actionFailed(action, code) }
    }

    /// Sets an element's value — how text is entered without synthesising keystrokes.
    public func setValue(_ value: String, on id: String) throws {
        guard let element = elements[id] else { throw Error.unknownElement(id) }
        let code = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard code == .success else { throw Error.actionFailed("set value", code) }
    }

    /// Screen frame of a captured element, for handing a target to CGEvent.
    public func frame(of id: String) throws -> CGRect {
        guard let element = elements[id] else { throw Error.unknownElement(id) }
        guard let frame = Self.frame(of: element) else {
            throw Error.actionFailed("read frame", .noValue)
        }
        return frame
    }

    // MARK: - Tree walking

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        if let window = Self.attribute(app, kAXFocusedWindowAttribute) { return (window as! AXUIElement) }
        if let main = Self.attribute(app, kAXMainWindowAttribute) { return (main as! AXUIElement) }
        return nil
    }

    /// Attributes fetched for every node, in one round trip.
    ///
    /// Order matters: results come back positionally.
    /// Held as `[String]` rather than `CFArray`: a static CFArray is shared mutable
    /// state as far as Swift 6 is concerned, and the bridge to CFArray is free.
    private static let batchedAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, kAXEnabledAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXChildrenAttribute,
    ]

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        counter: inout Int,
        truncation: inout Truncation,
        into nodes: inout [AXNode]
    ) {
        if depth > maxDepth {
            truncation.hitDepthLimit = true
            return
        }
        if nodes.count >= maxNodes {
            truncation.hitNodeLimit = true
            return
        }

        // One round trip for all nine attributes instead of nine. Every
        // AXUIElementCopyAttributeValue is IPC to the target application, and a busy
        // window has hundreds of nodes — the difference is most of the capture's cost,
        // on the tool the ladder leans on hardest.
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, Self.batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &raw
        )
        let values = (status == .success ? raw as? [AnyObject] : nil) ?? []

        func value(_ index: Int) -> AnyObject? {
            guard index < values.count else { return nil }
            let candidate = values[index]
            // Missing attributes come back as an AXValue wrapping an AXError rather
            // than as a gap, so they have to be filtered out by type.
            if CFGetTypeID(candidate) == AXValueGetTypeID(),
               AXValueGetType(candidate as! AXValue) == .axError {
                return nil
            }
            return candidate
        }

        func string(_ index: Int) -> String? {
            guard let raw = value(index) else { return nil }
            if let text = raw as? String { return text.isEmpty ? nil : text }
            if let number = raw as? NSNumber { return number.stringValue }
            return nil
        }

        let role = string(0) ?? "AXUnknown"
        let subrole = string(1)


        // Kept as a second round trip: measured at ~7ms of a 26ms capture, and it is
        // what distinguishes an actionable control from a layout container. Deriving
        // interactivity from the role instead would miss custom controls, which is
        // precisely where the accessibility tier earns its place over pixels.
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let actionNames = (actions as? [String]) ?? []

        counter += 1
        let id = "e\(counter)"
        let node = AXNode(
            id: id,
            role: role,
            subrole: subrole,
            title: string(2),
            // A capture reads every node's value, so one password field anywhere in the
            // window would put its contents in the model's context and the transcript.
            value: UIFingerprint.reportableValue(role: role, subrole: subrole, value: string(3)),
            help: string(4),
            enabled: (value(5) as? NSNumber)?.boolValue ?? true,
            frame: Self.frame(position: value(6), size: value(7)),
            depth: depth,
            actions: actionNames
        )
        nodes.append(node)
        if node.isInteractive { elements[id] = element }

        guard let children = value(8) as? [AXUIElement] else { return }
        for child in children {
            walk(
                child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes,
                counter: &counter, truncation: &truncation, into: &nodes
            )
        }
    }

    // MARK: - Attribute helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Builds a frame from position and size values already fetched in a batch.
    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

extension String {
    func truncated(_ limit: Int) -> String {
        let flat = replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
