import Testing
import Foundation
@testable import OpenClickyKit

/// Exercises the tools against the real machine. These are deliberately not mocked:
/// the whole point of Tiers 0–2 is that they talk to macOS, and a mocked version
/// would prove nothing about whether `osascript` or the accessibility API works.
/// Everything here is read-only or confined to a temporary directory.
@Suite("Tool execution", .serialized)
struct ToolExecutionTests {

    private func text(_ output: ToolOutput) -> String {
        output.content.compactMap {
            if case let .text(t) = $0 { return t }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Tier 0

    @Test("shell runs a command and returns stdout")
    func shellRuns() async throws {
        let output = try await ShellTool().run(.object(["command": .string("echo hello-openclicky")]))
        #expect(!output.isError)
        #expect(text(output).contains("hello-openclicky"))
    }

    @Test("shell reports a failing command as an error, with stderr")
    func shellSurfacesFailure() async throws {
        let output = try await ShellTool().run(
            .object(["command": .string("ls /nonexistent-openclicky-path")])
        )
        #expect(output.isError)
        #expect(text(output).contains("exit code"))
    }

    @Test("shell refuses a deny-listed command before running it")
    func shellRefusesDenied() async {
        await #expect(throws: Policy.Violation.self) {
            try await ShellTool().run(.object(["command": .string("rm -rf /")]))
        }
    }

    @Test("shell honours its timeout")
    func shellTimesOut() async throws {
        let output = try await ShellTool().run(.object([
            "command": .string("sleep 10"),
            "timeout_seconds": .number(1),
        ]))
        #expect(output.isError)
        #expect(text(output).contains("timeout"))
    }

    @Test("The sandbox profile confines writes to system locations")
    func sandboxBlocksSystemWrites() async throws {
        let output = try await ShellTool(sandbox: .enabled).run(
            .object(["command": .string("touch /usr/openclicky-should-not-exist")])
        )
        #expect(output.isError, "sandbox-exec should have refused a write to /usr")
        #expect(!FileManager.default.fileExists(atPath: "/usr/openclicky-should-not-exist"))
    }

    @Test("read_file and write_file round-trip")
    func fileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-tests-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("note.txt").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try await WriteFileTool().run(.object([
            "path": .string(path), "content": .string("ladder"),
        ]))
        #expect(!written.isError)

        let read = try await ReadFileTool().run(.object(["path": .string(path)]))
        #expect(text(read) == "ladder")
    }

