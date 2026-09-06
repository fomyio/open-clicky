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
            actionsTaken: 0, observationsMade: 3, intent: .action, stopReason: "end_turn"
        )
        #expect(noActions.isUnfulfilled)

        let acted = RunOutcome(
            actionsTaken: 1, observationsMade: 3, intent: .action, stopReason: "end_turn"
        )
        #expect(!acted.isUnfulfilled)

        let asked = RunOutcome(
            actionsTaken: 0, observationsMade: 3, intent: .question, stopReason: "end_turn"
        )
        #expect(!asked.isUnfulfilled)
    }

    @Test("A fulfilled run's report is the plain stop reason")
    func fulfilledReportIsUnchanged() {
        // The guard adds nothing to the ordinary path. If it did, every existing
        // closing line would change and the warning would stop standing out.
        let outcome = RunOutcome(
            actionsTaken: 2, observationsMade: 1, intent: .action, stopReason: "end_turn"
        )
        #expect(outcome.report == "end_turn")
    }

    @Test("The unfulfilled report says so in words, and pluralises")
    func unfulfilledReportReadsCorrectly() {
        // "1 observations" is the same defect as "1 turns" and "one tiers" this
        // codebase has fixed twice already.
        let one = RunOutcome(
            actionsTaken: 0, observationsMade: 1, intent: .action, stopReason: "end_turn"
        )
        #expect(one.report.contains("nothing was done"))
        #expect(one.report.contains("1 observation and"))

        let many = RunOutcome(
            actionsTaken: 0, observationsMade: 4, intent: .action, stopReason: "end_turn"
        )
        #expect(many.report.contains("4 observations"))
    }

    // MARK: - What the user sees

    @Test("An unfulfilled run's closing line is a warning, not a status")
    func reportRendersUnfulfilledAsWarning() throws {
        var report = RunReport(isInteractive: false)
        let outcome = RunOutcome(
            actionsTaken: 0, observationsMade: 1, intent: .action, stopReason: "end_turn"
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
            actionsTaken: 2, observationsMade: 0, intent: .action, stopReason: "end_turn"
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
}
