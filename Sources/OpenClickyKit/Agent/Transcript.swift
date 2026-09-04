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

    /// The conversation as the API expects it.
    public var conversation: [Wire.Message] { messages }

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
