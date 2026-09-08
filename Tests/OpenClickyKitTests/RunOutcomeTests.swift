import Testing
import Foundation
@testable import OpenClickyKit

/// The completion guard: whether a run that changed nothing can look like one that did.
///
/// The classifier is a heuristic, so these tests are as much a specification of where
/// it is allowed to be wrong as of where it must be right. It errs toward `.action`
/// deliberately — a false "nothing was done" is a line of noise, a false silence is
/// the original bug.
@Suite("Run outcome")
struct RunOutcomeTests {

    // MARK: - Intent

    @Test("Imperatives are actions", arguments: [
        "format the markdown file in my active VS Code tab",
        "open spotify",
        "empty the trash",
        "send the draft to my inbox",
        "rename these files to lowercase",
        // The task from session DE641705 verbatim. It opens with an imperative and
        // contains an interrogative clause — genuinely mixed phrasing, and the user's
        // intent was action. Classifying by the opener gets this one right.
        "show me in my current vscode how can I format the markdown file in the active tab",
    ])
    func imperativesAreActions(_ task: String) {
        #expect(TaskIntent.classify(task) == .action)
    }

    @Test("Questions are questions", arguments: [
        "how much disk space is left?",
        "what is playing right now",
        "where did I save the invoice",
        "is Docker running",
        "can you see my terminal",
        "which display is the main one",
        "do I have unread mail",
    ])
    func questionsAreQuestions(_ task: String) {
        #expect(TaskIntent.classify(task) == .question)
    }

    @Test("A trailing question mark outranks an imperative opener")
    func questionMarkWins() {
        // The one signal a user types on purpose. "Open Spotify?" is someone asking
        // whether it is open, not telling the agent to open it.
        #expect(TaskIntent.classify("open spotify?") == .question)
    }

    @Test("An interrogative word mid-sentence does not make a question")
    func interrogativeMidSentenceIsStillAction() {
        // "is", "do" and "can" are common inside imperatives. Matching them anywhere
        // in the string would classify most real tasks as questions and silence the
        // guard on exactly the runs it exists for.
        #expect(TaskIntent.classify("tell me what is playing") == .action)
        #expect(TaskIntent.classify("open the file that is newest") == .action)
        #expect(TaskIntent.classify("delete everything I do not need") == .action)
    }

    @Test("Empty and whitespace tasks fall back to action")
    func emptyFallsBackToAction() {
        // Unclassifiable input takes the loud branch, in keeping with the asymmetry.
        #expect(TaskIntent.classify("") == .action)
        #expect(TaskIntent.classify("   \n  ") == .action)
    }

    @Test("Leading punctuation and case do not defeat the opener check")
    func openerIsNormalised() {
        #expect(TaskIntent.classify("What's playing") == .question)
        #expect(TaskIntent.classify("HOW MUCH RAM IS FREE") == .question)
    }

    // MARK: - The verdict

