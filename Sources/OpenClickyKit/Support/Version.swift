import Foundation

/// The build's identity.
///
/// One definition. The version lived only in `Scripts/bundle.sh`, written straight
/// into the app's Info.plist, so the CLI had no way to report which build it was and
/// nothing could disagree with the app because nothing else knew. A bug report that
/// cannot name a build is a bug report about an unknown program.
public enum OpenClicky {
    public static let version = "0.1.0"

    /// What `--version` prints, and what a bug report should carry.
    public static var versionLine: String {
        "openclicky \(version) (\(architecture), macOS \(systemVersion))"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
