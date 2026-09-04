import Foundation

/// Append-only JSONL record of a session.
///
/// One JSON object per line so a session can be tailed live, replayed, and resumed
/// without holding it all in memory. Append-only matters beyond convenience: newer
/// Claude models bind thinking blocks to the history that produced them, so rewriting
/// earlier turns invalidates them.
public actor Transcript {
    public struct Entry: Codable, Sendable {
        public let timestamp: Date
        public let kind: String
        public let payload: JSONValue
    }

    private let url: URL
    private var messages: [Wire.Message] = []
    private let encoder: JSONEncoder

    public init(sessionID: String = UUID().uuidString, directory: URL? = nil) throws {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".openclicky/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("\(sessionID).jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public var path: String { url.path }

    /// The full conversation, images included.
    ///
    /// Use `conversation(keepingRecentImages:)` for anything sent to the API —
    /// this is the unpruned record.
    public var conversation: [Wire.Message] { messages }

    /// The conversation with all but the most recent screenshots elided.
    ///
    /// Screenshots cost ~1,500 vision tokens each and the whole conversation is
    /// resent every turn, so an unpruned computer-use session pays for every
    /// screenshot it has ever taken, on every subsequent turn — cost and latency
    /// grow quadratically in the number of captures.
    ///
    /// Stale screenshots are also actively harmful: they show a screen that no
    /// longer exists, and the model can reason from one by mistake. Eliding them
    /// leaves a note telling it to look again, which is the behaviour we want.
    ///
    /// The `tool_result` block itself is always kept — dropping it would orphan
    /// its `tool_use` and make the request invalid. Only the image inside it is
    /// swapped for text.
    public func conversation(keepingRecentImages limit: Int) -> [Wire.Message] {
        guard limit >= 0 else { return messages }

        var remaining = limit
        var pruned = messages

        // Reverse order: the newest images are the ones worth keeping.
        for messageIndex in pruned.indices.reversed() {
            var content = pruned[messageIndex].content
            var changed = false

            for blockIndex in content.indices.reversed() {
                guard case let .toolResult(toolUseID, blocks, isError) = content[blockIndex],
                      blocks.contains(where: \.isImage) else { continue }

                if remaining > 0 {
                    remaining -= 1
                    continue
                }

                content[blockIndex] = .toolResult(
                    toolUseID: toolUseID,
                    content: blocks.map { $0.isImage ? .text(Self.elidedImageNote) : $0 },
                    isError: isError
                )
                changed = true
            }

            if changed {
                pruned[messageIndex] = Wire.Message(
                    role: pruned[messageIndex].role, content: content
                )
            }
        }
        return pruned
    }

    static let elidedImageNote = """
        [Earlier screenshot removed to save context. It showed a screen that has \
        since changed — take a new screenshot if you need to see the current state.]
        """

    public func append(_ message: Wire.Message) {
        messages.append(message)
        record(kind: message.role.rawValue, payload: encodeToJSON(message))
    }

    /// Notes something that is not part of the conversation — usage, denials, errors.
    public func note(kind: String, _ fields: [String: JSONValue]) {
        record(kind: kind, payload: .object(fields))
    }

    private func record(kind: String, payload: JSONValue) {
        let entry = Entry(timestamp: Date(), kind: kind, payload: payload)
        guard let data = try? encoder.encode(entry) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private func encodeToJSON<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? encoder.encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }
}
