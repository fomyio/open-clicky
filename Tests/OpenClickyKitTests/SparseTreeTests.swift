import Testing
import Foundation
@testable import OpenClickyKit

/// An app that publishes no accessibility tree, and an app whose tree was clipped,
/// look identical to a model unless the capture says which happened.
///
/// Measured on this machine before the note was written: a capture of VS Code walks
/// 13 elements and keeps 5 — the window, a group, and three unlabelled window
/// buttons. Finder, captured identically, walks 316 and keeps 280 with 120
/// actionable. Neither hit a node or depth limit, so VS Code is not truncated; it
/// simply does not populate the tree. Electron apps generally do not, unless their
/// own screen-reader mode is on.
@Suite("Sparse accessibility trees")
struct SparseTreeTests {

    private func node(_ id: String, _ role: String) -> AXNode {
        AXNode(id: id, role: role, subrole: nil, title: nil, value: nil,
               help: nil, enabled: true, frame: nil, depth: 0, actions: ["AXPress"])
    }

    private func capture(
        nodes: Int, walked: Int, nodeLimit: Bool = false, depthLimit: Bool = false
    ) -> AXCapture.Capture {
        AXCapture.Capture(
            app: "Test",
            nodes: (0..<nodes).map { node("e\($0)", "AXButton") },
            totalNodesWalked: walked,
            hitNodeLimit: nodeLimit,
            hitDepthLimit: depthLimit,
            filteredToInteractive: false
        )
    }

    @Test("An app that returns almost nothing is reported as sparse")
    func vsCodeShapedCaptureIsSparse() throws {
        // The VS Code reading: 5 kept, 13 walked, no limits.
        let vscode = capture(nodes: 5, walked: 13)
        #expect(vscode.isEffectivelyEmpty)
        let note = try #require(vscode.truncationNote)
        #expect(note.hasPrefix("SPARSE:"))
        #expect(note.contains("not evidence that the control you want is absent"))
    }

    @Test("A rich tree says nothing")
    func finderShapedCaptureIsSilent() {
        // The Finder reading: 280 kept, 316 walked, no limits.
        let finder = capture(nodes: 280, walked: 316)
        #expect(!finder.isEffectivelyEmpty)
        #expect(finder.truncationNote == nil)
    }

    @Test("A clipped tree keeps its own note rather than being called sparse")
    func truncationOutranksSparsity() {
        // A capture that hit a limit is already explained, and calling it sparse would
        // send the model down a tier it does not need.
        let clipped = capture(nodes: 400, walked: 400, nodeLimit: true)
        #expect(!clipped.isEffectivelyEmpty)
        #expect(clipped.truncationNote?.hasPrefix("INCOMPLETE:") == true)
    }

    @Test("A small capture that hit a limit is not called sparse")
    func smallButTruncatedIsNotSparse() {
        // `interactive_only` can legitimately leave few nodes. Only a capture that
        // walked everything and still found nothing says the app publishes nothing.
        let small = capture(nodes: 3, walked: 3, depthLimit: true)
        #expect(!small.isEffectivelyEmpty)
        #expect(small.truncationNote?.hasPrefix("INCOMPLETE:") == true)
    }

    @Test("The note points down the ladder, not up it")
    func noteSteersToCheaperTiers() throws {
        // The failure this exists to prevent is a model concluding "the control is not
        // there" or reaching for pixels. Tier 2 being blind is a reason to drop to a
        // shell command, not to photograph the screen.
        let note = try #require(capture(nodes: 5, walked: 13).truncationNote)
        #expect(note.contains("tier 0 or tier 1"))
        #expect(note.contains("last resort"))
    }

    @Test("The element count is grammatical")
    func singularElementReadsCorrectly() {
        let one = capture(nodes: 1, walked: 4)
        #expect(one.truncationNote?.contains("only 1 element and") == true)
    }
}
