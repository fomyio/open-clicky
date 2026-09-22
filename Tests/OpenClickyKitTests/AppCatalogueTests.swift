import Testing
import Foundation
@testable import OpenClickyKit

/// The list that makes "open Safari" answerable without a model.
///
/// Every rule here is about what must *not* be in it. An option list is an answer space:
/// a classifier shown a bad option will pick it confidently, and an option it cannot act
/// on is a silent no-op. So the tests are mostly exclusions, and the one about
/// truncation is the one that matters most — a list that quietly drops an app produces a
/// confident wrong answer rather than no answer.
@Suite("App catalogue")
struct AppCatalogueTests {

    private func found(
        _ identifier: String, _ name: String, isSystem: Bool = false
    ) -> AppCatalogue.Found {
        AppCatalogue.Found(
            bundleIdentifier: identifier,
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            isSystem: isSystem
        )
    }

    private func running(_ identifier: String, _ name: String) -> AppCatalogue.Running {
        AppCatalogue.Running(
            bundleIdentifier: identifier,
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    // MARK: - What goes in

    @Test("A running app is marked as running, and sorts ahead of one that is not")
    func runningSortsFirst() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Safari", "Safari"), found("com.apple.Notes", "Notes")],
            running: [running("com.apple.Notes", "Notes")]
        )
        #expect(catalogue.entries.first?.bundleIdentifier == "com.apple.Notes")
        #expect(catalogue.entry(bundleIdentifier: "com.apple.Notes")?.isRunning == true)
        #expect(catalogue.entry(bundleIdentifier: "com.apple.Safari")?.isRunning == false)
    }

    /// The most visible way this list could be wrong. A running app may live somewhere
    /// nothing scans — a debug build, a download, an app inside a project directory —
    /// and it is on screen, so it is by far the likeliest thing meant.
    @Test("An app running from an unscanned place is still offered")
    func runningFromAnywhereIsIncluded() {
        let catalogue = AppCatalogue.build(
            installed: [],
            running: [AppCatalogue.Running(
                bundleIdentifier: "com.example.Debug",
                name: "Debug Build",
                url: URL(fileURLWithPath: "/Users/someone/build/Debug Build.app")
            )]
        )
        #expect(catalogue.entries.count == 1)
        #expect(catalogue.entries.first?.isRunning == true)
    }

