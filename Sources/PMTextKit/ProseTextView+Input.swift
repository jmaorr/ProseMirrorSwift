#if os(macOS)
import AppKit
import PMModel
import PMTransform
import PMState

extension ProseTextView {
    // MARK: Text input
    //
    // As in prosemirror-view, edits inside one paragraph are made by AppKit itself and read
    // back afterwards (docs/plans/2026-10-29-native-input.md). NSTextView then keeps its own
    // autocorrect and correction bubble, smart punctuation, text replacement, inline
    // predictions, IME, dictation and Writing Tools. Edits that cross paragraphs, add
    // newlines or touch block leaves become transactions instead.

    static let blockCharacters = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}\u{FFFC}")

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        typedText = text
        defer { typedText = nil }
        #if DEBUG
        InputTrace.note(self, "insertText \(text.debugDescription) replacing=\(replacementRange.location == NSNotFound ? "-" : "\(replacementRange.location),\(replacementRange.length)")")
        #endif
        if !hasMarkedText(), !allowNativeEdit {
            // Input rules see typed text before it lands, as in prosemirror-view.
            let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let doc = range == selectedRange() ? (state.selection.from, state.selection.to) : docRange(range)
            if handleTextInput(doc.0, doc.1, text) { return }
        }
        insertingTyped = !hasMarkedText()
        defer { insertingTyped = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Paragraph end in the storage: its "\n" (or the end), however long the paragraph is now.
    private func paragraphEnd(from start: Int) -> Int {
        let string = textStorage!.string as NSString
        let newline = string.range(of: "\n", options: [], range: NSRange(location: start, length: string.length - start))
        return newline.location == NSNotFound ? string.length : newline.location
    }

    /// Whether AppKit may replace `range` with `text` itself: inside one textblock's
    /// paragraph, with no paragraph or object characters. If so, starts tracking the paragraph.
    private func beginNativeEdit(_ range: NSRange, _ text: String) -> Bool {
        guard text.rangeOfCharacter(from: Self.blockCharacters) == nil, let storage = textStorage else { return false }
        let span: ParagraphSpan
        if let edit = nativeEdit {
            span = edit.span
        } else {
            guard renderer.doc === state.doc, let s = renderer.span(atString: range.location), !s.isLeaf,
                  s.strStart + s.length <= storage.length else { return false }
            span = s
        }
        // The span's length is the paragraph before this edit; once tracking, it may be shorter
        // now (a prediction clears its marked word before inserting it), so only its end counts.
        guard range.location >= span.strStart, range.upperBound <= paragraphEnd(from: span.strStart) else { return false }
        if nativeEdit == nil {
            let before = (storage.string as NSString).substring(with: NSRange(location: span.strStart, length: span.length))
            nativeEdit = NativeEdit(span: span, before: Array(before.utf16), caret: state.selection.from - span.pmStart, typed: insertingTyped)
        }
        insertingTyped = false
        return true
    }

    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        #if DEBUG
        InputTrace.note(self, "shouldChangeText \(affectedRanges.map(\.rangeValue)) \(replacementStrings?.map(\.debugDescription) ?? []) native=\(allowNativeEdit)")
        #endif
        if allowNativeEdit { return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) }
        // Attribute-only changes (nil strings) are never allowed; the document owns the styling.
        guard let strings = replacementStrings, affectedRanges.count == 1, let first = affectedRanges.first?.rangeValue,
              let text = strings.first else { return false }
        if let whole = rangeCoveringCollapsedRuns(first), whole != first {
            // An edit reaching into a collapsed run (Backspace after a chip, Delete before
            // one) takes the whole run, as it would an attachment: its hidden characters never
            // change on their own.
            guard !hasMarkedText() else { return false }
            applyAsTransaction(docRange(whole), text)
            return false
        }
        if beginNativeEdit(first, text) {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        guard !hasMarkedText() else { return false }
        // Not a one-paragraph text edit: apply it as a transaction (input rules already ran).
        applyAsTransaction(docRange(first), text)
        return false
    }

    /// Text the gate refused, as transactions (InputLines): line breaks split blocks as Return
    /// would (a run of them is one break); in a code block they stay newlines.
    private func applyAsTransaction(_ range: (from: Int, to: Int), _ text: String) {
        InputLines.apply(text, over: range, state: { state }, run: { run($0) }, enter: { handleKeyDown(KeyEvent(key: "Enter", keyCode: 13)) })
    }

    public override func didChangeText() {
        super.didChangeText()
        readBack()
    }

    /// Show the document again after AppKit's own edit to the text was refused. Replacing the
    /// text moves AppKit's selection, which isn't the user's: the state's selection is put back.
    private func redrawFromState() {
        let wasSyncing = syncingSelection
        syncingSelection = true
        renderer.update(textStorage!, to: state.doc, scope: scope, force: true)
        syncingSelection = wasSyncing
        syncSelectionToView()
        needsDisplay = true
    }

    /// Turn the paragraph AppKit edited into a transaction, once no composition is open.
    private func readBack() {
        guard let edit = nativeEdit, !hasMarkedText(), let storage = textStorage else { return }
        nativeEdit = nil
        let start = edit.span.strStart
        let afterString = (storage.string as NSString).substring(with: NSRange(location: start, length: paragraphEnd(from: start) - start))
        let after = Array(afterString.utf16)
        let sel = selectedRange()
        let anchor = edit.span.pmStart + min(max(sel.location - start, 0), after.count)
        let head = edit.span.pmStart + min(max(sel.upperBound - start, 0), after.count)
        guard let diff = TextDiff.findDiff(edit.before, after, preferred: edit.caret) else {
            // Nothing changed (a cancelled composition); the view's selection still counts.
            if renderer.doc === state.doc { dispatch(state.tr.setSelection(selection(for: sel))) }
            return
        }
        let inserted = String(utf16CodeUnits: Array(after[diff.start..<diff.endB]), count: diff.endB - diff.start)
        #if DEBUG
        InputTrace.note(self, "readBack before=\(String(utf16CodeUnits: edit.before, count: edit.before.count).debugDescription) diff=\(diff) inserted=\(inserted.debugDescription) composed=\(edit.composed)")
        #endif
        heldChange = (edit.span.pmStart + diff.start, edit.span.pmStart + diff.endA, inserted, anchor, head)
        // Changes held back during the composition (remote edits) go first, so the
        // committed text is applied to the document they produce and overwrites nothing.
        if edit.composed { onCompositionEnd?() }
        guard let change = heldChange else { return }
        heldChange = nil
        let errors = CommandErrors.errorCount
        do {
            var tr = change.text.isEmpty ? try state.tr.delete(change.from, change.to)
                : try state.tr.insertText(change.text, change.from, change.to)
            let size = tr.doc.content.size
            _ = tr.setSelection(TextSelection.between(tr.doc.resolve(min(change.anchor, size)), tr.doc.resolve(min(change.head, size))))
            if let prepare = separateUndoStep, !edit.typed || closeHistoryOnNextInput { tr = prepare(tr) }
            // A correction is its own undo step, and so is the typing after it.
            closeHistoryOnNextInput = !edit.typed
            let doc = state.doc
            dispatch(tr.scrollIntoView())
            // Refused (a read-only note's filter): AppKit already changed the text on screen,
            // so put back what the document holds, or the two drift apart.
            if state.doc === doc { redrawFromState() }
        } catch {
            CommandErrors.last = error
            CommandErrors.errorCount += 1
            redrawFromState()
        }
        reportErrors(since: errors)
    }

    // MARK: IME

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Marked text (IME, inline predictions) stays out of the document until committed.
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        #if DEBUG
        InputTrace.note(self, "setMarkedText \(text.debugDescription) selected=\(selectedRange) replacing=\(replacementRange.location == NSNotFound ? "-" : "\(replacementRange.location),\(replacementRange.length)")")
        #endif
        let range = replacementRange.location != NSNotFound ? replacementRange : (hasMarkedText() ? markedRange() : self.selectedRange())
        if !beginNativeEdit(range, text), !hasMarkedText(), state.selection.from != state.selection.to {
            // Composing over a selection across paragraphs: delete it first.
            run { state, dispatch, _ in
                guard let tr = try? state.tr.deleteSelection() else { return false }
                dispatch?(tr)
                return true
            }
            _ = beginNativeEdit(self.selectedRange(), text)
        }
        nativeEdit?.composed = true
        allowNativeEdit = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        allowNativeEdit = false
    }

    /// Commit marked text (IME, a shown prediction) as typed, and tell the input method.
    /// Do this before dispatching a document change built from `state`: rendering it
    /// while marked text is up would draw over the composition.
    public func commitComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    public override func unmarkText() {
        #if DEBUG
        InputTrace.note(self, "unmarkText")
        #endif
        allowNativeEdit = true
        super.unmarkText()
        allowNativeEdit = false
        readBack()
        applyPendingStyle()
    }

    func insert(_ text: String, _ range: (from: Int, to: Int)) {
        if handleTextInput(range.from, range.to, text) { return }
        let errors = CommandErrors.errorCount
        do {
            dispatch(try state.tr.insertText(text, range.from, range.to).scrollIntoView())
        } catch {
            CommandErrors.last = error
            CommandErrors.errorCount += 1
        }
        reportErrors(since: errors)
    }
}
#endif
