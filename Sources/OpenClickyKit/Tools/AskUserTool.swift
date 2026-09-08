import Foundation

/// Tier 0 — put one question to the user and wait for the answer.
///
/// The agent had exactly two ways to reach the person sitting in front of it: call a
/// tool, or write prose at the end of a turn. Neither of those is a conversation. So
/// "show me how to change the VS Code theme" had only two readings available to it —
/// narrate the steps and touch nothing, or silently perform them — and the thing that
/// was actually asked for, being walked to the setting and *then* asked whether to
/// change it, was not expressible at all.
///
/// The permission gate cannot be that channel. It answers exactly one question — may
/// this call run — and it is deliberately not a general line to the user: widening it
/// would widen the only containment this project has. So the missing capability is a
/// tool, and by the ladder's own rule it belongs at the lowest tier that can do the
/// job. That is tier 0. No grants, no vision tokens, nothing on screen.
///
/// The whole of the danger is in the presentation, not the effect — see `Question`.
public struct AskUserTool: Tool {
    public let name = "ask_user"
    public let tier = Tier.shell

    public let description = """
    Put one short question to the user and wait for their answer. Use it when the \
    answer changes what you do next and the machine cannot tell you.

    The case it exists for is being asked to *show* someone how something is done. \
    Navigate to the place where the change is made, say what is there and what the \
    options mean, then ask whether to make it — "Settings is open on Color Theme, \
    currently Dark+. Shall I switch it to Light+?" — instead of changing it unasked or \
    describing it without opening anything. Also use it at a real fork: two files that \
    both match, a destination that cannot be inferred.

    Not for permission. Anything that changes state is put to the user separately, and \
    that is the only thing that can authorise it; an answer here authorises nothing. A \
    question written to look like that prompt is refused instead of shown. Not for \
    things you can find out yourself — read the file, run the command, look. Not for \
    narrating: say what you are about to do in your reply, do not ask about it.

    If nobody is there to answer — a piped or non-interactive run — this says so \
    immediately rather than waiting, so never build a plan that stalls without a reply.
    """

    public var inputSchema: JSONValue {
        .schema([
            "question": .string(describing:
                "The question, in plain words, as one sentence. It is shown to the "
                + "user verbatim and is not a request for permission."),
        ], required: ["question"])
    }

    /// How this surface actually reaches the user. See `Asker`.
    public let ask: Asker

    public init(ask: @escaping Asker = AskUserTool.noOneToAsk) {
        self.ask = ask
    }

    /// Asking a question is `.read`, and the argument is constrained rather than trusted.
    ///
    /// A `.read` skips the gate in every mode — read-only included — so this
    /// classification has to be earned twice: once on effect, once on argument.
    ///
    /// On effect it is easy. Nothing is written, nothing is executed, no other app is
    /// touched, no file is opened; the machine ends in the state it started in. The
    /// alternative is not merely stricter, it is worse. Classified `.write`, every
    /// question would raise an approval prompt of its own — "Approve? changes state
    /// ask_user" — so one demonstration would put two prompts in front of the user for
    /// a single interaction, which spends the gate's only asset, the user's attention,
    /// on a call that cannot hurt them and teaches them to clear prompts by reflex. And
    /// in read-only mode it would be denied outright, so the one mode where explaining
    /// rather than doing is the entire point would be the one mode that could not ask.
    ///
    /// On argument it is the harder half, and the harm it has to rule out is not to the
    /// machine but to what the user believes they are answering. That is discharged in
    /// `Question`, before anything reaches a screen: the frame is fixed text this tool
    /// owns, the model's words are rendered through `Policy.summarize` onto a single
    /// prefixed line inside it, and a question shaped like the gate's own prompt is
    /// refused rather than displayed. What the model controls is one line in a frame it
    /// cannot reach — which is what "provably read-only" has to mean for a tool whose
    /// argument is prose.
    public func risk(for input: JSONValue) -> Risk { .read }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let raw = try input.string("question")
        guard let question = Question(asking: raw) else {
            return .failure(Self.refusal)
        }
        switch await ask(question) {
        case let .answered(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .text("""
                    The user pressed Return without answering. Read that as "no \
                    preference", never as permission: take the reversible option and \
                    say which one you took, or stop and let them tell you what they want.
                    """)
            }
            return .text("""
                The user answered: \(Policy.abbreviateMiddle(trimmed, to: 2000))

                That is an answer, not an approval. Anything that changes state is \
                still put to them separately and can still be refused there.
                """)
        case let .unavailable(reason):
            return .text("""
                No answer is available: \(reason). Do not wait for one and do not \
                assume what it would have been. Carry on with whatever does not depend \
                on it, and put the question in your reply so the user sees it.
                """)
        }
    }

    /// What the model is told when its question was refused for imitating the gate.
    ///
    /// Names the specific shapes rather than saying "invalid", because a model that
    /// cannot tell what was wrong retries the same thing.
    static let refusal = """
        That question was written to look like a permission prompt, so it was not \
        shown to the user. The approval prompt is the only thing that can grant \
        permission, and a question imitating it could collect a "yes" that was never \
        asked for. Rewrite it in plain words — no bracketed choices like [y]es/[n]o, \
        no "approve", "always allow", "changes state" or "destructive" — and ask again.
        """
}