    @Test("read_file refuses credential paths")
    func readFileRefusesCredentials() async {
        await #expect(throws: Policy.Violation.self) {
            try await ReadFileTool().run(.object(["path": .string("~/.ssh/id_rsa")]))
        }
    }

    @Test("Overwriting an existing file is classified destructive")
    func overwriteIsDangerous() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-overwrite-\(UUID().uuidString).txt")
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let input = JSONValue.object(["path": .string(url.path), "content": .string("new")])
        guard case .dangerous = WriteFileTool().risk(for: input) else {
            Issue.record("overwriting an existing file should be destructive")
            return
        }
        guard case .write = WriteFileTool().risk(
            for: .object(["path": .string(url.path + ".new"), "content": .string("x")])
        ) else {
            Issue.record("creating a new file should be a plain write")
            return
        }
    }

    // MARK: - Tier 1

    @Test("app_script evaluates AppleScript")
    func appleScriptRuns() async throws {
        let output = try await AppleScriptTool().run(
            .object(["script": .string("return 6 * 7")])
        )
        #expect(!output.isError)
        #expect(text(output).trimmingCharacters(in: .whitespacesAndNewlines) == "42")
    }

    @Test("app_script evaluates JXA")
    func jxaRuns() async throws {
        let output = try await AppleScriptTool().run(.object([
            "script": .string("'open' + 'clicky'"),
            "language": .string("javascript"),
        ]))
        #expect(!output.isError)
        #expect(text(output).contains("openclicky"))
    }

    @Test("app_script reads live system state without any screenshot")
    func appleScriptReadsSystemState() async throws {
        let output = try await AppleScriptTool().run(.object([
            "script": .string("tell application \"System Events\" to return name of first process whose frontmost is true"),
        ]))
        // Needs Automation consent for System Events; a refusal is a valid outcome
        // in CI, so assert on the shape rather than a specific app name.
        if !output.isError { #expect(!text(output).isEmpty) }
    }

    @Test("app_script surfaces a syntax error rather than pretending to succeed")
    func appleScriptReportsErrors() async throws {
        let output = try await AppleScriptTool().run(
            .object(["script": .string("this is not applescript at all")])
        )
        #expect(output.isError)
        #expect(text(output).contains("Script failed"))
    }

    @Test("Mutating and outward-facing scripts are classified higher than queries")
    func scriptRiskClassification() {
        let tool = AppleScriptTool()
        guard case .read = tool.risk(for: .object([
            "script": .string("tell application \"Mail\" to unread count of inbox")
        ])) else { Issue.record("a query should be read-only"); return }

        guard case .write = tool.risk(for: .object([
            "script": .string("tell application \"Notes\" to make new note")
        ])) else { Issue.record("creating a note should be a write"); return }

        guard case .dangerous = tool.risk(for: .object([
            "script": .string("tell application \"Mail\" to send outgoing message 1")
        ])) else { Issue.record("sending mail should be destructive"); return }
    }

    @Test("run_shortcut lists the user's shortcuts")
    func shortcutsLists() async throws {
        let output = try await ShortcutsTool().run(.object([:]))
        #expect(!output.isError)
    }

    // MARK: - Tier 2

    @Test("ax_capture reads the frontmost window, or explains why it cannot")
    func axCaptureWorks() async throws {
        let output = try await AXCaptureTool().run(.object([:]))
        if await AXCapture.shared.isTrusted {
            #expect(!output.isError, "accessibility is granted, so a capture should succeed")
            #expect(text(output).contains("elements"))
        } else {
            #expect(output.isError)
            #expect(text(output).contains("Accessibility permission"))
        }
    }

    @Test("Acting on a stale element id fails loudly instead of hitting the wrong thing")
    func staleElementIsRejected() async throws {
        let output = try await AXPressTool().run(.object(["element_id": .string("e99999")]))
        #expect(output.isError)
    }

    // MARK: - Registry

    @Test("The registry orders tools by tier so the cheapest are described first")
    func registryOrdersByTier() {
        let registry = ToolRegistry([
            ScreenshotTool(), ShellTool(), AXCaptureTool(), AppleScriptTool(),
        ])
        #expect(registry.ordered.map(\.tier) == [.shell, .script, .accessibility, .pixels])
    }

    @Test("Capping the tier removes the tools above it")
    func tierCapExcludesHigherTiers() {
        let all: [any Tool] = [
            ShellTool(), AppleScriptTool(), AXCaptureTool(), ScreenshotTool(), ClickTool(),
        ]
        let capped = ToolRegistry(all.filter { $0.tier <= .script })
        #expect(capped.maxTier == .script)
        #expect(capped["screenshot"] == nil)
        #expect(capped["click"] == nil)
        #expect(capped["app_script"] != nil)
    }

    @Test("Every tool has a unique name and a non-trivial description")
    func toolMetadataIsSound() {
        let all: [any Tool] = [
            ShellTool(), ReadFileTool(), WriteFileTool(), AppleScriptTool(), ShortcutsTool(),
            AXCaptureTool(), AXPressTool(), AXSetValueTool(), ScreenshotTool(), ZoomTool(),
            ClickTool(), DragTool(), TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
        ]
        let names = all.map(\.name)
        #expect(Set(names).count == names.count, "tool names must be unique")
        for tool in all {
            #expect(tool.description.count > 40, "\(tool.name) needs a real description")
            #expect(tool.inputSchema["additionalProperties"]?.boolValue == false, "\(tool.name) schema must be closed for strict mode")
        }
    }
}
