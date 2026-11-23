#if canImport(UIKit) && !os(macOS)
import UIKit
import PMModel
import PMTransform
import PMState

/// A TextKit 2 `UITextView` driven by an `EditorState`: the iOS twin of the AppKit view.
///
/// The text storage is a projection of the document (`DocRenderer`, shared with macOS). UIKit's
/// own text input edits it (typing, autocorrect, predictions, marked text, dictation, the
/// selection handles and edit menu), and every edit inside one paragraph is read back into a
/// transaction, as prosemirror-view reads back DOM changes. Edits that would cross paragraphs
/// or touch block leaves, Return, Backspace at a paragraph start and Tab become transactions
/// through the keymaps instead. The `EditorState` is always the truth: after each change the
/// renderer writes only the text and attributes that differ, and the selection is mapped back.
///
/// The view is its own `UITextView.delegate` (it needs `shouldChangeTextIn` and the change
/// callbacks); use `onChange` rather than setting a delegate.
public final class ProseTextView: UITextView, EditorView, EditorCoreObserver, NSTextLayoutManagerDelegate {
    /// The state this view shows, owned by `core` (which other views may share).
    public var state: EditorState { core.state }
    public let core: EditorCore
    public let renderer: DocRenderer
    /// Called after every state change, with the transaction that caused it (nil for `setState`).
    public var onChange: ((EditorState, Transaction?) -> Void)?
    /// Called when a command reports an error (an exception in JS).
    public var onError: ((Error) -> Void)?

    var syncingSelection = false
    /// Set while UIKit changes marked text: let it through without tracking or read-back.
    var allowNativeEdit = false
    /// The next typed text starts a new undo step, so a correction stays its own step.
    var closeHistoryOnNextInput = false
    /// Applied to edits that should be their own undo step (autocorrect, chrome buttons).
    /// Set it to prosemirror-history's `closeHistory`.
    public var separateUndoStep: ((Transaction) -> Transaction)?
    public var composing: Bool { markedTextRange != nil }
    /// Called when a composition ends, before its text is applied. Dispatching while
    /// `composing` would re-render over the marked text, so hold changes until then.
    public var onCompositionEnd: (() -> Void)?

    /// A paragraph UIKit is editing, as it was before the first change.
    struct NativeEdit {
        var span: ParagraphSpan
        var before: [UInt16]
        /// The caret before the edit, relative to the paragraph; settles ambiguous diffs.
        var caret: Int
        /// Typed text (an undo step of its own only after a correction), not a correction.
        var typed: Bool
        /// Marked text was involved: other changes waiting for the composition go first.
        var composed = false
    }
    var nativeEdit: NativeEdit?
    /// Set while UIKit inserts typed text; the first edit it makes is the typing.
    var insertingTyped = false
    /// A finished composition's change, mapped through changes `onCompositionEnd` applies first.
    var heldChange: (from: Int, to: Int, text: String, anchor: Int, head: Int)?
    /// The hardware key being handled by `pressesBegan`, so the text it inserts (Return) or
    /// deletes (Backspace) doesn't run the same keymap binding a second time.
    var keyTriedByPress: String?
    /// Modifiers held on a hardware keyboard (Shift-Return).
    var heldModifiers: UIKeyModifierFlags = []

    /// Formatting shortcuts shown in the iPad ⌘-hold overlay and menu bar (see `keyCommands`).
    public var shortcutCommands: [ShortcutCommand] = [] {
        didSet { if shortcutCommands != oldValue { UIMenuSystem.main.setNeedsRebuild() } }
    }