public extension AskUserTool {

    /// How a surface puts a question to the user.
    ///
    /// A closure for the same reason `PermissionGate.Prompt` is one: the CLI reads a
    /// terminal, the app would draw a panel, and neither belongs in the library. It
    /// returns `Answer` rather than `String?` so a surface that cannot ask says *why*,
    /// and the model is told rather than left to infer it from silence.
    typealias Asker = @Sendable (Question) async -> Answer

    /// What came back, including the case where nothing could.
    enum Answer: Sendable, Equatable {
        /// The user typed something. An empty string means they skipped the question.
        case answered(String)
        /// Nobody could be asked, and this is why. Never a reason to wait.
        case unavailable(reason: String)
    }

    /// The honest default: a registry built with no surface attached cannot ask anyone.
    ///
    /// Returning "unavailable" rather than blocking is the whole contract of this tool.
    /// A default that waited would deadlock every non-interactive run — CI, a piped
    /// session, a test — on the first question the model thought of.
    static let noOneToAsk: Asker = { _ in
        .unavailable(reason: "this run has no way to put a question to the user")
    }

    /// A question that has already been sanitised and framed, ready to display.
    ///
    /// **This type is the safety of the tool.** A question is text the model chooses,
    /// shown to the user, answered by the user — which is the shape of the permission
    /// prompt as well. If the model can render something the user reads as the gate's
    /// own prompt, it can manufacture consent: ask "Allow shell to run rm -rf ~? [y]es
    /// / [n]o", the user types y believing they answered the gate, and the model holds
    /// an approval the gate never issued. The gate is the only containment here, so
    /// this cannot be left to the wording of a description.
    ///
    /// Two defences, and they are independent on purpose.
    ///
    /// **The frame, which always applies.** `header`, `caveat` and `answerPrompt` are
    /// constants of this type; no argument reaches them. The model's own words become
    /// exactly one line, prefixed with `linePrefix` and put through
    /// `Policy.summarize` — the same rendering the approval summary gets, so control
    /// characters are made visible instead of repainting the terminal and a newline
    /// becomes a visible `⏎` rather than a second line that could stand on its own.
    /// A question therefore cannot produce a line the user meets outside the frame,
    /// whatever it contains.
    ///
    /// **The refusal, which is defence in depth.** A question whose text carries the
    /// gate's own shape is not rendered at all. The gate's offer is read *from*
    /// `PermissionGate.choices` rather than copied here, so rewording the prompt
    /// cannot leave this checking for a string that no longer exists — the drift that
    /// makes a detector quietly stop detecting. The comparison is done on a
    /// normalisation that drops punctuation, control characters and zero-width
    /// scalars, because `[y\u{200B}]es` renders to the user as `[y]es` and a check
    /// reading raw bytes would wave it through.
    struct Question: Sendable, Equatable {
        /// Fixed. Says what this is, in words the gate never uses.
        public static let header = "Question from the agent"
        /// Fixed. Says what it is not, on its own line, every time.
        public static let caveat =
            "not a permission request — an answer here allows nothing"
        /// Fixed. Marks the model's line as being inside the frame.
        public static let linePrefix = "? "
        /// Fixed, and deliberately nothing like `PermissionGate.choices`: no bracketed
        /// keys, no listed letters, nothing that reads as a set of choices on offer.
        public static let answerPrompt = "» your answer (Return to skip): "