    /// Our own surface is not the user's. Focusing ourselves is never what was meant,
    /// and it would fight the focus the app hands back before a run starts.
    @Test("Our own bundle is never offered")
    func selfIsExcluded() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.openclicky.app", "OpenClicky"), found("com.apple.Safari", "Safari")],
            running: [running("com.openclicky.app", "OpenClicky")],
            selfBundleIDs: ["com.openclicky.app"]
        )
        #expect(catalogue.entry(bundleIdentifier: "com.openclicky.app") == nil,
                "the agent offered itself as somewhere to switch to")
        #expect(catalogue.entries.count == 1)
    }

    @Test("The same app found twice is offered once")
    func duplicatesCollapse() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Safari", "Safari"), found("com.apple.Safari", "Safari")],
            running: [running("com.apple.Safari", "Safari")]
        )
        #expect(catalogue.entries.count == 1)
    }

    // MARK: - Ambiguity, removed from the question rather than the answer

    /// "Open chrome" does not choose between these, and no probability margin can make
    /// it. Detecting it here — where it is a pure function over the installed list —
    /// beats detecting it in the answer, where it needs a calibrated margin between two
    /// near-identical options.
    @Test("Two builds of one app collapse into a single ambiguous option")
    func variantsAreMarkedAmbiguous() {
        let catalogue = AppCatalogue.build(
            installed: [
                found("com.google.Chrome", "Google Chrome"),
                found("com.google.Chrome.canary", "Google Chrome Canary"),
                found("com.apple.Safari", "Safari"),
            ],
            running: []
        )
        #expect(catalogue.entry(bundleIdentifier: "com.google.Chrome")?.isAmbiguous == true)
        #expect(catalogue.entry(bundleIdentifier: "com.google.Chrome.canary")?.isAmbiguous == true)
        #expect(catalogue.entry(bundleIdentifier: "com.apple.Safari")?.isAmbiguous == false,
                "an app with no rival was marked ambiguous")
    }

    /// Stripping too much is its own failure: these are different requests, and a wrong
    /// collapse costs a fast path that should have fired.
    @Test("Apps that merely share a word are not confused for each other")
    func similarNamesAreNotCollapsed() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Music", "Music"), found("com.example.MusicBox", "Music Box")],
            running: []
        )
        #expect(catalogue.entries.allSatisfy { !$0.isAmbiguous })
    }

    @Test("A version suffix is not part of the spoken name", arguments: [
        ("Google Chrome", "google chrome"),
        ("Google Chrome Canary", "google chrome"),
        ("Visual Studio Code - Insiders", "visual studio code"),
        ("Safari", "safari"),
        ("Xcode 26", "xcode"),
        // The names that *are* variant words. Stripping these to nothing put every one
        // of them in a single ambiguous group — caught by running the scan against a
        // real disk, where "Developer" and "Preview" are both installed.
        ("Preview", "preview"),
        ("Developer", "developer"),
    ])
    func plainNameStripsVariants(name: String, expected: String) {
        #expect(AppCatalogue.plainName(name) == expected)
    }

    /// The failure the case above prevents, stated as the behaviour rather than the
    /// helper: two unrelated apps whose whole name is a variant word are not each
    /// other's ambiguity.
    @Test("An app whose entire name is a variant word stands on its own")
    func namesThatAreVariantWordsAreNotCollapsed() {
        let catalogue = AppCatalogue.build(
            installed: [
                found("com.apple.Preview", "Preview"),
                found("com.apple.Developer", "Developer"),
            ],
            running: []
        )
        #expect(catalogue.entries.allSatisfy { !$0.isAmbiguous },
                "two apps collapsed together because both names stripped to nothing")
    }

    // MARK: - Truncation

    /// A `Choice` always returns one of the options it was given, so a classifier shown
    /// a truncated list names the closest thing it *was* shown. That is how "open
    /// Fantastical" launches Calendar. The flag is what lets the fast path refuse.
    @Test("A list too long to send says so")
    func truncationIsReported() {
        let many = (0..<250).map { found("com.example.app\($0)", "App \($0)") }
        let catalogue = AppCatalogue.build(installed: many, running: [], limit: 200)
        #expect(catalogue.truncated, "apps were dropped and nothing said so")
        #expect(catalogue.entries.count == 200)
    }

    /// Running apps are never the ones cut. They are few, and they are what somebody
    /// looking at their screen is most likely to mean.
    @Test("Truncation cuts the apps nobody is looking at")
    func truncationKeepsRunningApps() {
        let many = (0..<250).map { found("com.example.app\($0)", "App \($0)") }
        let catalogue = AppCatalogue.build(
            installed: many + [found("com.apple.Safari", "Safari")],
            running: [running("com.apple.Safari", "Safari")],
            limit: 200
        )
        #expect(catalogue.entry(bundleIdentifier: "com.apple.Safari") != nil,
                "the app that was on screen was cut to make room for ones that were not")
    }

    @Test("A list that fits says it was not cut")
    func untruncatedSaysSo() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Safari", "Safari")], running: [], limit: 200
        )
        #expect(!catalogue.truncated)
    }

    /// An unstable order would rewrite the request on every utterance for no reason, and
    /// a test could not read it.
    @Test("The same machine produces the same list twice")
    func orderIsStable() {
        let installed = [
            found("com.apple.Safari", "Safari"),
            found("com.apple.Notes", "Notes", isSystem: true),
            found("com.example.Zed", "Zed"),
        ]
        let first = AppCatalogue.build(installed: installed, running: [])
        let second = AppCatalogue.build(installed: installed.reversed(), running: [])
        #expect(first.entries.map(\.bundleIdentifier) == second.entries.map(\.bundleIdentifier))
    }

    @Test("A user's own apps sort ahead of the ones macOS shipped")
    func userAppsOutrankSystemApps() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Notes", "Notes", isSystem: true), found("com.example.Zed", "Zed")],
            running: []
        )
        #expect(catalogue.entries.first?.bundleIdentifier == "com.example.Zed")
    }

    // MARK: - How an option is described

    @Test("The running state travels with the name, so a tie can be broken by it")
    func criterionCarriesRunningState() {
        let catalogue = AppCatalogue.build(
            installed: [found("com.apple.Safari", "Safari")],
            running: [running("com.apple.Safari", "Safari")]
        )
        #expect(catalogue.entries[0].criterion.contains("Safari"))
        #expect(catalogue.entries[0].criterion.contains("running"))
    }

    @Test("An ambiguous option says it is ambiguous rather than picking a side")
    func ambiguousCriterionSaysSo() {
        let catalogue = AppCatalogue.build(
            installed: [
                found("com.google.Chrome", "Google Chrome"),
                found("com.google.Chrome.canary", "Google Chrome Canary"),
            ],
            running: []
        )
        #expect(catalogue.entries[0].criterion.contains("several versions"))
    }

    // MARK: - Reading a bundle off the disk

    /// The rules that cannot be checked without a filesystem, checked against a fixture
    /// tree rather than against whatever happens to be installed on the machine running
    /// the suite.
    @Test("A bundle is read, and the ones that cannot be focused are skipped")
    func readingBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeApp(_ name: String, info: [String: Any]) throws -> URL {
            let url = root.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }

        let ordinary = try makeApp("Ordinary", info: [
            "CFBundleIdentifier": "com.example.Ordinary", "CFBundleName": "Ordinary",
        ])
        let named = try makeApp("Named", info: [
            "CFBundleIdentifier": "com.example.Named",
            "CFBundleName": "Internal", "CFBundleDisplayName": "What People Call It",
        ])
        let agent = try makeApp("Agent", info: [
            "CFBundleIdentifier": "com.example.Agent", "LSUIElement": true,
        ])
        let anonymous = try makeApp("Anonymous", info: ["CFBundleName": "Anonymous"])

        #expect(AppCatalogue.read(bundleAt: ordinary, isSystem: false)?.name == "Ordinary")
        #expect(AppCatalogue.read(bundleAt: named, isSystem: false)?.name == "What People Call It",
                "the internal name was shown to the user instead of the one on the icon")
        #expect(AppCatalogue.read(bundleAt: agent, isSystem: false) == nil,
                "a menu-bar agent was offered as somewhere to switch to")
        #expect(AppCatalogue.read(bundleAt: anonymous, isSystem: false) == nil,
                "a bundle with no identifier was offered, and cannot be launched by one")

        // Every `.app` contains more `.app`s. A scan that descended would bury the
        // fourteen apps somebody uses under four hundred helpers.
        let helper = try makeApp("Ordinary.app/Contents/Frameworks/Helper", info: [
            "CFBundleIdentifier": "com.example.Ordinary.helper", "CFBundleName": "Helper",
        ])
        #expect(FileManager.default.fileExists(atPath: helper.path))
        let scanned = AppCatalogue.scan(roots: [root])
        #expect(scanned.contains { $0.bundleIdentifier == "com.example.Ordinary" })
        #expect(!scanned.contains { $0.bundleIdentifier == "com.example.Ordinary.helper" },
                "the scan went inside an application bundle")
    }

    @Test("A system app is ranked as one")
    func systemRootsAreMarked() {
        #expect(AppCatalogue.roots.contains { $0.path == "/System/Applications" })
        #expect(AppCatalogue.roots.first?.path == "/Applications",
                "the user's own apps must be found before the system's, so they win a tie")
    }
}
