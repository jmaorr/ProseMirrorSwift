#if canImport(UIKit) && !os(macOS)
import UIKit
import UniformTypeIdentifiers
import PMModel
import PMTransform
import PMState

// MARK: Text input
//
// As on macOS (ProseTextView+Input.swift) and in prosemirror-view, edits inside one paragraph
// are made by UIKit itself and read back afterwards, so UITextView keeps its autocorrect,
// predictions, smart punctuation, marked text (IME), dictation and selection UI. UIKit asks
// `textView(_:shouldChangeTextIn:replacementText:)` before every such edit: that is the gate
// (AppKit's `shouldChangeText(inRanges:)`). Edits that cross paragraphs, add newlines or touch
// block leaves are refused there and applied as transactions instead. Return, Tab and
// Backspace go through the keymaps first, as their key events would in a browser.

extension ProseTextView: UITextViewDelegate {
    static let blockCharacters = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}\u{FFFC}")

    public override func insertText(_ text: String) {
        typedText = text
        defer { typedText = nil }
        if markedTextRange == nil, !allowNativeEdit {
            switch text {
            case "\n", "\r":
                // Return: the keymap's Enter (split a list item, leave a heading). A newline nobody
                // claims never becomes a character in the document.
                if keyTriedByPress != "Enter" { _ = handleKeyDown(.named("Enter", modifiers: heldModifiers)) }
                return
            case "\t":
                if keyTriedByPress != "Tab" { _ = handleKeyDown(.named("Tab", modifiers: heldModifiers)) }
                return
            default:
                break
            }
            if keepsSelection(from: text) { return }
            // Input rules see typed text before it lands, as in prosemirror-view.
            if handleTextInput(state.selection.from, state.selection.to, text) { return }
        }
        // UIKit doesn't consult its delegate for every insertText (not when it's called
        // directly, as the keyboard and tests do), so the view asks the gate itself and reads
        // the paragraph back afterwards. A second ask from UIKit for the same edit is harmless.
        if markedTextRange == nil {
            insertingTyped = true
            defer { insertingTyped = false }
            guard textView(self, shouldChangeTextIn: selectedRange, replacementText: text) else { return }
        }
        insertingTyped = markedTextRange == nil
        allowNativeEdit = markedTextRange != nil
        super.insertText(text)
        allowNativeEdit = false
        insertingTyped = false
        readBack()
    }

    public override func deleteBackward() {
        if markedTextRange == nil, !allowNativeEdit, keyTriedByPress != "Backspace",
           handleKeyDown(.named("Backspace", modifiers: heldModifiers)) { return }
        if markedTextRange == nil {
            guard textView(self, shouldChangeTextIn: deletionRange(), replacementText: "") else { return }
        }
        super.deleteBackward()
        readBack()
    }

    /// What Backspace deletes: the selection, or the character (cluster) before the caret.
    private func deletionRange() -> NSRange {
        let sel = selectedRange
        guard sel.length == 0 else { return sel }
        guard sel.location > 0 else { return sel }
        return (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: sel.location - 1)
    }

    /// Paragraph end in the storage: its "\n" (or the end), however long the paragraph is now.
    private func paragraphEnd(from start: Int) -> Int {
        let string = textStorage.string as NSString
        let newline = string.range(of: "\n", options: [], range: NSRange(location: start, length: string.length - start))
        return newline.location == NSNotFound ? string.length : newline.location
    }

    /// Whether UIKit may replace `range` with `text` itself: inside one textblock's paragraph,
    /// with no paragraph or object characters. If so, starts tracking the paragraph.
    @discardableResult
    func beginNativeEdit(_ range: NSRange, _ text: String) -> Bool {
        guard text.rangeOfCharacter(from: Self.blockCharacters) == nil else { return false }
        let storage = textStorage
        let span: ParagraphSpan
        if let edit = nativeEdit {
            span = edit.span
        } else {
            guard renderer.doc === state.doc, let s = renderer.span(atString: range.location), !s.isLeaf else { return false }
            span = s
        }
        guard range.location >= span.strStart, range.upperBound <= paragraphEnd(from: span.strStart),
              span.strStart + span.length <= storage.length else { return false }
        if nativeEdit == nil {
            let before = (storage.string as NSString).substring(with: NSRange(location: span.strStart, length: span.length))
            nativeEdit = NativeEdit(span: span, before: Array(before.utf16), caret: state.selection.from - span.pmStart, typed: insertingTyped)
        }
        insertingTyped = false
        return true
    }

    /// The gate for every edit UIKit makes to the text.
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if allowNativeEdit {
            beginNativeEdit(range, text)
            return true
        }
        if text == "\n" || text == "\r", markedTextRange == nil, range == selectedRange {
            // The on-screen keyboard's Return asks here before it calls insertText("\n") (and
            // never calls it if refused), so this is where it runs the keymap's Enter, as
            // insertText does. Hardware Return already tried the keymap in pressesBegan. A
            // newline nobody claims never becomes a character (nor a space) in the document.
            if keyTriedByPress != "Enter" { _ = handleKeyDown(.named("Enter", modifiers: heldModifiers)) }
            return false
        }
        // A correction or dictation over a block that text mustn't replace (a selected table).
        if markedTextRange == nil, keepsSelection(from: text) { return false }
        if let whole = rangeCoveringCollapsedRuns(range), whole != range {
            // An edit reaching into a collapsed run takes the whole run, as it would an attachment.
            guard markedTextRange == nil else { return false }
            applyAsTransaction(docRange(whole), text)
            return false
        }
        if beginNativeEdit(range, text) { return true }
        guard markedTextRange == nil else { return false }
        // Not a one-paragraph text edit (a selection across paragraphs, a pasted line break):
        // apply it as a transaction. Input rules already ran.
        applyAsTransaction(docRange(range), text)
        return false
    }

    /// Text the gate refused, as transactions (InputLines): line breaks split blocks as Return
    /// would (a run of them is one break); in a code block they stay newlines.
    private func applyAsTransaction(_ range: (from: Int, to: Int), _ text: String) {
        InputLines.apply(text, over: range, state: { state }, run: { run($0) }, enter: { handleKeyDown(.named("Enter")) })
    }

    public func textViewDidChange(_ textView: UITextView) {
        if nativeEdit == nil, markedTextRange == nil, renderer.doc === state.doc {
            // UIKit changed the text without asking the gate first (no path known to do this
            // today): the document is the truth, so put its text back rather than drift.
            untrackedEdits += 1
            syncingSelection = true
            renderer.update(textStorage, to: state.doc, force: true)
            syncingSelection = false
            syncSelectionToView()
            return
        }
        readBack()
    }

    /// Replacements UIKit makes itself (autocorrect, a tapped suggestion, dictation, text
    /// replacement) go through the gate and are read back, like typing.
    public override func replace(_ range: UITextRange, withText text: String) {
        if markedTextRange == nil, !allowNativeEdit {
            guard textView(self, shouldChangeTextIn: nsRange(range), replacementText: text) else { return }
        }
        super.replace(range, withText: text)
        readBack()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        viewSelectionChanged()
    }

    /// Turn the paragraph UIKit edited into a transaction, once no composition is open.
    func readBack() {
        guard let edit = nativeEdit, markedTextRange == nil else { return }
        nativeEdit = nil
        let storage = textStorage
        let start = edit.span.strStart
        let afterString = (storage.string as NSString).substring(with: NSRange(location: start, length: paragraphEnd(from: start) - start))
        let after = Array(afterString.utf16)
        let sel = selectedRange
        let anchor = edit.span.pmStart + min(max(sel.location - start, 0), after.count)
        let head = edit.span.pmStart + min(max(sel.upperBound - start, 0), after.count)
        guard let diff = TextDiff.findDiff(edit.before, after, preferred: edit.caret) else {
            // Nothing changed (a cancelled composition); the view's selection still counts.
            if renderer.doc === state.doc { dispatch(state.tr.setSelection(selection(for: sel))) }
            return
        }
        let inserted = String(utf16CodeUnits: Array(after[diff.start..<diff.endB]), count: diff.endB - diff.start)
        heldChange = (edit.span.pmStart + diff.start, edit.span.pmStart + diff.endA, inserted, anchor, head)
        // Changes held back during the composition (remote edits) go first, so the committed
        // text is applied to the document they produce and overwrites nothing.
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
            dispatch(tr.scrollIntoView())
        } catch {
            CommandErrors.last = error
            CommandErrors.errorCount += 1
            syncingSelection = true
            renderer.update(textStorage, to: state.doc, force: true)
            syncingSelection = false
            syncSelectionToView()
        }
        reportErrors(since: errors)
    }

    // MARK: Marked text (IME)

    public override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        // Marked text stays out of the document until committed.
        let text = markedText ?? ""
        // A composition starting over a block that text mustn't replace (a selected table).
        if markedTextRange == nil, keepsSelection(from: text) { return }
        let range = markedTextRange.map { nsRange($0) } ?? self.selectedRange
        if !beginNativeEdit(range, text), markedTextRange == nil, state.selection.from != state.selection.to {
            // Composing over a selection across paragraphs: delete it first.
            run { state, dispatch, _ in
                guard let tr = try? state.tr.deleteSelection() else { return false }
                dispatch?(tr)
                return true
            }
            beginNativeEdit(self.selectedRange, text)
        }
        nativeEdit?.composed = true
        allowNativeEdit = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        allowNativeEdit = false
    }

    public override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        setMarkedText(markedText?.string, selectedRange: selectedRange)
    }

    public override func unmarkText() {
        allowNativeEdit = true
        super.unmarkText()
        allowNativeEdit = false
        readBack()
    }

    /// Commit marked text as typed. Do this before dispatching a document change built from
    /// `state`: rendering it while marked text is up would draw over the composition.
    public func commitComposition() {
        guard markedTextRange != nil else { return }
        unmarkText()
    }

    func nsRange(_ range: UITextRange) -> NSRange {
        let start = offset(from: beginningOfDocument, to: range.start)
        return NSRange(location: start, length: offset(from: range.start, to: range.end))
    }

    // MARK: Hardware keys

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { return super.pressesBegan(presses, with: event) }
        heldModifiers = key.modifierFlags
        guard markedTextRange == nil else { return super.pressesBegan(presses, with: event) }
        let keyEvent = KeyEvent(key)
        // A chord with a registered shortcut command is left to UIKit, which delivers its key
        // command (`performShortcut`): that is the only path that runs it.
        if shortcutCommands.contains(where: { $0.matches(keyEvent) }) {
            return super.pressesBegan(presses, with: event)
        }
        if handleKeyDown(keyEvent) { return }
        // The keymap had its chance; don't ask it again when UIKit turns this key into
        // insertText("\n") or deleteBackward().
        keyTriedByPress = keyEvent.key
        super.pressesBegan(presses, with: event)
        keyTriedByPress = nil
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldModifiers = []
        super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldModifiers = []
        super.pressesCancelled(presses, with: event)
    }

    // MARK: Edit menu formatting

    // Bold, Italic and Underline in the edit menu (and their standard shortcuts) run the
    // keymap's ⌘B, ⌘I and ⌘U, so the schema's own toggle commands decide.
    public override func toggleBoldface(_ sender: Any?) { runKey("b") }
    public override func toggleItalics(_ sender: Any?) { runKey("i") }
    public override func toggleUnderline(_ sender: Any?) { runKey("u") }

    private func runKey(_ key: String) {
        commitComposition()
        _ = handleKeyDown(.named(key, modifiers: .command))
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(toggleBoldface(_:)), #selector(toggleItalics(_:)), #selector(toggleUnderline(_:)):
            return isEditable && !state.selection.empty
        case #selector(performShortcut(_:)):
            return isEditable
        case #selector(paste(_:)):
            // UITextView offers Paste for text only; a note's copy, HTML and images paste too.
            let board = pasteboard
            return isEditable && (board.hasStrings || board.contains(pasteboardTypes: [Self.sliceType, UTType.html.identifier])
                || (onIncomingFiles != nil && board.hasImages))
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    // MARK: Clipboard

    /// The pasteboard type holding a copied selection as ProseMirror slice JSON (pasted back
    /// exactly within the app; other apps get the plain text).
    public static let sliceType = "dev.prosemirror-swift.slice"

    /// Where copy, cut and paste go (the general pasteboard; tests use their own).
    public var pasteboard: UIPasteboard { get { customPasteboard ?? .general } set { customPasteboard = newValue } }

    /// Rewrites a slice pasted from a note before it's inserted; nil inserts it as copied.
    public var transformPasted: ((Slice) -> Slice)? {
        get { clipboardHooks.transformPasted }
        set { clipboardHooks.transformPasted = newValue }
    }

    /// Rewrites a note's own slice after `transformPasted`, knowing whether it is moved here
    /// (a cut's first paste) or copied (every other paste, and every drop: dragging out is
    /// off on iOS): an app gives copies new identities here. HTML and Markdown are copies.
    public var adoptPasted: ((Slice, PasteOrigin) -> Slice)? {
        get { clipboardHooks.adoptPasted }
        set { clipboardHooks.adoptPasted = newValue }
    }

    /// `slice` through `transformPasted`, then `adoptPasted` with its origin.
    public func preparePasted(_ slice: Slice, _ origin: PasteOrigin) -> Slice {
        let cleaned = transformPasted?(slice) ?? slice
        return adoptPasted?(cleaned, origin) ?? cleaned
    }

    public override func copy(_ sender: Any?) {
        guard !state.selection.empty else { return }
        pasteboard.items = [selectionItem()]
    }

    /// The selection as plain text and slice JSON.
    private func selectionItem() -> [String: Any] {
        let slice = state.selection.content()
        let text = clipboardText?(slice) ?? slice.content.textBetween(0, slice.content.size, blockSeparator: "\n\n")
        return [UTType.utf8PlainText.identifier: text, Self.sliceType: slice.toJSON().description]
    }

    public override func cut(_ sender: Any?) {
        guard !state.selection.empty else { return }
        // Its first paste is a move (PasteOrigin).
        var item = selectionItem()
        item[PasteOrigin.cutMarkerType] = PasteOrigin.newCutToken()
        pasteboard.items = [item]
        run { state, dispatch, _ in
            guard let tr = try? state.tr.deleteSelection() else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
    }

    /// Paste, as on the Mac: `onPaste` first (HTML or Markdown from other apps), then a note's
    /// own copy exactly, then images (to `onIncomingFiles`), then plain text. One exception: an
    /// image whose HTML is nothing but the image (Safari's Copy Image) goes to `onIncomingFiles`
    /// first, so its bytes are uploaded rather than its URL linked.
    public override func paste(_ sender: Any?) {
        commitComposition()
        let board = pasteboard
        if let onIncomingFiles, Self.isImagePaste(board), case let files = Self.files(on: board), !files.isEmpty,
           onIncomingFiles(files, state.selection.from) { return }
        if let onPaste, onPaste(board) { return }
        var slice: Slice?
        if let parsed = Self.slice(on: board, schema: state.schema) {
            let marker = board.value(forPasteboardType: PasteOrigin.cutMarkerType) as? String
                ?? board.data(forPasteboardType: PasteOrigin.cutMarkerType).flatMap { String(data: $0, encoding: .utf8) }
            slice = preparePasted(parsed, PasteOrigin.forPaste(marker: marker))
        } else if let onIncomingFiles, case let files = Self.files(on: board), !files.isEmpty,
                  onIncomingFiles(files, state.selection.from) {
            return
        } else if let text = board.string, !text.isEmpty {
            if !text.contains(where: \.isNewline), handleTextInput(state.selection.from, state.selection.to, text) { return }
            slice = Self.plainTextSlice(text, state.schema)
        }
        guard let slice else { return }
        run { state, dispatch, _ in
            guard let tr = try? state.tr.replaceSelection(slice) else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
    }

    /// A note's own copy on `board` (slice JSON), or nil.
    static func slice(on board: UIPasteboard, schema: Schema) -> Slice? {
        guard let data = board.data(forPasteboardType: sliceType), let json = String(data: data, encoding: .utf8),
              let value = try? JSONValue.parse(json) else { return nil }
        return try? Slice.fromJSON(schema, value)
    }

    /// Text as a slice: one line stays inline; more become paragraphs.
    static func plainTextSlice(_ text: String, _ schema: Schema) -> Slice? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count == 1 { return text.isEmpty ? nil : Slice(Fragment.from(schema.text(text)), 0, 0) }
        guard let paragraph = schema.nodes["paragraph"] else { return nil }
        let nodes = lines.compactMap { line in
            try? schema.node(paragraph, nil, line.isEmpty ? nil : Fragment.from(schema.text(line)))
        }
        return Slice(Fragment.from(nodes), 1, 1)
    }

    // MARK: Files in

    /// A file dropped or pasted onto the note.
    public struct IncomingFile {
        public let data: Data
        public let filename: String
        /// e.g. "image/png"; nil when the type isn't known.
        public let mimeType: String?
        public var isImage: Bool { mimeType?.hasPrefix("image/") == true }
        public init(data: Data, filename: String, mimeType: String?) {
            self.data = data
            self.filename = filename
            self.mimeType = mimeType
        }
    }

    /// The largest file, in bytes, read from a drop for `onIncomingFiles` (100 MB by default).
    /// Larger files are skipped, as is anything that isn't a regular file.
    public static var maxIncomingFileSize = IncomingFileReader.defaultLimit

    /// An image on the pasteboard with no text to go with it: no note copy, and no HTML or only
    /// HTML without text (an `<img>` and markup).
    static func isImagePaste(_ board: UIPasteboard) -> Bool {
        guard !board.contains(pasteboardTypes: [sliceType]),
              board.contains(pasteboardTypes: pastedImageTypes.map(\.identifier)) else { return false }
        let type = UTType.html.identifier
        let html = board.value(forPasteboardType: type) as? String
            ?? board.data(forPasteboardType: type).flatMap { String(data: $0, encoding: .utf8) }
        return html.map(htmlHasNoText) ?? true
    }

    /// Whether HTML shows no text: nothing but tags, comments, scripts, styles and spaces.
    static func htmlHasNoText(_ html: String) -> Bool {
        var text = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(script|style|head|title)\\b[^>]*>[\\s\\S]*?</\\1\\s*>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[A-Za-z/!][^>\"']*(?:(?:\"[^\"]*\"|'[^']*')[^>\"']*)*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&(nbsp|#160|#xa0);", with: " ", options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Image types read from a pasteboard as they are (a copied photo, a screenshot).
    static let pastedImageTypes: [UTType] = [.png, .jpeg, .heic, .gif]

    /// An image on the pasteboard (as its own bytes when it is one of the common types).
    static func files(on board: UIPasteboard) -> [IncomingFile] {
        for type in pastedImageTypes {
            if let data = board.data(forPasteboardType: type.identifier) {
                let ext = type.preferredFilenameExtension ?? "png"
                return [IncomingFile(data: data, filename: "Pasted image.\(ext)", mimeType: type.preferredMIMEType)]
            }
        }
        if board.hasImages, let png = board.image?.pngData() {
            return [IncomingFile(data: png, filename: "Pasted image.png", mimeType: "image/png")]
        }
        return []
    }
}

/// Stored properties for the clipboard (extensions can't add them).
final class ClipboardHooks {
    var transformPasted: ((Slice) -> Slice)?
    var adoptPasted: ((Slice, PasteOrigin) -> Slice)?
}
#endif