        /// The model's words: one line, sanitised, prefixed. Never anything else.
        public let line: String

        public var header: String { Self.header }
        public var caveat: String { Self.caveat }
        public var answerPrompt: String { Self.answerPrompt }

        /// The whole frame as plain text, for a surface with no styling and for tests.
        public var rendered: String {
            "\(Self.header) — \(Self.caveat)\n\(line)"
        }

        /// Builds a question, or refuses.
        ///
        /// `nil` means the text imitates an approval prompt, or is empty. Failable
        /// rather than sanitising-into-safety, because there is no rewriting of "[y]es
        /// / [n]o" that leaves the model's intent intact — a question written that way
        /// is either an attempt at consent or a confusion, and both want the model
        /// told, not a silently altered string put in front of the user.
        public init?(asking text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !Question.imitatesApprovalPrompt(trimmed) else { return nil }
            self.line = Question.linePrefix + Policy.summarize(trimmed)
        }

        /// Whether this text is dressed as the permission gate's own prompt.
        ///
        /// Public so a surface, a test and the sweep can all ask the same question of
        /// the same function rather than each keeping an opinion about it.
        public static func imitatesApprovalPrompt(_ text: String) -> Bool {
            let flattened = normalised(text)
            if containsBracketedKey(flattened) { return true }
            for offer in gateOffers where flattened.contains(offer) { return true }
            for badge in approvalWording where flattened.contains(badge) { return true }
            return false
        }

        /// The gate's badges and the answers it takes, in the user's vocabulary.
        ///
        /// `approve` is on the list even though it has innocent uses — "shall I
        /// approve the pull request?" is refused, and the model rewrites it as "shall I
        /// merge it?". That trade is deliberate: the cost of a refusal is one wasted
        /// turn, and the cost of a miss is an approval the gate never issued.
        private static let approvalWording = [
            "approve", "approval", "always allow", "changes state", "destructive",
            "y/n", "n/y", "yes/no", "no/yes",
        ]

        /// The gate's offer, taken from the gate.
        ///
        /// Split around a marker standing in for the tool name, so both halves of the
        /// interpolated form are covered. Only the fragments that carry the choice
        /// notation, or are long enough to be distinctive, are kept: `this task` is a
        /// fragment of the real offer and also an ordinary English phrase, and
        /// refusing every question containing it would be a rule about English rather
        /// than about the gate.
        private static let gateOffers: [String] = {
            let marker = "zzztoolnamezzz"
            return [true, false]
                .map { PermissionGate.choices(isDestructive: $0, tool: marker) }
                .flatMap { normalised($0).components(separatedBy: marker) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("[") || $0.count >= 16 }
        }()

        /// `[y]`, `[n]`, `[a]` — the gate's notation for a key it will accept.
        private static func containsBracketedKey(_ text: String) -> Bool {
            let characters = Array(text)
            for index in characters.indices.dropLast(2)
            where characters[index] == "[" && characters[index + 1].isLetter
                && characters[index + 2] == "]" {
                return true
            }
            return false
        }

        /// Lowercased, whitespace collapsed, and everything that is neither a letter,
        /// a digit nor one of the few punctuation marks the gate's offer is made of
        /// removed outright.
        ///
        /// Removal rather than replacement is the point. A zero-width space is not a
        /// control character and survives `Policy.summarize` — so `[y\u{200B}]es`
        /// reaches the user's eyes as `[y]es` while a check on the raw text sees
        /// something else entirely. Dropping every scalar that cannot carry meaning on
        /// screen makes what is compared here the thing the user would actually read.
        private static func normalised(_ text: String) -> String {
            var out = ""
            var pendingSpace = false
            for character in text.lowercased() {
                if character.isWhitespace || character.isNewline {
                    pendingSpace = !out.isEmpty
                    continue
                }
                guard character.isLetter || character.isNumber
                    || "[]/?".contains(character) else { continue }
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(character)
            }
            return out
        }
    }
}