    let chromeState = ChromeState()
    let decorations = DecorationView()
    let chromeControls = UIChromeControls()
    let cardControlState = CardControlState()
    /// A long press on a card's control area shows the card menu (`cardMenu(at:)`).
    lazy var cardLongPress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(cardLongPressed(_:)))
        press.delegate = cardMenuGate
        return press
    }()
    lazy var cardMenuGate = CardMenuGate(self)
    lazy var cardMenuInteraction = UIEditMenuInteraction(delegate: cardMenuGate)
    /// The iPad pointer's hover look on cards and checkboxes.
    lazy var pointerHover: UIHoverGestureRecognizer = {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(pointerHovered(_:)))
        hover.delegate = hoverGate
        return hover
    }()
    private let hoverGate = HoverGate()
    private var chromeLink: CADisplayLink?
    private var lastChromeTick: CFTimeInterval = 0
    /// Animate chrome expanding and collapsing (off in tests).
    public var animatesChrome: Bool {
        get { chromeState.animates }
        set { chromeState.animates = newValue }
    }

    /// Undo and redo (keyboard shortcuts, shake, the shortcuts bar) run these; the history
    /// plugin owns undo. UIKit's own undo registration is turned off.
    public var undoCommand: Command?
    public var redoCommand: Command?
    private lazy var historyUndoManager = HistoryUndoManager(self)

    /// Text changes UIKit made without asking the gate, undone by re-rendering (for tests and
    /// diagnostics; expected to stay 0).
    public internal(set) var untrackedEdits = 0
    var customPasteboard: UIPasteboard?
    let clipboardHooks = ClipboardHooks()

    /// Called first on paste (after any composition is committed), with the view's pasteboard;
    /// return true to take the paste (HTML or Markdown from another app).
    public var onPaste: ((UIPasteboard) -> Bool)?
    /// The plain text a copied selection puts on the clipboard (prosemirror-view's
    /// clipboardTextSerializer); nil keeps the text as shown.
    public var clipboardText: ((Slice) -> String)?
    /// Files dropped or pasted (images included), and the document position they go at. Return
    /// true to take them (the app uploads them and inserts blocks); false lets text paste as usual.
    public var onIncomingFiles: (([IncomingFile], Int) -> Bool)?
    /// The edit menu's Link… item; the app shows its link sheet. No item while nil.
    public var onEditLink: (() -> Void)?
    /// Items appended to the edit menu (for example a "Turn Into" submenu).
    public var extraMenuItems: ((EditorState) -> [UIMenuElement])?

    /// Called when a checkbox marker is tapped, with the document position of the paragraph's
    /// content start. Return true if handled.
    public var onMarkerClick: ((Int) -> Bool)?
    /// A pill in a chrome box's strip was tapped (or chosen with VoiceOver). Nil: pills are only
    /// drawn, and taps on them place the caret as anywhere else.
    public var onChromePillTap: ((ChromePillHit) -> Void)?
    /// Whether pills take taps now (a read-only note's don't). Asked on every hit test.
    public var chromePillsEnabled: () -> Bool = { true }
    /// A native menu for a pill, opened in place by a button over it (`PillMenus+UIKit.swift`);
    /// nil for a pill that is tapped (`onChromePillTap`). Asked when a pill's button is made and
    /// again each time the menu opens.
    public var chromePillMenu: ((ChromePillHit) -> UIMenu?)? {
        didSet { layoutPillMenus(force: true) }
    }
    /// The pill tap (internal for tests).
    lazy var pillTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = pillTapGate
        return tap
    }()
    private lazy var pillTapGate = PillTapGate(self)

    /// Blocks that text mustn't replace while node-selected (on iOS, tables: they can't be made
    /// again here). Typing, a correction, dictation or a composition over such a selection does
    /// nothing; Backspace, Delete, cut and paste still replace or remove it, on purpose.
    public var keepsSelectedNode: ((Node) -> Bool)?

    /// Whether `text` would replace a node-selected block that `keepsSelectedNode` keeps.
    func keepsSelection(from text: String) -> Bool {
        guard !text.isEmpty, let keeps = keepsSelectedNode, let selection = state.selection as? NodeSelection else { return false }
        return keeps(selection.node)
    }

    // Suggestion menus (see Suggestions.swift). The app shows `suggestionState`.
    /// Characters that open a suggestion menu (a slash command menu, mentions), one each.
    public var suggestionTriggers: [SuggestionTrigger] = [] {
        didSet {
            closeSuggestions()
            suggestionControllers = suggestionTriggers.map { SuggestionController(trigger: $0, view: self) }
        }
    }
    var suggestionControllers: [SuggestionController] = []
    /// The text being typed (insertText), while its change is applied: suggestion menus open
    /// only on a typed trigger, not when the caret moves next to one.
    var typedText: String?
    private var loadedSuggestionState: SuggestionState?
    /// The open suggestion menu, for the app to show (a list above the keyboard).
    public var suggestionState: SuggestionState {
        if let loadedSuggestionState { return loadedSuggestionState }
        let state = SuggestionState(view: self)
        loadedSuggestionState = state
        return state
    }

    /// A suggestion controller opened, closed, filtered or moved its selection.
    func suggestionsDidChange() { loadedSuggestionState?.refresh() }

    public convenience init(state: EditorState, style: DocStyle) {
        self.init(core: EditorCore(state: state), style: style)
    }

    public init(core: EditorCore, style: DocStyle) {
        self.core = core
        renderer = DocRenderer(style: style)
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        layoutManager.delegate = self
        delegate = self

        allowsEditingTextAttributes = false
        smartInsertDeleteType = .no
        // Data detectors would add link attributes of their own; links come from the document.
        dataDetectorTypes = []
        textDragInteraction?.isEnabled = false
        installDropInteraction()
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        // No iPad shortcuts bar (undo/redo, B/I/U): the app has a formatting bar of its own.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        backgroundColor = .systemBackground
        textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        insertSubview(decorations, at: 0)
        decorations.host = self

        renderer.chromeProgress = { [chromeState] in chromeState.progress($0) }
        renderer.chromeOpen = { [chromeState] in chromeState.isOpen($0) }
        renderer.runOpen = { [weak self] from, to, edges in self?.isRunOpen(from: from, to: to, opensAtEdges: edges) ?? false }
        chromeState.setActive(activeChromePos(core.state))
        chromeState.snap()
        seedStripWidth()
        renderer.update(textStorage, to: core.state.doc, force: true)
        syncSelectionToView()
        core.addObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var undoManager: UndoManager? { historyUndoManager }

    /// Whether a collapsible run shows as text: while the whole selection is in it.
    func isRunOpen(from: Int, to: Int, opensAtEdges: Bool) -> Bool {
        let sel = state.selection
        if sel is AllSelection || sel.from < from || sel.to > to { return false }
        return opensAtEdges || !(sel.empty && (sel.from == from || sel.from == to))
    }

    /// Typing just after a collapsed run (a chip) would take its hidden characters' look,
    /// leaving marked text invisible: it takes the run's paragraph attributes instead (as on
    /// macOS). UIKit keeps its typing attributes without the setter (and drops the renderer's
    /// key), so the character before the caret is looked at here.
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get {
            let location = selectedRange.location
            if location > 0, location <= textStorage.length,
               let base = textStorage.attribute(.pmCollapsedRun, at: location - 1, effectiveRange: nil) as? [NSAttributedString.Key: Any] {
                return base
            }
            return super.typingAttributes
        }
        set { super.typingAttributes = newValue }
    }

    /// Restyle the whole document in place (another theme or text size).
    public func setStyle(_ style: DocStyle) {
        commitComposition()
        renderer.style = style
        syncingSelection = true
        renderer.update(textStorage, to: state.doc, force: true)
        syncingSelection = false
        syncSelectionToView()
        decorations.setNeedsDisplay()
    }

    // MARK: State

    /// Replace the whole state (e.g. loading another document).
    public func setState(_ newState: EditorState) { core.setState(newState) }

    public func dispatch(_ tr: Transaction) { core.dispatch(tr) }

    public func coreDidUpdate(_ core: EditorCore, _ tr: Transaction?) {
        if let tr { didApply(tr) } else { didReplaceState() }
    }

    private func didReplaceState() {
        closeSuggestions()
        chromeState.reset()
        chromeState.setActive(activeChromePos(state))
        chromeState.snap()
        seedStripWidth()
        syncingSelection = true
        renderer.update(textStorage, to: state.doc, force: true)
        syncingSelection = false
        syncSelectionToView()
        decorations.setNeedsDisplay()
        layoutChromeControls()
        onChange?(state, nil)
    }

    private func didApply(_ tr: Transaction) {
        if tr.docChanged {
            chromeState.map(tr.mapping, isChrome: isChromeNode(at:))
            if let held = heldChange {
                heldChange = (tr.mapping.map(held.from), tr.mapping.map(held.to), held.text,
                              tr.mapping.map(held.anchor), tr.mapping.map(held.head))
            }
        }
        let active = activeChromePos(state)
        if active != chromeState.activePos { chromeState.setActive(active) }
        // UIKit moves the selection as the text is replaced; that isn't the user's.
        let wasSyncing = syncingSelection
        syncingSelection = true
        renderer.update(textStorage, to: state.doc)
        renderer.refreshChrome(textStorage)
        syncingSelection = wasSyncing
        syncSelectionToView()
        startChromeAnimation()
        startCheckAnimations()
        decorations.setNeedsDisplay()
        layoutChromeControls()
        layoutPillMenus(force: true)
        if tr.scrolledIntoView || tr.docChanged { scrollToSelection() }
        for suggestion in suggestionControllers { suggestion.stateDidChange(tr, typed: typedText) }
        onChange?(state, tr)
    }

    /// Run a command against the current state; returns whether it applied. An open
    /// composition is committed first, so the command sees (and can't redraw over) its text.
    @discardableResult
    public func run(_ command: Command) -> Bool {
        commitComposition()
        let errors = CommandErrors.errorCount
        let result = command(state, dispatch, self)
        reportErrors(since: errors)
        return result
    }

    func reportErrors(since count: Int) {
        if CommandErrors.errorCount != count, let error = CommandErrors.last { onError?(error) }
    }

    /// Scroll the selection into view once TextKit has laid it out.
    public func scrollToSelection() {
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            if let rect = headRect() {
                scrollRectToVisible(rect.insetBy(dx: 0, dy: -8), animated: false)
            } else {
                scrollRangeToVisible(selectedRange)
            }
        }
    }

    /// Caret rect at the selection head, in view (content) coordinates, after laying it out.
    public func headRect() -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let range = selectedRange
        let offset = state.selection.head == state.selection.from ? range.location : range.upperBound
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
        let textRange = NSTextRange(location: loc)
        tlm.ensureLayout(for: textRange)
        var rect: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r
            return false
        }
        return rect.map { $0.offsetBy(dx: hostContainerOrigin.x, dy: hostContainerOrigin.y) }
    }

    // MARK: Chrome

    private func startChromeAnimation() {
        guard !chromeState.settled, chromeLink == nil else { return }
        let link = CADisplayLink(target: ChromeTicker(self), selector: #selector(ChromeTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        chromeLink = link
        lastChromeTick = 0
    }

    fileprivate func chromeTick(_ link: CADisplayLink) {
        let dt = lastChromeTick == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastChromeTick
        lastChromeTick = link.timestamp
        chromeState.step(dt)
        if markedTextRange == nil {
            syncingSelection = true
            renderer.refreshChrome(textStorage)
            syncingSelection = false
            if renderer.refreshChangedText { syncSelectionToView() }
        }
        decorations.setNeedsDisplay()
        layoutChromeControls()
        guard chromeState.settled else { return }
        link.invalidate()
        chromeLink = nil
    }

    /// Frame of the box drawn around the chrome node at `pos` (content coordinates), for tests.
    public func chromeFrame(at pos: Int) -> CGRect? {
        guard let region = renderer.chromes.first(where: { $0.pos == pos }) else { return nil }
        ensureLayout(for: region)
        return chromeRect(region)
    }

    // MARK: Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A change of geometry moves what the decorations draw: redraw them all. (Content and
        // state changes redraw through `decorations.setNeedsDisplay()` where they happen.)
        let geometry = DecorationView.Geometry(width: bounds.width, inset: textContainerInset)
        if geometry != decorations.geometry {
            decorations.geometry = geometry
            decorations.setNeedsDisplay()
        }
        // Tiles cover what's visible plus a margin, in content coordinates; scrolling draws
        // only the tiles coming into that area, and a tile whose text TextKit has since moved
        // (laying out estimated paragraphs above it) draws again.
        decorations.cover(CGRect(origin: contentOffset, size: bounds.size).insetBy(dx: 0, dy: -bounds.height * 0.25),
                          contentHeight: contentSize.height)
        if subviews.first !== decorations { sendSubviewToBack(decorations) }
        syncStripWidth()
        layoutChromeControls()
        layoutPillMenus()
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        decorations.setNeedsDisplay()
    }

    // MARK: Selection mapping

    func syncSelectionToView() {
        let sel = state.selection
        let from = renderer.stringOffset(sel.from, bias: 1)
        let to = max(from, renderer.stringOffset(sel.to, bias: -1))
        let range = NSRange(location: from, length: to - from)
        guard selectedRange != range else { return }
        syncingSelection = true
        selectedRange = range
        syncingSelection = false
    }

    /// The view's selection changed (a tap, a handle drag, arrow keys): make it the state's.
    func viewSelectionChanged() {
        // Mid-edit the renderer's spans are stale; readBack sets the selection.
        guard !syncingSelection, markedTextRange == nil, nativeEdit == nil, renderer.doc === state.doc else { return }
        let sel = selection(for: selectedRange)
        if sel.eq(state.selection) { return }
        dispatch(state.tr.setSelection(sel))
    }

    // MARK: EditorView

    public func endOfTextblock(_ dir: String, _ state: EditorState?) -> Bool {
        let head = (state ?? self.state).selection.headPos
        if !head.parent.inlineContent { return true }
        if dir == "backward" || dir == "left" || dir == "up" { return head.parentOffset == 0 }
        return head.parentOffset == head.parent.content.size
    }

    /// A key press, as from a hardware keyboard: an open suggestion menu first (↑/↓, Return,
    /// Tab, Escape), then the keymaps. Returns whether something handled it.
    @discardableResult
    public func handleKey(_ event: KeyEvent) -> Bool {
        commitComposition()
        return handleKeyDown(event)
    }

    func handleKeyDown(_ event: KeyEvent) -> Bool {
        let errors = CommandErrors.errorCount
        defer { reportErrors(since: errors) }
        // An open suggestion menu takes its keys before the keymaps, as on macOS.
        if markedTextRange == nil, let suggestion = activeSuggestion, suggestion.handleKey(event) { return true }
        for p in state.plugins {
            if let f = p.props.handleKeyDown, f(self, event) { return true }
        }
        return false
    }

    func handleTextInput(_ from: Int, _ to: Int, _ text: String) -> Bool {
        let errors = CommandErrors.errorCount
        defer { reportErrors(since: errors) }
        for p in state.plugins {
            if let f = p.props.handleTextInput, f(self, from, to, text) { return true }
        }
        return false
    }

    // MARK: Taps

    /// A tap on a checkbox toggles it rather than placing the caret.
    public override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer is UITapGestureRecognizer || recognizer is UILongPressGestureRecognizer, recognizer !== pillTap,
           tappablePill(at: recognizer.location(in: self)) != nil {
            // A pill is a button: `pillTap` takes it. No other tap places the caret there, and no
            // long press brings up the loupe, a selection or the card menu.
            return false
        }
        if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1, onMarkerClick != nil,
           let offset = markerOffset(at: recognizer.location(in: self)) {
            // Handled on touch up by `markerTap`; keep UIKit's caret placement out of it.
            pendingMarkerOffset = offset
            return false
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    /// Whether `point` (content coordinates) is in a tappable checkbox's touch target: the marker
    /// tap's alone (other gestures, such as a link's, stay out of it).
    public func isOnMarker(_ point: CGPoint) -> Bool {
        onMarkerClick != nil && markerOffset(at: point) != nil
    }

    /// Whether `point` is on a card's control area (the card long press's alone).
    public func isOnCardControl(_ point: CGPoint) -> Bool {
        cardMenuTarget(at: point) != nil
    }

    private var pendingMarkerOffset: Int?
    /// The checkbox tap (internal for tests).
    lazy var markerTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(markerTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = markerTapGate
        return tap
    }()

    /// Lets the marker tap begin only on a marker. Recognizing every tap, it made UIKit's text
    /// single-tap fail (two taps on one view don't recognize together), so a tap never placed
    /// the caret or brought up the keyboard.
    private lazy var markerTapGate = MarkerTapGate(self)

    private final class MarkerTapGate: NSObject, UIGestureRecognizerDelegate {
        weak var view: ProseTextView?
        init(_ view: ProseTextView) { self.view = view }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let view, view.onMarkerClick != nil else { return false }
                return view.markerOffset(at: recognizer.location(in: view)) != nil
            }
        }

        /// Only touches on a checkbox: elsewhere UIKit's taps don't wait for this one.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            MainActor.assumeIsolated {
                guard let view else { return false }
                return view.isOnMarker(touch.location(in: view))
            }
        }

        /// On a checkbox, UIKit's text taps (caret placement, word selection) wait for this tap
        /// to fail, so a tap that toggles never also moves the caret or raises the keyboard.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view === recognizer.view && other is UITapGestureRecognizer
        }
    }

    /// Losing focus closes an open suggestion menu, as on macOS.
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { closeSuggestions() }
        return ok
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { closeSuggestions() }
        if markerTap.view == nil { addGestureRecognizer(markerTap) }
        if pillTap.view == nil { addGestureRecognizer(pillTap) }
        installCardGestures()
    }

    @objc func markerTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let offset = markerOffset(at: tap.location(in: self)) else { return }
        pendingMarkerOffset = nil
        tapMarker(atString: offset)
    }

    /// Toggle the checkbox drawn for the paragraph at string offset `offset`, as a tap would.
    @discardableResult
    public func tapMarker(atString offset: Int) -> Bool {
        guard let (pos, _) = renderer.docPosition(offset) else { return false }
        return onMarkerClick?(pos) ?? false
    }

    /// Content-space rect of the checkbox drawn for the paragraph at string offset `offset` (for tests).
    public func checkboxRect(atString offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: offset),
              case _ = tlm.ensureLayout(for: NSTextRange(location: loc)),
              let fragment = tlm.textLayoutFragment(for: loc) as? BlockLayoutFragment,
              let r = fragment.checkboxRect(lineStart: textContainer.lineFragmentPadding) else { return nil }
        return r.offsetBy(dx: hostContainerOrigin.x, dy: hostContainerOrigin.y)
    }

    // MARK: NSTextLayoutManagerDelegate

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.host = self
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            fragment.decoration = paragraph.attributedString.attribute(.pmBlock, at: 0, effectiveRange: nil) as? BlockDecoration
        }
        return fragment
    }
}

