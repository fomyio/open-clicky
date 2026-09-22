import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Every application this Mac can be asked to bring forward, as a closed list.
///
/// It exists to make a whole class of request answerable *without a model*. "Open
/// Safari" is not reasoning — it is a lookup in a finite set that is sitting on the
/// disk — and the only reason it ever cost a round trip is that nothing here could
/// enumerate the set. A model asked the same question can name an app that is not
/// installed; a `Choice` over this list cannot, because the option set is the answer
/// space.
///
/// That is also the safety argument for `FocusChange`. An action whose argument came
/// from here is provably an app that exists on this machine, which is what lets it be
/// classified below `.write` — see `FocusChange` for the other half of that.
///
/// **Not an actor, deliberately.** `Tool.risk(for:)` is synchronous and non-throwing, so
/// a tool that has to consult this before classifying its own risk cannot `await`. The
/// cache is a lock instead, and the cost of that choice is paid in `current()`.
public struct AppCatalogue: Sendable, Equatable {

    /// One application.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { bundleIdentifier }
        public let bundleIdentifier: String
        /// What a person would call it. `CFBundleDisplayName`, falling back to
        /// `CFBundleName`, falling back to the filename.
        public let name: String
        /// Where it actually is. The argument `activate_app` uses, so that what is
        /// launched is the thing that was enumerated rather than whatever LaunchServices
        /// resolves a *name* to.
        public let url: URL
        public let isRunning: Bool
        /// Whether more than one installed app shares this one's plain name.
        ///
        /// "Google Chrome" and "Google Chrome Canary" normalise to the same thing, and a
        /// spoken "open chrome" does not choose between them. Rather than detect that in
        /// the *answer* — which needs a probability margin, and a calibrated 0.91 between
        /// two near-identical options is a coin flip wearing a decimal point — the
        /// ambiguity is removed from the *question*: the group collapses to one entry,
        /// marked here, and a marked entry is never fast-pathed.
        public let isAmbiguous: Bool
        public let rank: Rank

        public init(
            bundleIdentifier: String, name: String, url: URL,
            isRunning: Bool, isAmbiguous: Bool = false, rank: Rank = .user
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.url = url
            self.isRunning = isRunning
            self.isAmbiguous = isAmbiguous
            self.rank = rank
        }

