import Foundation

/// Tier 0 — read a file's contents.
///
/// Separate from `shell` so reads are unambiguously classified read-only and can
/// skip the permission prompt, and so the credential deny-list applies by path.
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let tier = Tier.shell
    public let description = """
    Read a text file from disk. Use this instead of `shell` with `cat` when you \
    simply need a file's contents — it never prompts for approval.
    """

    public var inputSchema: JSONValue {
        .schema([
            "path": .string(describing: "Absolute path, or one starting with ~."),
            "max_bytes": .integer(describing: "Stop after this many bytes. Default 100000."),
        ], required: ["path"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let path = try input.string("path")
        try Policy.validateRead(path: path)

        // Resolve before opening, so the path the deny-list checked is the path that
        // is actually read. Without this a symlink slips between the two.
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
        let limit = min(max(input.int("max_bytes", default: 100_000), 1), 1_000_000)

        guard let handle = FileHandle(forReadingAtPath: expanded) else {
            return .failure("No readable file at '\(path)'.")
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: limit)
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("'\(path)' is not UTF-8 text (\(data.count) bytes read). Use `shell` with a binary-aware tool.")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: expanded)[.size] as? Int) ?? nil
        if let size, size > limit {
            return .text(text + "\n… [truncated at \(limit) of \(size) bytes]")
        }
        return .text(text)
    }
}

/// Tier 0 — write a file.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let tier = Tier.shell
    public let description = """
    Write text to a file, creating it or replacing its contents entirely. \
    Parent directories are created as needed.
    """

    public var inputSchema: JSONValue {
        .schema([
            "path": .string(describing: "Absolute path, or one starting with ~."),
            "content": .string(describing: "The complete file contents to write."),
        ], required: ["path", "content"])
    }

    public init() {}

    public func risk(for input: JSONValue) -> Risk {
        guard let path = input["path"]?.stringValue else {
            return .write(summary: "write with missing arguments")
        }
        let bytes = input["content"]?.stringValue?.utf8.count ?? 0

        // Persistence and security-posture paths are destructive whether or not the
        // file already exists — dropping a new launch agent is the attack, and
        // "it is a new file" is exactly the case a create-vs-overwrite test misses.
        if let sensitive = Policy.isSensitiveWrite(path: path) {
            return .dangerous(summary: "write to \(path), under \(sensitive) — this can persist code or change security settings")
        }

        let exists = FileManager.default.fileExists(
            atPath: (path as NSString).expandingTildeInPath
        )
        return exists
            ? .dangerous(summary: "overwrite \(path) with \(bytes) bytes (existing contents are lost)")
            : .write(summary: "create \(path) (\(bytes) bytes)")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let path = try input.string("path")
        let content = try input.string("content")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url, options: .atomic)
        return .text("Wrote \(content.utf8.count) bytes to \(url.path).")
    }
}
