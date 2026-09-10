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

    /// Where sessions are written when the caller names no directory. One definition,
    /// so a reader of the record and a writer of it cannot disagree about the path.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclicky/sessions", isDirectory: true)
    }

    public init(sessionID: String = UUID().uuidString, directory: URL? = nil) throws {
        let base = directory ?? Self.defaultDirectory
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
        // Sorted, so `kind` lands in a predictable place. Swift seeds its dictionary
        // ordering per process, so without this an entry's keys came out in a
        // different order on every line: the reader's tail search, which inspects a
        // short prefix to find `"usage"` without decoding 240KB images, found it in
        // some runs and not others. That made a listing report 0, 1 or 2 turns for the
        // same file — a flaky answer, which is worse than a wrong one because it looks
        // like a passing test most of the time.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
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

    /// What the stored sessions occupy.
    ///
    /// A run that takes screenshots writes them to the record in full, so a busy
    /// session is measured in megabytes and nothing prunes the directory. That is a
    /// defensible trade — the record is meant to reconstruct what happened — but it
    /// was invisible, and a tool that grows on someone's disk indefinitely should at
    /// least say so when asked.
    public struct Storage: Sendable, Equatable {
        public let sessions: Int
        public let bytes: Int
        public let directory: URL
        public let oldest: Date?

        /// Rendered for a human, e.g. "18 sessions, 143.2 MB".
        public var summary: String {
            // Non-numeric formatting is off: ByteCountFormatter's default renders an
            // empty record as "Zero KB", which reads like a bug rather than a number.
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowsNonnumericFormatting = false
            let size = formatter.string(fromByteCount: Int64(bytes))
            return "\(sessions) session\(sessions == 1 ? "" : "s"), \(size)"
        }
    }

    public static func storage(in directory: URL? = nil) -> Storage {
        let base = directory ?? defaultDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let sessions = files.filter { $0.pathExtension == "jsonl" }
        let values = sessions.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        }
        return Storage(
            sessions: sessions.count,
            bytes: values.reduce(0) { $0 + ($1.fileSize ?? 0) },
            directory: base,
            oldest: values.compactMap(\.contentModificationDate).min()
        )
    }


    /// The conversation as it currently stands in memory — **not** the unpruned record.
    ///
    /// It was the unpruned record until `compacted(policy:)` existed. That method keeps
    /// what it prunes, deliberately, so that history stops moving behind the prompt
    /// cache — which means that after a run's first turn this holds the compacted form:
    /// stale screenshots replaced by `elidedImageNote`, old results abbreviated. A
    /// later read under `.unpruned` cannot bring them back, and `compactionStillPrunes\
    /// AndIsMonotonic` asserts exactly that.
    ///
    /// **The unpruned record is the JSONL file**, which `append` writes before any
    /// pruning happens and which nothing here ever rewrites. Anything that needs the
    /// true history — an export, an audit view, a debugging surface — has to read that,
    /// not this. Said here rather than left to be discovered because the property used
    /// to promise the opposite, and a caller that trusted the old wording would ship
    /// redacted data believing it complete.
    ///
    /// Use `compacted(policy:)` for anything sent to the API.
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

    /// The conversation as it should be sent to the API under `policy`, *and* the
    /// record updated to match.
    ///
    /// The compaction is kept rather than recomputed, and that is the whole point.
    /// `conversation(policy:)` measures its windows backwards from the newest message,
    /// so an observation that was intact on turn five is abbreviated on turn eight —
    /// which rewrites bytes the model has already been sent. That was harmless while
    /// nothing in `messages` carried a cache breakpoint, and it is fatal the moment
    /// something does: prompt caching matches on a *prefix*, so a block edited behind
    /// the breakpoint invalidates it and every turn re-bills the whole history at full
    /// price. The failure is silent — the request is still correct, it is only the bill
    /// that changes — and `CostMeter.cacheHitRate` is the only thing that would ever
    /// say so.
    ///
    /// Keeping it is also simply what the pruning already meant. The windows only ever
    /// slide forward, so a block this drops can never come back; recomputing it from
    /// the original each turn spent work to arrive at the same answer, plus a
    /// different byte stream on the way there.
    ///
    /// The unpruned record is the file on disk, which is append-only and untouched by
    /// this. `conversation` and `conversation(policy:)` stay pure for the callers that
    /// want to ask what a policy *would* do without doing it.
    public func compacted(policy: ContextPolicy) -> Compacted {
        messages = conversation(policy: policy)
        return Compacted(
            messages: messages,
            settledThrough: Self.settledThrough(messages, policy: policy)
        )
    }

    /// A compacted conversation, and how much of it has stopped moving.
    public struct Compacted: Sendable {
        public let messages: [Wire.Message]
        /// Leading messages the policy can never rewrite again — the only region a
        /// cache breakpoint can sit at the end of and still hit next turn.
        public let settledThrough: Int

        public init(messages: [Wire.Message], settledThrough: Int) {
            self.messages = messages
            self.settledThrough = settledThrough
        }
    }

    /// How many leading messages the policy has finished with.
    ///
    /// This is the number the prompt cache turns on, and the reason retroactive
    /// pruning and prefix caching can coexist at all. Both windows are measured
    /// backwards in `tool_result` blocks, so a message stops being reachable once
    /// enough results have accumulated after it — and because history only grows, a
    /// message that is past the windows is past them forever. Everything before that
    /// point is final; everything after it is still liable to be rewritten on any
    /// turn, which is precisely what a cached prefix must not contain.
    ///
    /// `max` rather than the sum of the two windows: each is independently a claim of
    /// the form "at least *K* results have to follow before this one is touched", and
    /// the later of the two frontiers is the one that governs. Images live inside
    /// results, so counting results bounds the image window too.
    ///
    /// A policy that prunes nothing settles everything immediately — there is no
    /// mechanism left that could rewrite a message, so the whole history is cacheable.
    /// Without that case, `.unpruned` would fall through the loop below to zero and
    /// silently turn caching off for the runs least able to afford it.
    static func settledThrough(_ messages: [Wire.Message], policy: ContextPolicy) -> Int {
        guard policy != .unpruned else { return messages.count }
        let window = max(policy.keepRecentFullResults, policy.keepRecentImages)

        var resultsAfter = 0
        for index in messages.indices.reversed() {
            if resultsAfter >= window { return index + 1 }
            resultsAfter += messages[index].content.reduce(0) {
                if case .toolResult = $1 { return $0 + 1 }
                return $0
            }
        }
        return 0
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
    /// The marker an abbreviated result carries, and the thing that makes
    /// abbreviating idempotent.
    ///
    /// Without the check below this is not a fixed point. The replacement is longer
    /// than the marker itself, so a budget smaller than the marker leaves the result
    /// still over budget — and abbreviating it again takes another head and tail *of
    /// the abbreviation*, producing a different, shorter string every turn. Text was
    /// therefore still being rewritten several turns after it had aged out, which is
    /// data loss on its own and, since `compacted` keeps what it prunes, would mean
    /// the history behind every cache breakpoint never settled.
    static let elisionMarker = "characters from an earlier turn elided"

    static func abbreviate(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        // Already abbreviated, or already an elided screenshot: both are as short as
        // this is going to make them, and both are recognisable. Left alone.
        guard !text.contains(elisionMarker), text != elidedImageNote else { return text }
        let half = max(budget / 2, 1)
        let head = text.prefix(half)
        let tail = text.suffix(half)
        let removed = text.count - (half * 2)
        return """
            \(head)

            […\(removed) \(Self.elisionMarker). Re-run the tool if you need this in full.]

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
    /// Records a backoff the client made inside a single `send`.
    ///
    /// Lives here, and is called from where the client is constructed, because the
    /// loop never sees a retry: the client is built outside it and reports its
    /// backoffs straight to the observer, which draws to a terminal and is gone. That
    /// left `bench` unable to tell a slow response from a fast one behind a
    /// `Retry-After` — the recorded 62-second turn is still unexplained for exactly
    /// this reason, and every report has had to carry a caveat saying so.
    ///
    /// A method rather than a `note(kind:)` call at each site, so the two wirings —
    /// the CLI and the menu-bar app — cannot record the same event under different
    /// keys and leave a reader matching on one of them.
    public func noteRetry(attempt: Int, of total: Int, delay: Double, reason: String) {
        note(kind: "retry", [
            "attempt": .number(Double(attempt)),
            "of": .number(Double(total)),
            "delay_seconds": .number(delay),
            "reason": .string(reason.truncated(200)),
        ])
    }

    /// Records how long a turn waited before its first token.
    ///
    /// Beside `noteRetry` and for the same reason: the loop cannot see it. The client
    /// reports fragments straight to a closure, and only the place that builds the
    /// client can put one in the record.
    public func noteFirstToken(seconds: Double) {
        note(kind: "first_token", ["seconds": .number(seconds)])
    }

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
