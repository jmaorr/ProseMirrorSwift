#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import PMModel
import PMTransform
import PMState

/// A TextKit 2 text view driven by an `EditorState`.
///
/// The text storage is a projection of the document (see `DocRenderer`). Keys go
/// through the state's keymap plugins first, the way prosemirror-view does. Edits
/// inside one paragraph (typing, deleting, autocorrect, IME, predictions) are made
/// by AppKit and read back into a transaction, as prosemirror-view reads back DOM
/// changes; anything else becomes a transaction directly. Each new state is
/// rendered, writing only the text and attributes that differ, and its selection
/// mapped back.
public final class ProseTextView: NSTextView, EditorView, EditorCoreObserver, NSTextLayoutManagerDelegate {
    /// The state this view shows, owned by `core` (which other views may share).
    public var state: EditorState { core.state }
    public let core: EditorCore
    public let renderer: DocRenderer
    /// Called after every state change, with the transaction that caused it (nil for `setState`).
    public var onChange: ((EditorState, Transaction?) -> Void)?
    /// Called when a command reports an error (an exception in JS).
    public var onError: ((Error) -> Void)?

    var syncingSelection = false
    /// Set while AppKit changes marked text: let it through without tracking or read-back.
    var allowNativeEdit = false
    /// The next typed text starts a new undo step, so a correction stays its own step.
    var closeHistoryOnNextInput = false
    /// Applied to edits that should be their own undo step: autocorrect / text replacement /
    /// smart punctuation, and chrome control presses. Set it to prosemirror-history's
    /// `closeHistory`.
    public var separateUndoStep: ((Transaction) -> Transaction)?
    public var composing: Bool { hasMarkedText() }
    /// Called when a composition (IME, inline prediction) ends, before its text is applied.
    /// Dispatching while `composing` would re-render over the marked text, so hold changes
    /// until then and dispatch them here.
    public var onCompositionEnd: (() -> Void)?

    // Native text input state (see ProseTextView+Input.swift).
    /// A paragraph AppKit is editing, as it was before the first change.
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
    /// Set while AppKit inserts typed text; the first edit it makes is the typing.
    var insertingTyped = false
    /// A finished composition's change, mapped through changes `onCompositionEnd` applies first.
    var heldChange: (from: Int, to: Int, text: String, anchor: Int, head: Int)?
    /// The text being typed (insertText), while its change is applied: suggestion menus open
    /// only on a typed trigger, not when the caret moves next to one.
    var typedText: String?

    // Suggestion menus (see Suggestions.swift).
    /// Characters that open a suggestion menu (a slash command menu, mentions), one each.
    public var suggestionTriggers: [SuggestionTrigger] = [] {
        didSet {
            closeSuggestions()
            suggestionControllers = suggestionTriggers.map { SuggestionController(trigger: $0, view: self) }
        }
    }
    var suggestionControllers: [SuggestionController] = []
    /// The selected row's fill in suggestion menus (a theme's accent).
    public var suggestionAccentColor: NSColor = .controlAccentColor

    let chromeState = ChromeState()
    let chromeControls = ChromeControls()
    private var chromeLink: AnyObject?
    private var lastChromeTick: CFTimeInterval = 0
    /// Animate chrome expanding and collapsing (off in tests, where it would need a display).
    public var animatesChrome: Bool {
        get { chromeState.animates }
        set { chromeState.animates = newValue }
    }

    public convenience init(state: EditorState, style: DocStyle) {
        self.init(core: EditorCore(state: state), style: style)
    }

    /// A view of `core`'s state; dispatching from any view sharing the core updates them all.
    /// With `scope` (the position before a container node, such as a table cell) the view shows
    /// and edits only that node's content.
    public init(core: EditorCore, style: DocStyle, scope: Int? = nil) {
        self.core = core
        storedScope = scope
        let state = core.state
        renderer = DocRenderer(style: style)
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        layoutManager.delegate = self

        isRichText = true
        allowsUndo = false
        importsGraphics = false
        // Spelling, grammar, autocorrect, text replacement and smart punctuation follow the
        // user's system settings and are NSTextView's own (see "Text input").
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
        isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        unregisterDraggedTypes()
        // Note content (moved or copied within the app), text, and files (see onIncomingFiles).
        registerForDraggedTypes([Self.sliceType, .string, .fileURL, .png, .tiff])

        renderer.chromeProgress = { [chromeState] in chromeState.progress($0) }
        renderer.chromeOpen = { [weak self, chromeState] in (self?.showsCollapsedText ?? false) || chromeState.isOpen($0) }
        renderer.runOpen = { [weak self] from, to, edges in self?.isRunOpen(from: from, to: to, opensAtEdges: edges) ?? false }
        chromeState.setActive(activeChromePos(state))
        chromeState.snap()
        seedStripWidth()
        renderer.update(textStorage!, to: state.doc, scope: scope, force: true)
        syncSelectionToView()
        core.addObserver(self)
    }

    // MARK: Find

    /// While the find bar shows, collapsed nodes show their text, so Find sees it.
    public private(set) var showsCollapsedText = false
    private var findBarObservation: NSKeyValueObservation?

