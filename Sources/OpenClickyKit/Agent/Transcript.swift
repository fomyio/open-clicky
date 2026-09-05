import Foundation

/// Append-only JSONL record of a session.
///
/// One JSON object per line so a session can be tailed live, replayed, and resumed
/// without holding it all in memory. Append-only matters beyond convenience: newer
/// Claude models bind thinking blocks to the history that produced them, so rewriting
/// earlier turns invalidates them.
public actor Transcript {
    public struct Entry: Codable, Sendable {
        /// Position in the record. Monotonic, gapless, and the only reliable ordering.
        ///
        /// Timestamps cannot do this job: several entries a turn are written within
        /// the same millisecond, which is the finest resolution ISO8601 offers, so
        /// four consecutive writes shared one stamp. The timestamp says when; this
        /// says in what order, and the two are not the same question.
        public let sequence: Int
        public let timestamp: Date
        public let kind: String
        public let payload: JSONValue
    }

    private let url: URL
    private var messages: [Wire.Message] = []
    private let encoder: JSONEncoder
    private var nextSequence = 0

    /// Held open for the session rather than reopened per entry.
    ///
    /// A transcript records several entries per turn, and open + seek + write + close
    /// for each of them is four syscalls where one will do. The handle is closed on
    /// deinit; a crash still leaves every line already written on disk, because each
    /// is flushed as it is appended.
    private var handle: FileHandle?

    public init(sessionID: String = UUID().uuidString, directory: URL? = nil) throws {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".openclicky/sessions", isDirectory: true)
        // Explicit permissions rather than whatever the caller's umask happens to be.
        // A transcript holds command output, file contents and base64 screenshots in
        // full — the on-disk record is never pruned — and the default 022 umask would
        // make it 0644, readable by every other local account (all of which are in
        // `staff`, which can traverse a default home directory).
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.url = base.appendingPathComponent("\(sessionID).jsonl")

        let encoder = JSONEncoder()
        // Fractional seconds, because the whole point of this file is reconstructing
        // what happened. At second resolution every entry in a turn carries the same
        // timestamp, so the record cannot order two events or time anything — and a
        // turn is where the interesting sequence lives.
        // A format style rather than ISO8601DateFormatter: the latter is a class, and
        // is not Sendable, so capturing one in this @Sendable closure is a data race
        // the compiler is right to warn about.
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format.format(date))
        }
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        // Tighten the directory even if it already existed from an earlier version.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)

        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public var path: String { url.path }

    /// The full conversation, images included.
    ///
    /// Use `conversation(keepingRecentImages:)` for anything sent to the API —
    /// this is the unpruned record.
    public var conversation: [Wire.Message] { messages }

    /// How much of the conversation's history is sent back on each turn.
    ///
    /// Everything the agent has ever observed is resent every turn, so the cost of a
    /// session grows with the square of its length unless old observations are
    /// trimmed. They are also the least useful part of the context: a screenshot or
    /// an accessibility dump from eight turns ago describes a screen that no longer
    /// exists, and the model can reason from it by mistake.
    ///
    /// What is never trimmed: the model's own turns, the user's instructions, and the
    /// existence of every `tool_result` block — only the bulk *inside* a stale result
    /// is replaced, so no `tool_use` is ever orphaned.
    public struct ContextPolicy: Sendable, Equatable {
        /// Screenshots kept intact, newest first. Two allows a before/after comparison.
        public var keepRecentImages: Int
        /// Tool results kept at full length, newest first.
        public var keepRecentFullResults: Int
        /// Characters retained from an older result. Kept as head and tail, since the
        /// start of a result carries its header and the end carries its conclusion.
        public var staleResultBudget: Int

        public init(
            keepRecentImages: Int = 2,
            keepRecentFullResults: Int = 6,
            staleResultBudget: Int = 400
        ) {
            self.keepRecentImages = keepRecentImages
            self.keepRecentFullResults = keepRecentFullResults
            self.staleResultBudget = staleResultBudget
        }

        public static let `default` = ContextPolicy()

        /// Sends the history untouched. For debugging what the model actually saw.
        public static let unpruned = ContextPolicy(
            keepRecentImages: .max, keepRecentFullResults: .max, staleResultBudget: .max
        )
    }

    /// The conversation as it should be sent to the API under `policy`.
    public func conversation(policy: ContextPolicy) -> [Wire.Message] {
        var imagesRemaining = policy.keepRecentImages
        var fullResultsRemaining = policy.keepRecentFullResults
        var pruned = messages

        // Reverse order: recency is what decides whether an observation is still
        // worth its tokens.
        for messageIndex in pruned.indices.reversed() {
            var content = pruned[messageIndex].content
            var changed = false

            for blockIndex in content.indices.reversed() {
                guard case let .toolResult(toolUseID, blocks, isError) = content[blockIndex] else {
                    continue
                }

                let isRecentEnoughToKeepWhole = fullResultsRemaining > 0
                if fullResultsRemaining > 0 { fullResultsRemaining -= 1 }

                var rewritten: [Wire.ToolResultContent] = []
                var blockChanged = false

                for block in blocks {
                    switch block {
                    case .image:
                        if imagesRemaining > 0 {
                            imagesRemaining -= 1
                            rewritten.append(block)
                        } else {
                            rewritten.append(.text(Self.elidedImageNote))
                            blockChanged = true
                        }
                    case let .text(text):
                        // An error is usually short and always worth keeping — it is
                        // what the model needs in order to correct itself.
                        if isRecentEnoughToKeepWhole || isError
                            || text.count <= policy.staleResultBudget {
                            rewritten.append(block)
                        } else {
                            rewritten.append(.text(Self.abbreviate(text, to: policy.staleResultBudget)))
                            blockChanged = true
                        }
                    }
                }

                if blockChanged {
                    content[blockIndex] = .toolResult(
                        toolUseID: toolUseID, content: rewritten, isError: isError
                    )
                    changed = true
                }
            }

            if changed {
                pruned[messageIndex] = Wire.Message(
                    role: pruned[messageIndex].role, content: content
                )
            }
        }
        return pruned
    }

    /// Shortens a stale result to its head and tail.
    ///
    /// Both ends matter: a command's output opens with what it is reporting on and
    /// closes with its conclusion, and a head-only cut loses the latter.
    static func abbreviate(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        let half = max(budget / 2, 1)
        let head = text.prefix(half)
        let tail = text.suffix(half)
        let removed = text.count - (half * 2)
        return """
            \(head)

            […\(removed) characters from an earlier turn elided. Re-run the tool if you need this in full.]

            \(tail)
            """
    }

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
        conversation(policy: ContextPolicy(
            keepRecentImages: limit,
            keepRecentFullResults: .max,
            staleResultBudget: .max
        ))
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
        let entry = Entry(
            sequence: nextSequence, timestamp: Date(), kind: kind, payload: payload
        )
        nextSequence += 1
        guard let data = try? encoder.encode(entry), let handle else { return }
        // A failed write must not take the run down — the transcript is a record, not
        // a dependency of the work.
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
    }

    deinit {
        try? handle?.close()
    }

    private func encodeToJSON<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? encoder.encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }
}