    @Test("Only an action task with zero actions is unfulfilled")
    func unfulfilledRequiresBoth() {
        let noActions = RunOutcome(
            actionsTaken: 0, observationsMade: 3, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(noActions.isUnfulfilled)

        let acted = RunOutcome(
            actionsTaken: 1, observationsMade: 3, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(!acted.isUnfulfilled)

        let asked = RunOutcome(
            actionsTaken: 0, observationsMade: 3, intent: .question, stopReason: .concluded("end_turn")
        )
        #expect(!asked.isUnfulfilled)
    }

    @Test("A fulfilled run's report is the plain stop reason")
    func fulfilledReportIsUnchanged() {
        // The guard adds nothing to the ordinary path. If it did, every existing
        // closing line would change and the warning would stop standing out.
        let outcome = RunOutcome(
            actionsTaken: 2, observationsMade: 1, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(outcome.report == "end_turn")
    }

    @Test("The unfulfilled report says so in words, and pluralises")
    func unfulfilledReportReadsCorrectly() {
        // "1 observations" is the same defect as "1 turns" and "one tiers" this
        // codebase has fixed twice already.
        let one = RunOutcome(
            actionsTaken: 0, observationsMade: 1, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(one.report.contains("nothing was done"))
        #expect(one.report.contains("1 observation and"))

        let many = RunOutcome(
            actionsTaken: 0, observationsMade: 4, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(many.report.contains("4 observations"))
    }

    // MARK: - Finishing, as distinct from changing something

    // `isUnfulfilled` asks whether the run changed anything and never asked whether it
    // finished. From the session listing, verbatim:
    //
    //     open vscode and open the command palette | act=5 obs=7 unfulfilled=False
    //     stop=turn limit (12) reached
    //
    // Five actions, so "it changed something" holds; the palette never opened, because
    // the run ran out of turns first. Two different failures, and merging them would
    // lose one of the two messages.

    @Test("Only the model ending its own turn counts as concluding")
    func onlyEndTurnConcludes() {
        #expect(StopReason.concluded("end_turn").disposition == StopReason.Disposition.concluded)
        #expect(StopReason.cutShort("turn limit (12) reached").disposition
            == StopReason.Disposition.cutShort)
        #expect(StopReason.interrupted.disposition == StopReason.Disposition.interrupted)
        // The wording the renderers match on, kept in one place.
        #expect(StopReason.interrupted.sentence == AgentLoop.Event.interruptedReason)
    }

    @Test("A run cut short is incomplete even though it acted")
    func cutShortAfterActingIsIncomplete() {
        let outcome = RunOutcome(
            actionsTaken: 5, observationsMade: 7, intent: .action,
            stopReason: .cutShort("turn limit (12) reached")
        )
        // The exact reading that exited 0: it acted, so the old guard was silent.
        #expect(!outcome.isUnfulfilled)
        #expect(outcome.wasCutShort)
        #expect(outcome.isIncomplete)
    }

    @Test("An interruption is not counted as an incomplete run")
    func interruptionIsNotIncomplete() {
        // The user asked for the stop. Warning them that the agent fell short of a
        // task they cancelled is noise, and `exit 2` on it breaks a deliberate ctrl-c.
        let outcome = RunOutcome(
            actionsTaken: 2, observationsMade: 1, intent: .action, stopReason: .interrupted
        )
        #expect(!outcome.wasCutShort)
        #expect(!outcome.isIncomplete)
        #expect(outcome.report == "interrupted by the user")
    }

    @Test("A concluded run that acted is complete")
    func concludedRunIsComplete() {
        let outcome = RunOutcome(
            actionsTaken: 5, observationsMade: 7, intent: .action, stopReason: .concluded("end_turn")
        )
        #expect(!outcome.isIncomplete)
        #expect(outcome.report == "end_turn")
    }

    @Test("The cut-short report names what happened and what it managed, and pluralises")
    func cutShortReportReadsCorrectly() {
        let many = RunOutcome(
            actionsTaken: 5, observationsMade: 7, intent: .action,
            stopReason: .cutShort("turn limit (12) reached")
        )
        #expect(many.report.contains("did not finish"))
        #expect(many.report.contains("turn limit (12) reached"))
        #expect(many.report.contains("5 actions and 7 observations"))
        // It states the fact and stops there — it does not know which part of the task
        // was left undone, and a guess reads as a diagnosis.
        #expect(!many.report.contains("nothing was done"))

        let one = RunOutcome(
            actionsTaken: 1, observationsMade: 1, intent: .action,
            stopReason: .cutShort("response truncated at the 16000-token limit")
        )
        #expect(one.report.contains("1 action and 1 observation."))
    }

    @Test("A run that did nothing and was cut short reports having done nothing")
    func doingNothingOutranksNotFinishing() {
        // Both are true and there is one closing line. "nothing was done" wins because
        // it already interpolates the stop reason, so choosing it loses no fact —
        // whereas the cut-short line would drop that the machine is untouched.
        let outcome = RunOutcome(
            actionsTaken: 0, observationsMade: 3, intent: .action,
            stopReason: .cutShort("turn limit (12) reached")
        )
        #expect(outcome.isUnfulfilled)
        #expect(outcome.wasCutShort)
        #expect(outcome.report.contains("nothing was done"))
        #expect(outcome.report.contains("turn limit (12) reached"))
        #expect(!outcome.report.contains("did not finish"))
    }

    // MARK: - What the user sees

    @Test("A run cut short closes on a warning, not a status")
    func reportRendersCutShortAsWarning() throws {
        // The paragraph above this line was written mid-task and reads exactly like a
        // closing summary. The emphasis is the only thing separating them.
        var report = RunReport(isInteractive: false)
        let outcome = RunOutcome(
            actionsTaken: 5, observationsMade: 7, intent: .action,
            stopReason: .cutShort("turn limit (12) reached")
        )
        _ = report.lines(for: .outcome(outcome))
        let lines = report.lines(for: .finished(reason: "turn limit (12) reached"))

        let closing = try #require(lines.first { !$0.text.isEmpty })
        #expect(closing.emphasis == .warning)
        #expect(closing.text.contains("did not finish"))
    }

    @Test("An unfulfilled run's closing line is a warning, not a status")
    func reportRendersUnfulfilledAsWarning() throws {
        var report = RunReport(isInteractive: false)
        let outcome = RunOutcome(
            actionsTaken: 0, observationsMade: 1, intent: .action, stopReason: .concluded("end_turn")
        )
        _ = report.lines(for: .outcome(outcome))
        let lines = report.lines(for: .finished(reason: "end_turn"))

        let closing = try #require(lines.first { !$0.text.isEmpty })
        #expect(closing.emphasis == .warning)
        #expect(closing.text.contains("nothing was done"))
    }

    @Test("A fulfilled run's closing line stays a plain detail line")
    func reportRendersFulfilledAsDetail() throws {
        var report = RunReport(isInteractive: false)
        let outcome = RunOutcome(
            actionsTaken: 2, observationsMade: 0, intent: .action, stopReason: .concluded("end_turn")
        )
        _ = report.lines(for: .outcome(outcome))
        let lines = report.lines(for: .finished(reason: "end_turn"))

        let closing = try #require(lines.first { !$0.text.isEmpty })
        #expect(closing.emphasis == .detail)
        #expect(closing.text == "── end_turn")
    }

    @Test("A renderer that never sees an outcome still prints the stop reason")
    func reportToleratesAMissingOutcome() throws {
        // `.outcome` arrives before `.finished`, but a caller that filters events —
        // or an older one — must not lose the closing line entirely.
        var report = RunReport(isInteractive: false)
        let lines = report.lines(for: .finished(reason: "turn limit (40) reached"))
        let closing = try #require(lines.first { !$0.text.isEmpty })
        #expect(closing.text == "── turn limit (40) reached")
        #expect(closing.emphasis == .detail)
    }

    // MARK: - Imperatives that only ask for information

    // Found by running the agent, not by reading it. "count the files in /tmp and tell
    // me the number" is phrased as an instruction, so the opener check called it an
    // action — and a correct run answers it with one read and zero actions, which the
    // guard would report as "nothing was done" and exit 2. A guard that fires on
    // correct runs is one the user learns to ignore.

    @Test("Verbs that cannot ask for a change are questions", arguments: [
        "count the files in /tmp and tell me the number",
        "list my running applications",
        "summarize the notes in this document",
        "describe what is on my screen",
        "explain what this script does",
        "compare these two files",
    ])
    func informationalImperativesAreQuestions(_ task: String) {
        #expect(TaskIntent.classify(task) == TaskIntent.question)
    }

    @Test("Verbs with an ordinary action reading stay actions", arguments: [
        // Every one of these has a state-changing sense on a Mac, so a narrow list is
        // the whole point. `tell application "Spotify" to play` is the idiom this
        // project is built around.
        "show me in my current vscode how can I format the markdown file in the active tab",
        "tell Spotify to play",
        "find the duplicate photos and move them to the trash",
        "check out the develop branch",
        "read the config and apply it",
    ])
    func ambiguousVerbsStayActions(_ task: String) {
        #expect(TaskIntent.classify(task) == TaskIntent.action)
    }

    @Test("The run that motivated the guard is still flagged")
    func theOriginalCaseStillFlags() {
        // The regression that would matter most: widening the question set until the
        // case the guard exists for stops being caught.
        let outcome = RunOutcome(
            actionsTaken: 0, observationsMade: 1,
            intent: .classify("show me in my current vscode how can I format the markdown file in the active tab"),
            stopReason: .concluded("end_turn")
        )
        #expect(outcome.isUnfulfilled)
    }

    @Test("A counted answer with one read is not reported as nothing done")
    func informationalRunIsNotUnfulfilled() {
        let outcome = RunOutcome(
            actionsTaken: 0, observationsMade: 1,
            intent: .classify("count the files in /tmp and tell me the number"),
            stopReason: .concluded("end_turn")
        )
        #expect(!outcome.isUnfulfilled)
        #expect(outcome.report == "end_turn")
    }

}