        /// How this entry is described to a classifier picking between them.
        ///
        /// The running state travels with the name because it is how a tie gets broken
        /// the way a person would break it: "open chrome" said while Chrome is open means
        /// the one that is open.
        public var criterion: String {
            if isAmbiguous {
                return "\(name) — several versions of this are installed, so which one is "
                    + "meant is not clear from the name alone."
            }
            return isRunning ? "\(name) (currently running)" : "\(name) (not running)"
        }
    }

    /// Why an app is near the front of the list when the list has to be cut.
    public enum Rank: Int, Sendable, Equatable, Comparable, CaseIterable {
        /// Running right now. Overwhelmingly the likely target, and never more than a
        /// few dozen.
        case running = 0
        /// Installed by the user, in `/Applications` or `~/Applications`.
        case user = 1
        /// Shipped with macOS. Kept last because a machine with too many apps to fit is
        /// a machine whose *own* apps are the ones the user means.
        case system = 2

        public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let entries: [Entry]

    /// Whether anything was cut to fit the cap.
    ///
    /// Load-bearing, not diagnostic. A `Choice` always returns one of the options it was
    /// given, so a classifier shown a truncated list will confidently name the closest
    /// thing it *was* shown — which is how "open Fantastical" launches Calendar. A
    /// truncated catalogue is what tells the fast path to offer an escape hatch and to
    /// distrust a marginal answer.
    public let truncated: Bool

    public init(entries: [Entry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }

    public static let empty = AppCatalogue(entries: [], truncated: false)

    public func entry(bundleIdentifier: String) -> Entry? {
        entries.first { $0.bundleIdentifier == bundleIdentifier }
    }

    // MARK: - Building, which is pure

    /// How many apps may be offered.
    ///
    /// Under Jev's 255-option ceiling with room left for the fixed verb sets and for the
    /// synthetic options the fast path adds. A typical Mac is nowhere near it — this
    /// machine has 115 installed — so the cap is a guard against a developer's laptop,
    /// not a routine condition.
    public static let limit = 200

    /// Assembles a catalogue from what was found and what is running.
    ///
    /// Split from the scan so the rules that matter — exclusion, collapsing, ranking,
    /// truncation — are a pure function over a list a test can write down, rather than
    /// something that can only be exercised by having the right apps installed.
    public static func build(
        installed: [Found],
        running: [Running],
        selfBundleIDs: Set<String> = [],
        limit: Int = AppCatalogue.limit
    ) -> AppCatalogue {
        var byIdentifier: [String: Found] = [:]
        for found in installed where !selfBundleIDs.contains(found.bundleIdentifier) {
            // First writer wins, and the roots are ordered so that is the user's copy.
            if byIdentifier[found.bundleIdentifier] == nil {
                byIdentifier[found.bundleIdentifier] = found
            }
        }
        // A running app may live somewhere nothing scans — a debug build, a download,
        // an app bundle inside a project directory. It is on screen, so it is by far the
        // most likely thing meant, and leaving it out because of where it lives would be
        // the single most visible way this list could be wrong.
        let runningIDs = Set(running.map(\.bundleIdentifier))
        for app in running where !selfBundleIDs.contains(app.bundleIdentifier) {
            if byIdentifier[app.bundleIdentifier] == nil {
                byIdentifier[app.bundleIdentifier] = Found(
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    url: app.url,
                    isSystem: false
                )
            }
        }

        // Collapse the groups that a spoken name cannot tell apart.
        var countsByPlainName: [String: Int] = [:]
        for found in byIdentifier.values {
            countsByPlainName[plainName(found.name), default: 0] += 1
        }

        var entries = byIdentifier.values.map { found -> Entry in
            let isRunning = runningIDs.contains(found.bundleIdentifier)
            return Entry(
                bundleIdentifier: found.bundleIdentifier,
                name: found.name,
                url: found.url,
                isRunning: isRunning,
                isAmbiguous: (countsByPlainName[plainName(found.name)] ?? 0) > 1,
                rank: isRunning ? .running : (found.isSystem ? .system : .user)
            )
        }

        // Stable, so the same machine produces the same list twice — a test can read it,
        // and an unstable option order would change the request on every utterance for
        // no reason.
        entries.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let left = $0.name.lowercased(), right = $1.name.lowercased()
            if left != right { return left < right }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }

        let truncated = entries.count > limit
        if truncated { entries = Array(entries.prefix(limit)) }
        return AppCatalogue(entries: entries, truncated: truncated)
    }

    /// An app as the scan found it.
    public struct Found: Sendable, Equatable {
        public let bundleIdentifier: String
        public let name: String
        public let url: URL
        public let isSystem: Bool

        public init(bundleIdentifier: String, name: String, url: URL, isSystem: Bool) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.url = url
            self.isSystem = isSystem
        }
    }

    /// An app as the workspace reports it running.
    public struct Running: Sendable, Equatable {
        public let bundleIdentifier: String
        public let name: String
        public let url: URL

        public init(bundleIdentifier: String, name: String, url: URL) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.url = url
        }
    }

    /// The name with the words that distinguish one build of an app from another taken
    /// off, which is what a spoken name actually carries.
    ///
    /// Deliberately a small list. Stripping too much would collapse apps that a person
    /// *does* distinguish by name — "Music" and "Music Box" are not the same request —
    /// and every wrong collapse costs a fast path that should have fired.
    static func plainName(_ name: String) -> String {
        // Format characters first. A bundle display name can carry a leading
        // left-to-right mark — WhatsApp's does on this machine — which is invisible in
        // every log and makes two identical names compare unequal.
        let cleaned = name.lowercased().unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
        var words = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .map(String.init)
        let variants: Set<String> = [
            "beta", "canary", "dev", "developer", "nightly", "preview", "alpha",
            "insiders", "edition", "(setapp)", "setapp",
        ]
        // `words.count > 1` is the whole of this loop's safety. Without it a name that
        // *is* a variant word — "Developer", "Preview", both real apps on this machine —
        // strips to nothing, and every such app collapses into one ambiguous group with
        // every other. Found by running the scan against a real disk, not by a test:
        // the empty string is a plausible-looking key right up until two apps share it.
        while words.count > 1, let last = words.last,
              variants.contains(last) || last.allSatisfy({ $0.isNumber || $0 == "." }) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Reading the disk

public extension AppCatalogue {

    /// Where applications live, in the order a tie is broken.
    ///
    /// One level deep, plus `Utilities`. **Never recursive**, and that is not a
    /// performance note: every `.app` contains more `.app`s — helpers, crash reporters,
    /// an Electron app's renderer, Xcode's several dozen embedded tools — and none of
    /// them is ever what somebody meant. A recursive walk would bury the fourteen apps a
    /// person uses under four hundred they have never heard of, and then spend the
    /// option budget on them.
    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
    }

    /// Everything found under `roots`.
    static func scan(roots: [URL] = AppCatalogue.roots) -> [Found] {
        let manager = FileManager.default
        var found: [Found] = []
        for root in roots {
            let isSystem = root.path.hasPrefix("/System/")
            guard let names = try? manager.contentsOfDirectory(atPath: root.path) else {
                continue
            }
            for name in names where name.hasSuffix(".app") {
                let url = root.appendingPathComponent(name, isDirectory: true)
                if let app = read(bundleAt: url, isSystem: isSystem) { found.append(app) }
            }
        }
        return found
    }

    /// Reads one bundle's `Info.plist`.
    ///
    /// Straight through `PropertyListSerialization` rather than `Bundle(url:)`: this runs
    /// over a few hundred bundles and `Bundle` caches every one it is handed, keeping
    /// them alive for the life of the process to answer a question we ask once.
    static func read(bundleAt url: URL, isSystem: Bool) -> Found? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let info = raw as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else { return nil }

        // A menu-bar agent has no window to bring forward, so "activate" on one does
        // nothing observable — it would be offered as a choice, picked, run, and verify
        // as unchanged. An option that cannot succeed is worse than an absent one.
        if info["LSUIElement"] as? Bool == true || info["LSBackgroundOnly"] as? Bool == true {
            return nil
        }
        if let flag = info["LSUIElement"] as? String, flag == "1" { return nil }

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Found(bundleIdentifier: identifier, name: name, url: url, isSystem: isSystem)
    }

    /// The catalogue as it stands right now.
    ///
    /// **The installed list is cached; the running set never is.** They are cached
    /// differently because they change differently: installing an app is rare and
    /// scanning for it is expensive, while which apps are running changes constantly and
    /// reading it is an array lookup in this process. Caching the second would produce
    /// "Safari (not running)" for the app that is frontmost — the one error that makes
    /// the whole feature look broken, because the user is looking straight at it.
    static func current(selfBundleIDs: Set<String> = []) -> AppCatalogue {
        build(
            installed: Cache.shared.installed(),
            running: runningApplications(),
            selfBundleIDs: selfBundleIDs
        )
    }

    /// Scans ahead of the first request, so nothing waits on the disk mid-sentence.
    static func warm() {
        _ = Cache.shared.installed()
    }

    static func runningApplications() -> [Running] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.compactMap { app in
            // `.regular` only: an accessory or prohibited app has no windows and no Dock
            // tile, so there is nothing to bring forward.
            guard app.activationPolicy == .regular,
                  let identifier = app.bundleIdentifier,
                  let url = app.bundleURL
            else { return nil }
            let name = app.localizedName
                ?? url.deletingPathExtension().lastPathComponent
            return Running(bundleIdentifier: identifier, name: name, url: url)
        }
        #else
        return []
        #endif
    }

    /// The installed list, behind a lock.
    ///
    /// A lock rather than an actor because `Tool.risk(for:)` is synchronous and
    /// non-throwing — a tool consulting this to classify its own risk has no `await` to
    /// spend. The lock is held only around the two stored properties, never across the
    /// scan itself.
    final class Cache: @unchecked Sendable {
        static let shared = Cache()

        /// The floor on how often the disk is touched. Short enough that an app
        /// installed during a session becomes reachable within a few sentences, long
        /// enough that a fast path firing every three words does not restat the disk
        /// every time.
        static let lifetime: TimeInterval = 300

        private let lock = NSLock()
        private var entries: [Found] = []
        private var scannedAt: Date = .distantPast
        private var signature: [String: Date] = [:]

        func installed() -> [Found] {
            let now = Date()
            let live = Self.signature()
            lock.lock()
            let fresh = now.timeIntervalSince(scannedAt) < Self.lifetime && live == signature
            let cached = entries
            lock.unlock()
            if fresh, !cached.isEmpty { return cached }

            // Outside the lock: a scan takes long enough that holding it would serialise
            // every caller behind the disk.
            let scanned = AppCatalogue.scan()
            lock.lock()
            entries = scanned
            scannedAt = now
            signature = live
            lock.unlock()
            return scanned
        }

        /// The roots' modification times, which change when an app is added or removed.
        ///
        /// Checked on every read — five `stat` calls, microseconds — so an install is
        /// picked up on the next utterance rather than after the lifetime expires. The
        /// TTL is the floor under this, for the cases mtime does not move.
        private static func signature() -> [String: Date] {
            var stamps: [String: Date] = [:]
            for root in AppCatalogue.roots {
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: root.path)
                stamps[root.path] = (attributes?[.modificationDate] as? Date) ?? .distantPast
            }
            return stamps
        }
    }
}
