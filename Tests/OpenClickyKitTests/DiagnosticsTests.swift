import Testing
import Foundation
@testable import OpenClickyKit

/// User-facing messages are part of the product. These are the ones people meet
/// before anything works, so a wrong instruction here is the whole first impression.
@Suite("Diagnostics and guidance")
struct DiagnosticsTests {

    /// Every `openclicky …` in an error message has to be a command that parses.
    /// This one suggested `openclicky auth --set`, which exits with
    /// "Unknown option '--set'" — a dead end at the most common first error.
    @Test("The credentials error only names commands that exist")
    func credentialsErrorNamesRealCommands() {
        let message = AnthropicClient.Error.missingCredentials.description
        let commands = message.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("openclicky ") }

        #expect(!commands.isEmpty, "the error should tell the user what to run")
        for command in commands {
            let arguments = command.split(separator: " ").dropFirst().map(String.init)
            let subcommand = arguments.first ?? ""
            #expect(["auth", "doctor"].contains(subcommand), "'\(command)' is not a real command")
            #expect(!arguments.contains { $0.hasPrefix("--") },
                    "'\(command)' passes a flag these subcommands do not accept")
        }
    }

    @Test("The credentials error offers both ways to supply a key")
    func credentialsErrorCoversBothPaths() {
        let message = AnthropicClient.Error.missingCredentials.description
        #expect(message.contains("openclicky auth"), "the Keychain path")
        #expect(message.contains("ANTHROPIC_API_KEY"), "the environment path")
    }

    /// A permission error the user cannot act on is just an obstacle.
    @Test("Permission advice names the pane to open", arguments: [
        // (screenRecording, accessibility, the pane the advice must name)
        (false, true, "Screen"),
        (true, false, "Accessibility"),
        (false, false, "Accessibility"),
    ])
    func permissionAdviceIsActionable(scenario: (Bool, Bool, String)) {
        let status = PermissionStatus(
            screenRecording: scenario.0, accessibility: scenario.1
        )
        let advice = try! #require(status.advice)
        #expect(advice.contains(scenario.2), "advice was: \(advice)")
        #expect(advice.contains("System Settings"))
        #expect(advice.contains("Tiers 0 and 1"), "and what still works meanwhile")
    }

    @Test("Nothing is reported when everything is granted")
    func noAdviceWhenGranted() {
        #expect(PermissionStatus(screenRecording: true, accessibility: true).advice == nil)
    }

    /// These reach the model as tool errors, so they have to say what to do next
    /// rather than only what went wrong.
    @Test("Tool failures tell the model how to recover")
    func toolErrorsSuggestRecovery() {
        #expect(AXCapture.Error.notTrusted.description.contains("System Settings"))
        #expect(AXCapture.Error.unknownElement("e9").description.contains("ax_capture again"))
        #expect(ScreenCapture.Error.notPermitted.description.contains("System Settings"))
        #expect(ScreenToolError.noScreenshot.description.contains("screenshot"))
        #expect(InputInjector.Error.notTrusted.description.contains("Accessibility"))
    }

    @Test("An unknown key names what a valid one looks like")
    func unknownKeyIsInstructive() {
        let message = InputInjector.Error.unknownKey("Frobnicate").description
        #expect(message.contains("Frobnicate"))
        #expect(message.contains("Return") || message.contains("Escape"))
    }

    /// The hotkey refusal has to explain itself, or it reads as an arbitrary limit.
    @Test("Refusing a modifier-less hotkey explains why")
    func hotKeyRefusalExplainsItself() {
        do {
            _ = try HotKey.parse("space")
            Issue.record("expected a throw")
        } catch let error as HotKey.Error {
            #expect(error.description.contains("typing"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test("A deny-list refusal says it cannot be overridden")
    func denyListRefusalIsClear() {
        do {
            try Policy.validateShell("rm -rf /")
            Issue.record("expected a throw")
        } catch let violation as Policy.Violation {
            #expect(violation.description.contains("every permission mode"))
            #expect(violation.description.contains("yourself in a terminal"),
                    "and what the user can do instead")
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test("API errors carry the status and the server's own message")
    func apiErrorsAreDiagnostic() {
        let error = AnthropicClient.Error.api(
            status: 400, type: "invalid_request_error",
            message: "thinking.budget_tokens is not supported", retryAfter: nil
        )
        #expect(error.description.contains("400"))
        #expect(error.description.contains("invalid_request_error"))
        #expect(error.description.contains("budget_tokens"))
    }

    // MARK: - What doctor's exit code means

    /// The verdict is the exit code, so `openclicky doctor && openclicky "…"` guards a
    /// run. It reported missing permissions and absent credentials and then exited 0,
    /// which tells a script the machine is ready. Extracted from `main.swift` because
    /// the version living there was unreachable by any test — how three other guards
    /// in this project came to be defended by nothing.
    @Test("Everything granted and a working key is ready")
    func readyWhenAllIsWell() {
        let granted = PermissionStatus(screenRecording: true, accessibility: true)
        #expect(granted.isReady(credentials: .working))
    }

    /// A laptop on a train is not a broken machine. An unreachable API says nothing
    /// about the key, so it says nothing about readiness.
    @Test("An unreachable API is not a failure")
    func unreachableIsNotFailure() {
        let granted = PermissionStatus(screenRecording: true, accessibility: true)
        #expect(granted.isReady(credentials: .unreachable("offline")))
    }

    @Test("A rejected key is not ready")
    func rejectedKeyIsNotReady() {
        let granted = PermissionStatus(screenRecording: true, accessibility: true)
        #expect(!granted.isReady(credentials: .rejected("API key is invalid.")))
    }

    @Test("No credentials at all is not ready")
    func missingCredentialsIsNotReady() {
        let granted = PermissionStatus(screenRecording: true, accessibility: true)
        #expect(!granted.isReady(credentials: nil))
    }

    /// A missing permission is a missing capability whatever the key says.
    @Test("A missing permission is not ready", arguments: [
        (false, true), (true, false), (false, false),
    ])
    func missingPermissionIsNotReady(pair: (Bool, Bool)) {
        let status = PermissionStatus(screenRecording: pair.0, accessibility: pair.1)
        #expect(!status.isReady(credentials: .working))
    }
}