extension ProseTextView: ProseViewHost, FragmentHost {
    var hostLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var hostContentManager: NSTextContentManager? { textLayoutManager?.textContentManager }
    var hostTextContainer: NSTextContainer? { textContainer }
    var hostContainerOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }
    func chromeHoverLevel(_ pos: Int) -> CGFloat { cardControlState.chromeHover.level(pos) }
    /// No pointer highlight on pills on iOS (the iPad pointer's card hover still shows).
    func hoveredPill(_ pos: Int) -> Int? { nil }
    /// Focus dimming isn't on iOS yet.
    public func focusAlpha(atString offset: Int) -> CGFloat { 1 }
}

/// Behind the text: chrome boxes and paragraph decorations (list markers, checkboxes, quote
/// bars, code backgrounds), which live in the margins where TextKit's fragment views clip.
///
/// Drawn in fixed tiles (`tileHeight` tall, in content coordinates) covering what's visible plus
/// a margin. A tile draws once and keeps its drawing while the view scrolls; only a tile
/// coming into the area draws. `setNeedsDisplay()` redraws every tile shown, so the places that
/// change what's drawn (edits, styles, chrome and tick animations, hover, trait and geometry
/// changes) call it as they would on a single view.
final class DecorationView: UIView {
    weak var host: ProseTextView?
    /// Height of a tile, in points.
    static let tileHeight: CGFloat = 512
    /// What the drawing depends on besides content and state; the host compares it on layout.
    struct Geometry: Equatable {
        var width: CGFloat = 0
        var inset: UIEdgeInsets = .zero
    }
    var geometry = Geometry()
    /// Tiles drawn so far (tests count them).
    private(set) var drawCount = 0
    /// Shown tiles by index (tile `i` covers y from `i * tileHeight`).
    private var tiles: [Int: DecorationTile] = [:]
    private var spare: [DecorationTile] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Not an element itself: a container of the pills' VoiceOver buttons (it sits under the
    /// text, in content coordinates, as the pills do).
    override var accessibilityElements: [Any]? {
        get { host?.pillAccessibilityElements() }
        set {}
    }

