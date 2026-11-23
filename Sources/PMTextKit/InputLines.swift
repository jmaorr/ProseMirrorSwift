import Foundation
import PMState
import PMCommands

/// Text arriving through the input gate with line breaks in it (dictation's "new line", a text
/// replacement, a keyboard's multi-line insert). Outside a code block its lines go in one by
/// one with the keymap's Enter between them, so a break splits blocks where it is, as Return
/// would, instead of landing in the document as a character or a space. A run of blank lines
/// is one break: several Enters in a row would set off the keymap's empty-item handling (leave
/// a list, drop an empty card) partway through the text. In a code block the text goes in as
/// it is, its breaks as newlines. Shared by AppKit and UIKit.
enum InputLines {
    /// Every kind of line break as "\n": CRLF, CR and the Unicode line and paragraph separators.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[\r\u{2028}\u{2029}]", with: "\n", options: .regularExpression)
    }

    /// The lines of `text` to put in with an Enter between each, runs of breaks counting as one.
    static func split(_ text: String) -> [String] {
        normalized(text).replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
    }

    /// Put `text` in place of `range`: `run` applies a command to the view, `enter` runs its
    /// keymap's Enter (false when nothing took it). Stops if a line can't be put in, so the
    /// rest never lands somewhere else.
    @MainActor
    static func apply(_ text: String, over range: (from: Int, to: Int), state: () -> EditorState,
                      run: (@escaping Command) -> Bool, enter: () -> Bool) {
        let start = state()
        guard range.from >= 0, range.from <= range.to, range.to <= start.doc.content.size else { return }
        if start.doc.resolve(range.from).parent.type.spec.code {
            let text = normalized(text)
            _ = run { state, dispatch, _ in
                guard let tr = text.isEmpty ? (range.from < range.to ? try? state.tr.delete(range.from, range.to) : nil)
                        : try? state.tr.insertText(text, range.from, range.to) else { return false }
                dispatch?(tr.scrollIntoView())
                return true
            }
            return
        }
        let lines = split(text)
        let more = lines.count > 1
        let first = lines[0]
        // Nothing to replace or type before the first break, with the caret there already:
        // straight to the Enter.
        let caretThere = start.selection.from == range.from && start.selection.to == range.from
        if !first.isEmpty || range.from < range.to || (more && !caretThere) {
            let done = run { state, dispatch, _ in
                guard let tr = replace(state, range, with: first, caretAfter: more) else { return false }
                dispatch?(tr.scrollIntoView())
                return true
            }
            guard done else { return }
        }
        for line in lines.dropFirst() {
            // The keymap's Enter; if nothing takes it, a plain split; failing that, a space.
            if !enter(), !run(splitBlock) {
                let spaced = run { state, dispatch, _ in
                    guard let tr = try? state.tr.insertText(" ") else { return false }
                    dispatch?(tr.scrollIntoView())
                    return true
                }
                guard spaced else { return }
            }
            guard !line.isEmpty else { continue }
            let done = run { state, dispatch, _ in
                guard let tr = try? state.tr.insertText(line) else { return false }
                dispatch?(tr.scrollIntoView())
                return true
            }
            guard done else { return }
        }
    }

    /// `range` replaced with `line` (deleted when the line is empty), with the caret after it
    /// when `caretAfter` (more lines follow there); nil when that can't be done.
    static func replace(_ state: EditorState, _ range: (from: Int, to: Int), with line: String,
                        caretAfter: Bool = false) -> Transaction? {
        let tr: Transaction
        if line.isEmpty {
            if range.from < range.to {
                guard let deleted = try? state.tr.delete(range.from, range.to) else { return nil }
                tr = deleted
            } else {
                tr = state.tr
            }
        } else {
            guard let inserted = try? state.tr.insertText(line, range.from, range.to) else { return nil }
            tr = inserted
        }
        if caretAfter { _ = tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(range.to))) }
        return tr
    }
}
