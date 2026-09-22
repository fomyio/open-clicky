import Foundation

/// A change to what is in front of the user, and nothing else.
///
/// This type exists to make one thing impossible. `Risk.focus` sits below `.write` — it
/// never prompts, in any mode that is not `.readOnly` — and the whole justification for
/// that is the argument `AskUserTool.risk` makes for classifying itself `.read`: a
/// classification below `.write` has to be **earned twice, once on effect and once on
/// argument**.
///
/// - **On effect**: nothing is written, nothing is executed, no file is opened, no other
///   process is signalled. What changes is which window is in front, and the undo is to
///   put a different one there.
/// - **On argument**: the thing acted on came from an enumeration of this machine. Not a
///   name that was matched, not a string that was validated — an entry that a scan of
///   the disk produced.
///
/// The second half is the one that rots. A `Risk.focus(summary: String)` would let any
/// tool added later return one from free text and exempt itself from the only prompt the
/// user relies on, and it would be a single plausible-looking line in a diff. So the
/// payload is a type whose `init` is private and whose only constructors are the
/// factories below: **the list of things that can be a focus change is this file, and
/// adding to it means editing this file.** `StopReason` is built the same way and for
/// the same reason — a guarantee that depends on everyone remembering is not one.
///
/// Every factory takes an *enumerated* value rather than a string. `activate` takes an
/// `AppCatalogue.Entry`, which cannot be conjured: it is produced by scanning
/// `/Applications`. That is what makes "the argument was enumerated" a fact about the
/// type rather than a claim in a comment.
public struct FocusChange: Sendable, Equatable {

    /// What the user is told, on the one path where this does reach a prompt — a focus
    /// change onto a security surface, which `Policy.escalate` turns into `.dangerous`.
    public let summary: String

    /// What this action *is*, for deciding whether it has already been done.
    ///
    /// A voice turn is classified several times as it is spoken — on the first three
    /// words, then the first six — and the same instruction appears in every one of
    /// those windows. Without a stable identity the session performs it once per window.
    /// Keyed on the action rather than on the words, because "open Safari" and "open
    /// Safari please" are the same act.
    public let identity: String

    private init(summary: String, identity: String) {
        self.summary = summary
        self.identity = identity
    }

    // MARK: - The closed set

    /// Bring an application to the front, launching it if it is not running.
    ///
    /// Takes the catalogue entry rather than a bundle identifier so that what is
    /// activated is the thing that was enumerated. A `String` here would re-open the
    /// hole this type closes: any identifier would do, and "the argument came from the
    /// disk" would be back to being a convention.
    public static func activate(_ entry: AppCatalogue.Entry) -> FocusChange {
        FocusChange(
            summary: "bring \(entry.name) to the front",
            identity: "activate:\(entry.bundleIdentifier)"
        )
    }
}