    /// Show tiles over `area` (content coordinates), reusing the ones already there.
    func cover(_ area: CGRect, contentHeight: CGFloat) {
        let width = geometry.width
        guard width > 0, area.height > 0 else { return }
        let h = Self.tileHeight
        frame = CGRect(x: 0, y: 0, width: width, height: max(contentHeight, area.maxY))
        let first = max(0, Int((area.minY / h).rounded(.down)))
        let last = max(first, Int((area.maxY / h).rounded(.up)) - 1)
        for (index, tile) in tiles where index < first || index > last || tile.frame.width != width {
            tiles[index] = nil
            tile.isHidden = true
            // Dropped tiles keep no drawing (memory); reuse draws them again.
            tile.layer.contents = nil
            if spare.count < 2 { spare.append(tile) } else { tile.removeFromSuperview() }
        }
        for index in first...last where tiles[index] == nil {
            let tile = spare.popLast() ?? DecorationTile()
            tile.owner = self
            tile.frame = CGRect(x: 0, y: CGFloat(index) * h, width: width, height: h)
            tile.isHidden = false
            if tile.superview !== self { addSubview(tile) }
            tile.setNeedsDisplay()
            tiles[index] = tile
        }
        // A drawn tile whose text has moved or changed height since draws again.
        guard let host else { return }
        for tile in tiles.values where !tile.layer.needsDisplay()
            && !tile.anchors.allSatisfy({ host.decorationAnchor(atString: $0.offset) == $0 }) {
            tile.setNeedsDisplay()
        }
    }