    public override func performTextFinderAction(_ sender: Any?) {
        // Before the finder reads the text.
        if (sender as? NSValidatedUserInterfaceItem)?.tag != NSTextFinder.Action.hideFindInterface.rawValue {
            setShowsCollapsedText(true)
        }
        super.performTextFinderAction(sender)
        setShowsCollapsedText(enclosingScrollView?.isFindBarVisible ?? false)
    }

    public override func performFindPanelAction(_ sender: Any?) {
        setShowsCollapsedText(true)
        super.performFindPanelAction(sender)
        setShowsCollapsedText(enclosingScrollView?.isFindBarVisible ?? false)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeSuggestions() }
        // The bar's Done button and Escape close it without going through the text view.
        findBarObservation = enclosingScrollView?.observe(\.isFindBarVisible, options: [.new]) { [weak self] scroll, _ in
            let visible = scroll.isFindBarVisible
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setShowsCollapsedText(visible) } }
        }
    }

    /// Typing just after a collapsed run (a chip) would take its hidden characters' look,
    /// leaving marked text invisible: it takes the run's paragraph attributes instead.
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            if let base = newValue[.pmCollapsedRun] as? [NSAttributedString.Key: Any] {
                super.typingAttributes = base
            } else {
                super.typingAttributes = newValue
            }
        }
    }

    /// Whether a collapsible run (`DocStyle.collapsedRuns`) shows as text: while the find bar is
    /// open, or while the whole selection is in it. A caret at either end counts only for a run
    /// that opens at its edges; a selection of exactly the run opens any run.
    func isRunOpen(from: Int, to: Int, opensAtEdges: Bool) -> Bool {
        if showsCollapsedText { return true }
        let sel = state.selection
        if sel is AllSelection || sel.from < from || sel.to > to { return false }
        return opensAtEdges || !(sel.empty && (sel.from == from || sel.from == to))
    }

    /// Show (or stop showing) collapsed nodes' text, as the find bar opens or closes.
    public func setShowsCollapsedText(_ on: Bool) {
        guard on != showsCollapsedText, let storage = textStorage else { return }
        showsCollapsedText = on
        guard !hasMarkedText() else { return }
        syncingSelection = true
        renderer.refreshChrome(storage)
        syncingSelection = false
        syncSelectionToView()
        layoutChromeControls()
        needsDisplay = true
    }

    /// Lay out a range of the text again (an embedded view changed size).
    public func invalidateLayout(forString range: NSRange) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        tlm.invalidateLayout(for: textRange)
        needsLayout = true
        needsDisplay = true
        tlm.textViewportLayoutController.layoutViewport()
    }

    // MARK: Scope

    private var storedScope: Int?
    /// The document the scope was last set for: a scope set for the current document (by an
    /// observer that ran first) is already mapped.
    private var scopeDoc: Node?
    /// Set when the scope node was deleted: the view shows nothing until it gets a new scope.
    private var detached = false

    /// The position before the container node this view shows (a table cell), or nil for the
    /// whole document. Mapped through every change; see `onScopeLost`.
    public var scope: Int? {
        get { storedScope }
        set {
            commitComposition()
            storedScope = newValue
            scopeDoc = state.doc
            detached = false
            // AppKit moves the selection as the text is replaced; that isn't the user's.
            syncingSelection = true
            renderer.update(textStorage!, to: state.doc, scope: newValue, force: true)
            syncingSelection = false
            syncSelectionToView()
            needsDisplay = true
        }
    }

    /// Called when a change deletes the scope node; the view then shows nothing.
    public var onScopeLost: (() -> Void)?

    /// Whether the selection is a text selection inside this view's scope (always, unscoped).
    public var hasSelectionInScope: Bool {
        guard let scope = storedScope, !detached else { return !detached }
        guard state.selection is TextSelection, let node = state.doc.nodeAt(scope) else { return false }
        return state.selection.from >= scope + 1 && state.selection.to <= scope + node.nodeSize - 1
    }

    private func mapScope(_ tr: Transaction) {
        guard let scope = storedScope, !detached, tr.docChanged, scopeDoc !== state.doc else { return }
        let result = tr.mapping.mapResult(scope, assoc: 1)
        if result.deletedAfter || tr.doc.nodeAt(result.pos).map({ $0.isTextblock || $0.isLeaf }) ?? true {
            detached = true
            textStorage?.setAttributedString(NSAttributedString())
            onScopeLost?()
            storedScope = nil
        } else {
            storedScope = result.pos
            scopeDoc = state.doc
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Focus

    let focus = FocusState()
    /// Alpha for top-level blocks the selection doesn't touch; nil turns dimming off.
    public var focusDimming: CGFloat? {
        didSet { updateFocus(); needsDisplay = true }
    }

    // MARK: Ticks

    let checkAnimations = CheckAnimations()
    /// Animate checkboxes as they're ticked and unticked.
    public var animatesChecks = true

    // MARK: Caret

    let caretState = CaretState()
    /// The insertion point's shape. Anything but `.system` is drawn by the view in
    /// `caretColor`, and AppKit's own insertion point is hidden.
    public var caret: TextCaret {
        get { caretState.style }
        set { guard newValue != caretState.style else { return }; caretState.style = newValue; caretStyleChanged() }
    }
    /// The custom caret's colour (also AppKit's insertion point colour with `.system`).
    public var caretColor: NSColor {
        get { caretState.color }
        set {
            caretState.color = newValue
            if caret == .system { insertionPointColor = newValue } else { caretState.savedSystemColor = newValue; updateCaret() }
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateCaret()
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateCaret()
        if ok { closeSuggestions() }
        return ok
    }

    // MARK: Style

    /// A style waiting for a composition to end: re-rendering would replace the marked text.
    private var pendingStyle: DocStyle?

    /// Restyle the whole document in place (another theme, zoom or appearance-independent change).
    public func setStyle(_ style: DocStyle) {
        pendingStyle = style
        applyPendingStyle()
    }

    func applyPendingStyle() {
        guard let style = pendingStyle, !hasMarkedText(), nativeEdit == nil else { return }
        pendingStyle = nil
        renderer.style = style
        guard !detached else { return }
        // AppKit moves the selection as the text is replaced; that isn't the user's.
        syncingSelection = true
        renderer.update(textStorage!, to: state.doc, scope: scope, force: true)
        syncingSelection = false
        syncSelectionToView()
        layoutChromeControls()
        updateFocus()
        needsDisplay = true
    }

    // MARK: State

    /// Replace the whole state (e.g. loading another document).
    public func setState(_ newState: EditorState) { core.setState(newState) }

    public func dispatch(_ tr: Transaction) { core.dispatch(tr) }

    public func coreDidUpdate(_ core: EditorCore, _ tr: Transaction?) {
        if let tr { didApply(tr) } else { didReplaceState() }
        #if DEBUG
        if InputTrace.enabled, tr?.docChanged != false {
            let block = state.selection.fromPos.parent
            InputTrace.note(self, "applied steps=\(tr?.steps.count ?? -1) meta=\(tr?.allMeta.keys.sorted() ?? []) doc=\(block.textContent.debugDescription)")
        }
        #endif
    }

    private func didReplaceState() {
        closeSuggestions()
        chromeState.reset()
        chromeState.setActive(activeChromePos(state))
        chromeState.snap()
        if detached { onChange?(state, nil); return }
        seedStripWidth()
        renderer.update(textStorage!, to: state.doc, scope: scope, force: true)
        syncSelectionToView()
        layoutChromeControls()
        updateFocus()
        onChange?(state, nil)
    }

    private func didApply(_ tr: Transaction) {
        mapScope(tr)
        if detached { onChange?(state, tr); return }
        if tr.docChanged {
            chromeState.map(tr.mapping, isChrome: isChromeNode(at:))
            if let held = heldChange {
                heldChange = (tr.mapping.map(held.from), tr.mapping.map(held.to), held.text,
                              tr.mapping.map(held.anchor), tr.mapping.map(held.head))
            }
        }
        let active = activeChromePos(state)
        if active != chromeState.activePos { chromeState.setActive(active) }
        // A selection-only change can still expand or collapse a node, which replaces its text:
        // AppKit moves the selection as it does, and that isn't the user's.
        let wasSyncing = syncingSelection
        syncingSelection = true
        renderer.update(textStorage!, to: state.doc, scope: scope)
        // A selection-only change can still move which node is active.
        renderer.refreshChrome(textStorage!)
        syncingSelection = wasSyncing
        syncSelectionToView()
        startChromeAnimation()
        startCheckAnimations()
        applyPendingStyle()
        updateFocus()
        layoutChromeControls()
        // Once TextKit has laid the change out.
        if hoveredPillHit != nil || renderer.hasStrips {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshPillHover() } }
        }
        needsDisplay = true
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
            guard let self else { return }
            // TextKit 2's scrollRangeToVisible can leave the view where it is (Enter at the end
            // of a note taller than the window), and the text above the caret only gets its real
            // height once the viewport is laid out there; so scroll to the head's rect, lay out
            // the viewport, and scroll again if that moved it.
            if let rect = headRect() {
                scrollToVisible(rect.insetBy(dx: 0, dy: -4))
                textLayoutManager?.textViewportLayoutController.layoutViewport()
                if let settled = headRect(), settled != rect { scrollToVisible(settled.insetBy(dx: 0, dy: -4)) }
            } else {
                scrollRangeToVisible(selectedRange())
            }
            // NSTextView placed the insertion indicator during the storage edit, using the
            // new line's estimated frame; when that is off, it hides the caret until
            // something (scrolling, typing) makes it recompute. Recompute now.
            updateInsertionPointStateAndRestartTimer(true)
        }
    }

    /// Caret rect at the selection head, in view coordinates, after laying it out.
    public func headRect() -> CGRect? {
        guard let tlm = textLayoutManager, let tcs = textContentStorage else { return nil }
        let range = selectedRange()
        let offset = state.selection.head == state.selection.from ? range.location : range.upperBound
        guard let loc = tcs.location(tcs.documentRange.location, offsetBy: offset) else { return nil }
        let textRange = NSTextRange(location: loc)
        tlm.ensureLayout(for: textRange)
        var rect: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r
            return false
        }
        guard let rect else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Chrome

    private func startChromeAnimation() {
        guard !chromeState.settled, chromeLink == nil else { return }
        if #available(macOS 14, *) {
            let link = displayLink(target: self, selector: #selector(chromeTick(_:)))
            link.add(to: .main, forMode: .common)
            chromeLink = link
            lastChromeTick = 0
        } else {
            chromeState.snap()
            applyChromeFrame()
        }
    }

    @available(macOS 14, *)
    @objc private func chromeTick(_ link: CADisplayLink) {
        let dt = lastChromeTick == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastChromeTick
        lastChromeTick = link.timestamp
        chromeState.step(dt)
        applyChromeFrame()
        guard chromeState.settled else { return }
        link.invalidate()
        chromeLink = nil
        updateInsertionPointStateAndRestartTimer(true)
        // Bring the whole expanded card into view, controls included.
        if let pos = chromeState.activePos, let region = renderer.chromes.first(where: { $0.pos == pos }),
           let rect = chromeRect(region) {
            scrollToVisible(rect.insetBy(dx: 0, dy: -8))
        }
    }

    /// Apply the current animation values: re-style, move controls, redraw.
    func applyChromeFrame() {
        // Re-styling during composition would wipe the marked-text styling; catch up afterwards.
        if !hasMarkedText() {
            syncingSelection = true
            renderer.refreshChrome(textStorage!)
            syncingSelection = false
            // A node finished collapsing into its attachment: its text is gone, so place the caret again.
            if renderer.refreshChangedText { syncSelectionToView() }
        }
        layoutChromeControls()
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(false)
    }

    func layoutChromeControls() {
        let pos = chromeState.activePos
        let region = pos.flatMap { p in renderer.chromes.first { $0.pos == p } }
        let controls = pos.flatMap { state.doc.nodeAt($0) }.map { renderer.style.controls(for: $0) } ?? []
        chromeControls.update(in: self, pos: pos, region: region, controls: controls)
    }

    @objc func chromeControlPressed(_ sender: NSButton) {
        guard let pos = chromeControls.pos, sender.tag < chromeControls.controls.count else { return }
        let control = chromeControls.controls[sender.tag]
        window?.makeFirstResponder(self)
        // A button press is its own undo step, and the next typing starts another.
        closeHistoryOnNextInput = true
        run { state, dispatch, view in
            control.action(pos)(state, dispatch.map { dispatch in { tr in dispatch(self.separateUndoStep?(tr) ?? tr) } }, view)
        }
    }

    public override func layout() {
        super.layout()
        syncStripWidth()
        layoutChromeControls()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncStripWidth()
        // The text rewraps under a selection that hasn't moved; AppKit doesn't re-place ours.
        updateCaret(restartBlink: false)
    }

    /// TextKit is laying the viewport out: a caret placement from inside it (AppKit re-placing
    /// its insertion point) must not start another viewport layout.
    public override func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerWillLayout(controller)
        caretState.viewportLayouts += 1
    }

    /// TextKit has just positioned what is drawn: put the custom caret on it. Whatever placed
    /// the caret before (a selection change, a chrome frame) may have read other frames.
    public override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        // Still inside it (counted from willLayout): read its frames.
        updateCaret(restartBlink: false)
        caretState.viewportLayouts = max(0, caretState.viewportLayouts - 1)
    }

    /// Wherever AppKit's insertion point is re-placed (a chrome frame, the scroll
    /// once TextKit has laid a change out), the custom caret follows.
    public override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        updateCaret(restartBlink: restartFlag)
    }

    /// Views drawn past their superview's bounds, such as a table's grips in the margin. AppKit
    /// only hit-tests inside a view's frame, so these are tried first.
    public let overhangingViews = NSHashTable<NSView>.weakObjects()

    public override func hitTest(_ point: NSPoint) -> NSView? {
        overhangingView(at: point) ?? super.hitTest(point)
    }

    private func overhangingView(at point: NSPoint) -> NSView? {
        overhangingViews.allObjects.first { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0
                && view.bounds.contains(view.convert(point, from: superview))
        }
    }

    /// NSTextView sets the I-beam as the pointer moves; over an overhanging view, that view
    /// sets the cursor instead.
    private func overhangingView(for event: NSEvent) -> NSView? {
        guard let superview else { return nil }
        return overhangingView(at: superview.convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHover(event)
        if setEmbeddedCursor(for: event) { return }
        super.mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        updateHover(nil)
        super.mouseExited(with: event)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.userInfo?["prose.hover"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: ["prose.hover": true]))
        }
    }

    /// Track which checkbox and card the pointer is over; redraw when either changes.
    private func updateHover(_ event: NSEvent?) {
        let marker = event.flatMap { onMarkerClick != nil ? markerOffset(at: $0) : nil }
        var chrome: Int?
        var pill: ChromePillHit?
        if let event {
            let point = convert(event.locationInWindow, from: nil)
            chrome = chromeCandidates(in: CGRect(origin: point, size: .zero)).first { region in
                region.box.activates && chromeRect(region)?.contains(point) == true
            }?.pos
            pill = tappablePill(at: point)
        }
        setHoveredPill(pill)
        guard marker != hoveredMarker || chrome != hoveredChrome else { return }
        hoveredMarker = marker
        hoveredChrome = chrome
        chromeHover.animates = chromeState.animates
        markerHover.animates = chromeState.animates
        chromeHover.set(chrome)
        markerHover.set(marker)
        needsDisplay = true
        startHoverAnimation()
    }

    private func startHoverAnimation() {
        guard !(chromeHover.settled && markerHover.settled), hoverLink == nil else { return }
        if #available(macOS 14, *) {
            let link = displayLink(target: self, selector: #selector(hoverTick(_:)))
            link.add(to: .main, forMode: .common)
            hoverLink = link
            lastHoverTick = 0
        } else {
            _ = stepHoverFades(1)
        }
    }

    @available(macOS 14, *)
    @objc private func hoverTick(_ link: CADisplayLink) {
        let dt = lastHoverTick == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastHoverTick
        lastHoverTick = link.timestamp
        guard !stepHoverFades(dt) else { return }
        link.invalidate()
        hoverLink = nil
    }

    public override func cursorUpdate(with event: NSEvent) {
        if setEmbeddedCursor(for: event) { return }
        super.cursorUpdate(with: event)
    }

    /// An overhanging view, or an embedded view offering a cursor (a table's column border),
    /// sets the cursor in place of the I-beam.
    private func setEmbeddedCursor(for event: NSEvent) -> Bool {
        // Checkboxes, disclosure triangles and strip pills are buttons.
        if onMarkerClick != nil, markerOffset(at: event) != nil {
            NSCursor.pointingHand.set()
            return true
        }
        if tappablePill(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
            return true
        }
        if let view = overhangingView(for: event) {
            view.cursorUpdate(with: event)
            return true
        }
        guard let superview else { return false }
        var view = super.hitTest(superview.convert(event.locationInWindow, from: nil))
        while let current = view, current !== self {
            if let provider = current as? EmbeddedCursorProviding, let cursor = provider.cursor(for: event) {
                cursor.set()
                return true
            }
            view = current.superview
        }
        return false
    }

    /// Frame of the box drawn around the chrome node at `pos`, for tests.
    public func chromeFrame(at pos: Int) -> CGRect? {
        renderer.chromes.first { $0.pos == pos }.flatMap { chromeRect($0) }
    }

    /// The active chrome node and its control buttons, for tests.
    public var activeChrome: (pos: Int, progress: CGFloat, buttons: [String])? {
        guard let pos = chromeState.activePos else { return nil }
        return (pos, chromeState.progress(pos), chromeControls.visibleTitles)
    }

    /// Press the active node's control with this title, as a click would. For tests.
    public func pressChromeControl(_ title: String) {
        chromeControls.button(titled: title)?.performClick(nil)
    }

    // MARK: Decorations

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawChromeBoxes(in: rect)
        guard let tlm = textLayoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let padding = container.lineFragmentPadding
        let width = container.size.width - 2 * padding
        let top = CGPoint(x: 0, y: max(0, rect.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY + origin.y > rect.maxY { return false }
            guard let block = fragment as? BlockLayoutFragment, block.decoration != nil else { return true }
            let offset = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
            let cg = NSGraphicsContext.current?.cgContext
            cg?.saveGState()
            cg?.setAlpha(focusAlpha(atString: offset))
            block.drawDecoration(origin: origin, lineStart: padding, lineWidth: width, checkScale: checkAnimation(atString: offset)?.scale ?? 1,
                                 hover: markerHover.level(offset))
            cg?.restoreGState()
            return true
        }
    }

    // MARK: Selection mapping

    func syncSelectionToView() {
        guard hasSelectionInScope else {
            syncingSelection = true
            setSelectedRange(NSRange(location: 0, length: 0))
            syncingSelection = false
            return
        }
        let sel = state.selection
        let from = renderer.stringOffset(sel.from, bias: 1)
        let to = max(from, renderer.stringOffset(sel.to, bias: -1))
        syncingSelection = true
        setSelectedRange(NSRange(location: from, length: to - from))
        syncingSelection = false
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCaret()
        // Mid-edit the renderer's spans are stale; readBack sets the selection.
        guard !syncingSelection, !stillSelecting, !hasMarkedText(), nativeEdit == nil, renderer.doc === state.doc else { return }
        let sel = selection(for: selectedRange())
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

    func handleKeyDown(_ event: KeyEvent) -> Bool {
        let errors = CommandErrors.errorCount
        defer { reportErrors(since: errors) }
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

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        // An open suggestion menu takes its keys (arrows, Return, Tab, Escape) before keymaps.
        if !hasMarkedText(), let suggestion = activeSuggestion, suggestion.handleKey(KeyEvent(event)) { return }
        if !hasMarkedText(), handleKeyDown(KeyEvent(event)) { return }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText(),
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        if handleKeyDown(KeyEvent(event)) { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func doCommand(by selector: Selector) {
        #if DEBUG
        InputTrace.note(self, "doCommand \(NSStringFromSelector(selector))")
        #endif
        // Keymaps already had their chance in keyDown. Newlines and tabs that no
        // command claimed must not end up as characters in the document.
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)),
             #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)),
             #selector(insertTab(_:)), #selector(insertBacktab(_:)), #selector(insertTabIgnoringFieldEditor(_:)):
            return
        default:
            super.doCommand(by: selector)
        }
    }

    // MARK: Clipboard

    /// Called first on paste (after any composition is committed), with the view's pasteboard;
    /// return true to take the paste (a table pasting cells, text that becomes a table).
    public var onPaste: ((NSPasteboard) -> Bool)?

    /// Items appended to the view's context menu (for example a table's).
    public var extraMenuItems: ((EditorState) -> [NSMenuItem])?

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let items = extraMenuItems?(state), !items.isEmpty else { return menu }
        let out = menu ?? NSMenu()
        out.addItem(.separator())
        for item in items { out.addItem(item) }
        return out
    }

    public override func paste(_ sender: Any?) {
        commitComposition()
        if let onPaste, onPaste(pasteboard) { return }
        // Copied from a note in this app: the exact content (cards, lists, marks).
        if let json = pasteboard.string(forType: Self.sliceType),
           let value = try? JSONValue.parse(json), let parsed = try? Slice.fromJSON(state.schema, value) {
            let slice = preparePasted(parsed, PasteOrigin.forPaste(marker: pasteboard.string(forType: Self.cutMarkerType)))
            run { state, dispatch, _ in
                guard let tr = try? state.tr.replaceSelection(slice) else { return false }
                dispatch?(tr.scrollIntoView())
                return true
            }
            return
        }
        if let onIncomingFiles, case let files = Self.files(on: pasteboard), !files.isEmpty,
           onIncomingFiles(files, state.selection.from) { return }
        pasteAsPlainText(sender)
    }

    // MARK: Copy

    /// The pasteboard type holding a copied selection as ProseMirror slice JSON (pasted back
    /// exactly within the app; other apps get the plain text).
    public static let sliceType = NSPasteboard.PasteboardType("dev.prosemirror-swift.slice")
    static let cutMarkerType = NSPasteboard.PasteboardType(PasteOrigin.cutMarkerType)

    /// Where copy, cut and paste go (the general pasteboard; tests use their own).
    public var pasteboard: NSPasteboard = .general

    /// The plain text a copied selection puts on the clipboard (prosemirror-view's
    /// clipboardTextSerializer); nil keeps the text as shown.
    public var clipboardText: ((Slice) -> String)?

    /// Rewrites a slice pasted from a note before it's inserted (prosemirror-view's
    /// transformPasted); nil inserts it as copied.
    public var transformPasted: ((Slice) -> Slice)?

    /// Rewrites a note's own slice after `transformPasted`, knowing whether it is moved here
    /// (a cut's first paste, a drag that moves) or copied (every other paste and drop): an app
    /// gives copies new identities here. HTML and Markdown from other apps are copies.
    public var adoptPasted: ((Slice, PasteOrigin) -> Slice)?

    /// `slice` through `transformPasted`, then `adoptPasted` with its origin.
    public func preparePasted(_ slice: Slice, _ origin: PasteOrigin) -> Slice {
        let cleaned = transformPasted?(slice) ?? slice
        return adoptPasted?(cleaned, origin) ?? cleaned
    }

    public override func copy(_ sender: Any?) {
        guard !state.selection.empty else { return }
        pasteboard.clearContents()
        writeSelection(to: pasteboard)
    }

    /// The selection as plain text and slice JSON, never the text storage's RTF: that holds the
    /// theme's fonts and colours, which shouldn't travel to other apps or notes.
    @discardableResult
    func writeSelection(to pboard: NSPasteboard) -> Bool {
        guard !state.selection.empty else { return false }
        let slice = state.selection.content()
        pboard.declareTypes([.string, Self.sliceType], owner: nil)
        let text = clipboardText?(slice) ?? slice.content.textBetween(0, slice.content.size, blockSeparator: "\n\n")
        pboard.setString(text, forType: .string)
        pboard.setString(slice.toJSON().description, forType: Self.sliceType)
        return true
    }

    // Dragging text out and Services write through these; AppKit's default writes RTF.
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, Self.sliceType] }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        writeSelection(to: pboard)
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        writeSelection(to: pboard)
    }

    public override func cut(_ sender: Any?) {
        guard !state.selection.empty else { return }
        copy(sender)
        // Its first paste is a move (PasteOrigin).
        pasteboard.addTypes([Self.cutMarkerType], owner: nil)
        pasteboard.setString(PasteOrigin.newCutToken(), forType: Self.cutMarkerType)
        run { state, dispatch, _ in
            guard let tr = try? state.tr.deleteSelection() else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
    }

    // MARK: Files in

    /// A file dropped or pasted onto the note.
    public struct IncomingFile {
        public let data: Data
        public let filename: String
        /// e.g. "image/png"; nil when the type isn't known.
        public let mimeType: String?
        public var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    }

    /// Files dropped or pasted, and the document position they go at. Return true to take them
    /// (the app uploads them and inserts blocks); false lets text paste as usual.
    public var onIncomingFiles: (([IncomingFile], Int) -> Bool)?

    /// The largest file, in bytes, read from a paste or drop for `onIncomingFiles` (100 MB by
    /// default). Larger files are skipped, as is anything that isn't a regular file (a device, a
    /// FIFO, a directory): another app chooses what the pasteboard names.
    public static var maxIncomingFileSize = IncomingFileReader.defaultLimit

    static func files(on pasteboard: NSPasteboard) -> [IncomingFile] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let limit = maxIncomingFileSize
            return urls.compactMap { url in
                guard let data = IncomingFileReader.read(url, limit: limit) else { return nil }
                return IncomingFile(data: data, filename: url.lastPathComponent,
                                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
            }
        }
        // An image on the pasteboard without a file (a screenshot, a copied picture).
        if let png = pasteboard.data(forType: .png) {
            return [IncomingFile(data: png, filename: "Pasted image.png", mimeType: "image/png")]
        }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [IncomingFile(data: png, filename: "Pasted image.png", mimeType: "image/png")]
        }
        return []
    }

    /// Whether `pasteboard` offers files or an image, judged by its types and URLs alone: no
    /// file is read (a drag asks on every mouse move).
    static func hasFiles(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// What a drag would do here: files are copied in; note content dragged within this view
    /// moves (copies with Option held); text or content from elsewhere is copied. Decided from
    /// the pasteboard's types; files are read only when dropped.
    func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        if board.availableType(from: [Self.sliceType, .string]) == nil {
            return onIncomingFiles != nil && Self.hasFiles(on: board) ? .copy : []
        }
        if !isEditable { return [] }
        let fromHere = (sender.draggingSource as AnyObject?) === self
        return fromHere && sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        _ = super.draggingEntered(sender)
        return dropOperation(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        _ = super.draggingUpdated(sender) // draws the drop caret
        return dropOperation(sender)
    }

    // As a drag source: only a drop back into this view moves (performDragOperation does it
    // through the doc); AppKit would otherwise delete a moved selection from the text storage.
    public override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }

    public override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation == .move ? .copy : operation)
    }

    func dropPosition(_ sender: any NSDraggingInfo) -> Int {
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        return renderer.docPosition(min(index, max(0, (textStorage?.length ?? 1) - 1)))?.pos ?? state.selection.from
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let operation = dropOperation(sender)
        let pos = dropPosition(sender)
        if board.availableType(from: [Self.sliceType, .string]) == nil {
            guard let onIncomingFiles, operation == .copy, case let files = Self.files(on: board), !files.isEmpty else { return false }
            return onIncomingFiles(files, pos)
        }
        return drop(from: board, at: pos, move: operation == .move)
    }

    /// Inserts dragged content at a document position (prosemirror-view's drop handler): note
    /// content as copied, otherwise plain text. A move deletes the selection first; dropping a
    /// selection onto itself does nothing. The dropped content ends up selected.
    @discardableResult
    public func drop(from board: NSPasteboard, at pos: Int, move: Bool) -> Bool {
        let schema = state.schema
        var slice: Slice?
        if let json = board.string(forType: Self.sliceType), let value = try? JSONValue.parse(json),
           let parsed = try? Slice.fromJSON(schema, value) {
            slice = preparePasted(parsed, move ? .move : .copy)
        } else if let text = board.string(forType: .string) {
            slice = Self.plainTextSlice(text, schema)
        }
        guard let slice else { return false }
        return run { state, dispatch, _ in
            let selection = state.selection
            if move && pos >= selection.from && pos <= selection.to { return false }
            let tr = state.tr
            var at = pos
            if move {
                guard (try? tr.deleteSelection()) != nil else { return false }
                at = tr.mapping.map(pos)
            }
            let steps = tr.mapping.maps.count
            guard (try? tr.replaceRange(at, at, slice)) != nil else { return false }
            let inserted = tr.mapping.slice(steps)
            tr.setSelection(TextSelection.between(tr.doc.resolve(inserted.map(at, assoc: -1)), tr.doc.resolve(inserted.map(at, assoc: 1))))
            dispatch?(tr.scrollIntoView())
            return true
        }
    }

    public override func pasteAsPlainText(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count == 1 {
            insert(text, (state.selection.from, state.selection.to))
            return
        }
        run { state, dispatch, _ in
            guard let slice = Self.plainTextSlice(text, state.schema),
                  let tr = try? state.tr.replaceSelection(slice) else { return false }
            dispatch?(tr.scrollIntoView())
            return true
        }
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

    // MARK: Mouse

    /// Called when a checkbox marker is clicked, with the document position of
    /// the paragraph's content start. Return true if handled.
    public var onMarkerClick: ((Int) -> Bool)?
    /// A pill in a chrome box's strip was clicked (or chosen with VoiceOver). Nil: pills are
    /// only drawn, and clicks on them place the caret as anywhere else.
    public var onChromePillTap: ((ChromePillHit) -> Void)?
    /// Whether pills take clicks now (a read-only note's don't). Asked on every hit test.
    public var chromePillsEnabled: () -> Bool = { true }
    /// The pill under the pointer: its card and index.
    var hoveredPillHit: ChromePillHit?
    /// VoiceOver elements for the pills on screen.
    let pillAccessibility = PillAccessibilityCache()
    /// The string offset of the paragraph whose checkbox the pointer is over.
    private(set) var hoveredMarker: Int?
    /// The chrome region (its node position) the pointer is over.
    private(set) var hoveredChrome: Int?
    /// How far each card's and checkbox's hover look has faded in.
    let chromeHover = HoverFade()
    let markerHover = HoverFade()
    private var hoverLink: AnyObject?
    private var lastHoverTick: CFTimeInterval = 0

    /// A plain click on the character at this document position (the position before it).
    /// Return true to take the click (e.g. to open a link), false to let it place the caret.
    public var onCharacterClick: ((Int) -> Bool)?

    /// A click below the last line of text. Return true to take it (a table ending the note
    /// adds a line to type on).
    public var clickBelowContent: ((ProseTextView, NSEvent) -> Bool)?

    public override func mouseDown(with event: NSEvent) {
        // A strip pill is a button: it neither moves the caret nor opens its card.
        if let hit = tappablePill(at: convert(event.locationInWindow, from: nil)) {
            if event.clickCount == 1 { onChromePillTap?(hit) }
            return
        }
        if event.clickCount == 1, let clickBelowContent, isBelowContent(event), clickBelowContent(self, event) { return }
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           let onCharacterClick, let pos = characterPosition(at: event), onCharacterClick(pos) { return }
        if let offset = markerOffset(at: event), let (pos, _) = renderer.docPosition(offset), onMarkerClick?(pos) == true { return }
        super.mouseDown(with: event)
    }

    /// The string offset of the paragraph whose clickable marker (checkbox, disclosure) is
    /// under the mouse, with a little slack around it.
    func markerOffset(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let lineStart = textContainer?.lineFragmentPadding ?? 0
        guard let fragment = blockFragment(atY: inContainer.y), let box = fragment.checkboxRect(lineStart: lineStart),
              box.insetBy(dx: -4, dy: -4).contains(inContainer), let tcs = textContentStorage else { return nil }
        return tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
    }

    private func isBelowContent(_ event: NSEvent) -> Bool {
        guard let tlm = textLayoutManager else { return false }
        tlm.ensureLayout(for: tlm.documentRange)
        let y = convert(event.locationInWindow, from: nil).y - textContainerOrigin.y
        return y > tlm.usageBoundsForTextContainer.maxY
    }

    /// The document position before the character under the mouse, if the click is on one.
    private func characterPosition(at event: NSEvent) -> Int? {
        guard let window else { return nil }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndex(for: screen)
        guard index != NSNotFound, index < (textStorage?.length ?? 0) else { return nil }
        var actual = NSRange()
        let glyph = firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: &actual)
        guard glyph.insetBy(dx: -1, dy: -1).contains(screen), let span = renderer.span(atString: index), !span.isLeaf else { return nil }
        return renderer.docPosition(index)?.pos
    }

    /// The decorated fragment whose frame spans container y (markers sit left of the text,
    /// where TextKit's point lookup finds nothing).
    private func blockFragment(atY y: CGFloat) -> BlockLayoutFragment? {
        guard let tlm = textLayoutManager else { return nil }
        let start = tlm.textViewportLayoutController.viewportRange?.location ?? tlm.documentRange.location
        var found: BlockLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > y { return false }
            if frame.maxY >= y { found = fragment as? BlockLayoutFragment; return false }
            return true
        }
        return found
    }

    /// View-space rect of the checkbox drawn for the paragraph at string offset `offset` (for tests).
    public func checkboxRect(atString offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager, let tcs = textContentStorage,
              let loc = tcs.location(tcs.documentRange.location, offsetBy: offset),
              case _ = tlm.ensureLayout(for: NSTextRange(location: loc)),
              let fragment = tlm.textLayoutFragment(for: loc) as? BlockLayoutFragment,
              let r = fragment.checkboxRect(lineStart: textContainer?.lineFragmentPadding ?? 0) else { return nil }
        return r.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Undo menu

    /// Undo/redo menu items route here; the history plugin owns undo.
    public var undoCommand: Command?
    public var redoCommand: Command?

    @objc public func undo(_ sender: Any?) { if let c = undoCommand { run(c) } }
    @objc public func redo(_ sender: Any?) { if let c = redoCommand { run(c) } }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return undoCommand.map { $0(state, nil, self) } ?? false
        case #selector(redo(_:)): return redoCommand.map { $0(state, nil, self) } ?? false
        default: return super.validateUserInterfaceItem(item)
        }
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
    var hostContentManager: NSTextContentManager? { textContentStorage }
    var hostTextContainer: NSTextContainer? { textContainer }
    var hostContainerOrigin: CGPoint { textContainerOrigin }
    func chromeHoverLevel(_ pos: Int) -> CGFloat { chromeHover.level(pos) }
    func hoveredPill(_ pos: Int) -> Int? { hoveredPillHit?.pos == pos ? hoveredPillHit?.index : nil }
}

/// A view embedded in the note's text (a table) that wants its own cursor at some points.
@MainActor public protocol EmbeddedCursorProviding: NSView {
    /// The cursor for the pointer at `event`, or nil for the note's own.
    func cursor(for event: NSEvent) -> NSCursor?
}
#endif
