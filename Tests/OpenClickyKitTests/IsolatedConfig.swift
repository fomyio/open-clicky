import Foundation
@testable import OpenClickyKit

/// A config file that does not exist, for tests that must never read the real one.
///
/// `Provider.resolve` used to default this to `ConfigFile()`, which reads
/// `~/.openclicky/config.json` — so every test that did not override it loaded the
/// developer's own API keys, and printed them in full when it failed. The default is
/// gone and the parameter is required, which is why this exists: the compiler now
/// asks each caller which file it means, and a test says "none".
func isolatedConfig() -> ConfigFile {
    ConfigFile(url: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("openclicky-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("config.json"))
}