    /// Redraw every shown tile.
    override func setNeedsDisplay() {
        for tile in tiles.values { tile.setNeedsDisplay() }
    }

    /// Redraw what the shown tiles have under `rect` (content coordinates) only.
    func setNeedsDisplay(contentRect rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        for tile in tiles.values where tile.frame.intersects(rect) {
            tile.setNeedsDisplay(rect.intersection(tile.frame).offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
        }
    }

    fileprivate func draw(_ tile: DecorationTile, _ rect: CGRect) {
        guard let host, let ctx = UIGraphicsGetCurrentContext() else { return }
        drawCount += 1
        ctx.saveGState()
        // Draw in the text view's content coordinates, with the text there laid out first.
        // Deliberate: the tile keeps this drawing while it scrolls, so it must not be drawn
        // from TextKit's estimated positions (boxes look fragments up without laying them out).
        let area = rect.offsetBy(dx: tile.frame.minX, dy: tile.frame.minY)
        host.ensureLayout(around: area)
        ctx.translateBy(x: -tile.frame.minX, y: -tile.frame.minY)
        host.drawDecorations(in: area)
        ctx.restoreGState()
        // Where the text at the tile's top and bottom edges was laid out when it drew (the
        // note's last paragraph for an edge past the end): a move or a change of height there
        // means the drawing is out of date.
        var anchors: [DecorationAnchor] = []
        for y in [tile.frame.minY, tile.frame.maxY] {
            if let anchor = host.decorationAnchor(atY: y) ?? host.lastDecorationAnchor(), !anchors.contains(anchor) {
                anchors.append(anchor)
            }
        }
        tile.anchors = anchors
    }
}

/// A layout fragment (by the string offset it starts at) and its vertical extent.
struct DecorationAnchor: Equatable {
    var offset: Int
    var minY: CGFloat
    var maxY: CGFloat
}

/// One tile of the decorations; `DecorationView` places it and draws into it.
final class DecorationTile: UIView {
    weak var owner: DecorationView?
    /// The layout fragments at the tile's edges as they were when it drew.
    var anchors: [DecorationAnchor] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) { owner?.draw(self, rect) }
}

/// Routes undo and redo to the history plugin. UIKit's text view registers its own undo
/// actions for the edits it makes; registration is off, since every edit is a transaction.
final class HistoryUndoManager: UndoManager {
    private weak var view: ProseTextView?

    init(_ view: ProseTextView) {
        self.view = view
        super.init()
        disableUndoRegistration()
    }

    override var canUndo: Bool {
        guard let view, let command = view.undoCommand else { return false }
        return MainActor.assumeIsolated { command(view.state, nil, view) }
    }

    override var canRedo: Bool {
        guard let view, let command = view.redoCommand else { return false }
        return MainActor.assumeIsolated { command(view.state, nil, view) }
    }

    override func undo() {
        guard let view, let command = view.undoCommand else { return }
        MainActor.assumeIsolated { _ = view.run(command) }
    }

    override func redo() {
        guard let view, let command = view.redoCommand else { return }
        MainActor.assumeIsolated { _ = view.run(command) }
    }
}

/// CADisplayLink retains its target; this breaks the cycle with the view.
private final class ChromeTicker: NSObject {
    weak var view: ProseTextView?
    init(_ view: ProseTextView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        MainActor.assumeIsolated { view.chromeTick(link) }
    }
}

extension ProseTextView {
    /// Lay out the text in and around `rect` (content coordinates; boxes and shadows reach a
    /// little past their text).
    func ensureLayout(around rect: CGRect) {
        guard let tlm = textLayoutManager else { return }
        let origin = hostContainerOrigin
        tlm.ensureLayout(for: rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -64))
    }

    /// The layout fragment at `y` (content coordinates), or nil past the text.
    func decorationAnchor(atY y: CGFloat) -> DecorationAnchor? {
        guard let tlm = textLayoutManager else { return nil }
        let origin = hostContainerOrigin
        return tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y - origin.y))).map { anchor(tlm, $0) }
    }

    /// The layout fragment starting at string offset `offset`, as laid out now.
    func decorationAnchor(atString offset: Int) -> DecorationAnchor? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
        return tlm.textLayoutFragment(for: location).map { anchor(tlm, $0) }
    }

    /// The note's last layout fragment.
    func lastDecorationAnchor() -> DecorationAnchor? {
        guard let tlm = textLayoutManager else { return nil }
        var last: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse]) { fragment in
            last = fragment
            return false
        }
        return last.map { anchor(tlm, $0) }
    }

    private func anchor(_ tlm: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) -> DecorationAnchor {
        let frame = fragment.layoutFragmentFrame
        return DecorationAnchor(offset: tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location),
                                minY: frame.minY, maxY: frame.maxY)
    }

    /// Something outside the editor's own edits changed the layout (an image's size arrived, a
    /// link preview's title): redraw the decorations.
    public func layoutChangedOutsideEdits() {
        decorations.setNeedsDisplay()
        setNeedsLayout()
    }

    /// Where the paragraph at string offset `offset` draws its decorations (content coordinates,
    /// the view's full width), with a little room for a checkbox's or box's edge.
    func decorationRect(ofParagraphAtString offset: Int) -> CGRect? {
        guard let anchor = decorationAnchor(atString: offset) else { return nil }
        let origin = hostContainerOrigin
        return CGRect(x: 0, y: origin.y + anchor.minY, width: bounds.width, height: anchor.maxY - anchor.minY).insetBy(dx: 0, dy: -6)
    }

    /// Where the chrome box of the node at `pos` draws, with its shadow and ring.
    func decorationRect(ofChromeAt pos: Int) -> CGRect? {
        guard let region = renderer.chromes.first(where: { $0.pos == pos }), let rect = chromeRect(region) else { return nil }
        return rect.insetBy(dx: -renderer.chromeReach, dy: -renderer.chromeReach)
    }

    /// Chrome boxes, then paragraph decorations, for everything intersecting `rect` (content
    /// coordinates), into the current context. Checkboxes draw at their tick's scale and hover.
    func drawDecorations(in rect: CGRect) {
        drawChromeBoxes(in: rect)
        guard let tlm = hostLayoutManager, let container = hostTextContainer else { return }
        let origin = hostContainerOrigin
        let padding = container.lineFragmentPadding
        let width = container.size.width - 2 * padding
        let top = CGPoint(x: 0, y: max(0, rect.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            if fragment.layoutFragmentFrame.minY + origin.y > rect.maxY { return false }
            guard let block = fragment as? BlockLayoutFragment, block.decoration != nil else { return true }
            let offset = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
            block.drawDecoration(origin: origin, lineStart: padding, lineWidth: width,
                                 checkScale: checkAnimation(atString: offset)?.scale ?? 1, hover: markerHoverLevel(atString: offset))
            return true
        }
    }
}
#endif
