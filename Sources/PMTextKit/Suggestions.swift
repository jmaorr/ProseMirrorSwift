#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import PMModel
import PMTransform
import PMState

// MARK: Model

/// One entry in a suggestion menu (a slash command, a mention, ...).
public struct SuggestionItem: Identifiable {
    public enum Icon: Equatable {
        /// An SF Symbol name.
        case symbol(String)
        /// A short text glyph, for things SF Symbols has no symbol for ("H1").
        case text(String)
    }

    /// Stable identifier; also matched by the filter ("heading1").
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon?
    /// Extra words the filter matches ("h1", "title").
    public var keywords: [String]
    /// Run on the state with the trigger and query already removed. Called without a dispatch
    /// to decide whether the item is offered at all, so it must be a pure check then.
    public var command: Command

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon? = nil, keywords: [String] = [], command: @escaping Command) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.command = command
    }

    /// Case-insensitive: anywhere in the title, or the start of the id or a keyword. An empty
    /// query matches everything.
    public func matches(_ query: String) -> Bool { matchRank(query) != nil }

    /// How well `query` matches, lower first: the title's start, a later word of the title, the
    /// start of the id or a keyword, then anywhere in the title. Nil for no match.
    public func matchRank(_ query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func prefix(_ s: String) -> Bool { s.range(of: query, options: options.union(.anchored)) != nil }
        if prefix(title) { return 0 }
        if title.split(separator: " ").dropFirst().contains(where: { prefix(String($0)) }) { return 1 }
        if ([id] + keywords).contains(where: prefix) { return 2 }
        if title.range(of: query, options: options) != nil { return 3 }
        return nil
    }
}

/// What opens a suggestion menu: a character typed at the start of a textblock or after
/// whitespace (Tiptap's Suggestion with `allowSpaces: false`). Typing on filters the items;
/// the menu closes when the caret leaves `trigger + query`, on a space, on Escape, on scroll
/// or when the view loses focus.
public struct SuggestionTrigger {
    public var character: Character
    /// The items before filtering, for the state the menu is about to show in.
    public var items: (EditorState) -> [SuggestionItem]
    /// Whether the trigger may open at this caret (for example, not in code).
    public var isAllowed: (ResolvedPos) -> Bool
    /// Shown when nothing matches the query.
    public var emptyText: String

    public init(character: Character, emptyText: String = "No results",
                isAllowed: @escaping (ResolvedPos) -> Bool = { _ in true },
                items: @escaping (EditorState) -> [SuggestionItem]) {
        self.character = character
        self.items = items
        self.isAllowed = isAllowed
        self.emptyText = emptyText
    }
}

// MARK: Controller

/// Runs one `SuggestionTrigger` on a `ProseTextView`: watches what is typed, keeps the
/// filtered items and the selection, takes the menu keys while open, and shows the menu.
/// macOS shows its own NSPanel (`SuggestionMenu`); on iOS the app shows `SuggestionState`
/// (the view's `suggestionState`), which follows the open controller.
@MainActor
public final class SuggestionController {
    public let trigger: SuggestionTrigger
    private weak var view: ProseTextView?
    #if os(macOS)
    let menu = SuggestionMenu()
    #endif

    /// The trigger character's position and the caret, while open.
    public private(set) var range: (from: Int, to: Int)?
    public private(set) var query = ""
    /// The items on show: matching the query, and able to run here.
    public private(set) var items: [SuggestionItem] = []
    public private(set) var selectedIndex = 0
    public var isOpen: Bool { range != nil }

    private var observers: [NSObjectProtocol] = []

    init(trigger: SuggestionTrigger, view: ProseTextView) {
        self.trigger = trigger
        self.view = view
        #if os(macOS)
        menu.onHover = { [weak self] index in self?.select(index, scroll: false) }
        menu.onClick = { [weak self] index in self?.choose(index) }
        #endif
    }

    // MARK: Following the document

    /// After every state change. `typed` is the text the user just typed, if this change is it.
    func stateDidChange(_ tr: Transaction?, typed: String?) {
        guard let view else { return }
        let state = view.state
        if let open = range {
            guard let tr, let match = match(state, from: tr.mapping.map(open.from)) else { return close() }
            refresh(match)
        } else if let tr, tr.docChanged, typed == String(trigger.character), state.selection.empty {
            let from = state.selection.head - 1
            guard from >= 0, startsTrigger(state.doc, at: from), let match = match(state, from: from) else { return }
            open(match)
        }
    }

    /// The trigger at `from` must follow the start of its textblock or whitespace.
    private func startsTrigger(_ doc: Node, at from: Int) -> Bool {
        let rpos = doc.resolve(from)
        guard rpos.parent.inlineContent else { return false }
        if rpos.parentOffset == 0 { return true }
        let before = doc.textBetween(from - 1, from, blockSeparator: "\n", leafText: "\n")
        return before.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// `trigger + query` from `from` to the caret, if the caret is still in it.
    private func match(_ state: EditorState, from: Int) -> (from: Int, to: Int, query: String)? {
        let sel = state.selection
        guard sel.empty, sel is TextSelection else { return nil }
        let head = sel.headPos
        guard head.parent.inlineContent, from >= head.start(), sel.head > from, trigger.isAllowed(head) else { return nil }
        let text = state.doc.textBetween(from, sel.head, blockSeparator: "\n", leafText: "\u{FFFC}")
        guard text.first == trigger.character else { return nil }
        let query = String(text.dropFirst())
        guard query.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}" }) else { return nil }
        return (from, sel.head, query)
    }

    private func open(_ match: (from: Int, to: Int, query: String)) {
        guard let view else { return }
        range = (match.from, match.to)
        query = match.query
        items = available(match)
        selectedIndex = 0
        observe(view)
        show()
    }

    private func refresh(_ match: (from: Int, to: Int, query: String)) {
        let selectedID = items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        let queryChanged = match.query != query
        range = (match.from, match.to)
        query = match.query
        items = available(match)
        // A new query starts at the best (first) match, as the web did; otherwise keep the row.
        selectedIndex = queryChanged ? 0 : (items.firstIndex { $0.id == selectedID } ?? 0)
        show()
    }

    /// The trigger's items that match the query and can run once `trigger + query` is gone.
    private func available(_ match: (from: Int, to: Int, query: String)) -> [SuggestionItem] {
        guard let view else { return [] }
        let state = view.state
        // Best matches first; the trigger's order otherwise (a stable sort).
        let matching = trigger.items(state).enumerated()
            .compactMap { i, item in item.matchRank(match.query).map { (rank: $0, i: i, item: item) } }
            .sorted { ($0.rank, $0.i) < ($1.rank, $1.i) }
            .map(\.item)
        guard let tr = try? state.tr.delete(match.from, match.to) else { return matching }
        let without = state.apply(tr)
        return matching.filter { $0.command(without, nil, view) }
    }

    // MARK: Keys and choosing

    /// The menu's keys while it's open: ↑/↓ (and ⌃P/⌃N) move, Return/Tab choose, Escape closes.
    /// With nothing matching, Return and Tab close the menu and do their usual thing.
    func handleKey(_ event: KeyEvent) -> Bool {
        guard isOpen else { return false }
        let plain = !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey
        let ctrlOnly = event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey
        switch event.key {
        case "ArrowDown" where plain, "n" where ctrlOnly:
            guard !items.isEmpty else { return false }
            move(1)
        case "ArrowUp" where plain, "p" where ctrlOnly:
            guard !items.isEmpty else { return false }
            move(-1)
        case "Enter" where plain, "Tab" where plain:
            guard !items.isEmpty else { close(); return false }
            choose(selectedIndex)
        case "Escape":
            close()
        default:
            return false
        }
        return true
    }

    /// Move the selection by `delta` rows, wrapping around (as the web menu does).
    public func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta % items.count + items.count) % items.count)
    }

    /// Select a row; `scroll` brings it into view (not for the pointer, which is already on it).
    public func select(_ index: Int, scroll: Bool = true) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        #if os(macOS)
        menu.setSelected(index, scroll: scroll)
        menu.announce(items[index])
        #else
        view?.suggestionsDidChange()
        #endif
    }

    /// Remove `trigger + query` and run the item's command, as one change (one undo step).
    public func choose(_ index: Int) {
        guard let view, let range, items.indices.contains(index) else { return }
        let item = items[index]
        close()
        view.run { state, dispatch, editorView in
            guard let dispatch, let tr = try? state.tr.delete(range.from, min(range.to, state.doc.content.size)) else { return false }
            let (without, applied) = state.applyTransaction(tr)
            var inner: Transaction?
            // Plugins that append to the deletion would leave `without` on another doc than `tr`;
            // then the deletion and the command go in one after the other.
            guard applied.count == 1 else {
                dispatch(view.separateUndoStep?(tr) ?? tr)
                return item.command(view.state, view.dispatch, editorView)
            }
            let ran = item.command(without, { inner = $0 }, editorView)
            if ran, let inner {
                for step in inner.steps { _ = try? tr.step(step) }
                for (key, value) in inner.allMeta { _ = tr.setMeta(key, value) }
                if tr.doc.eq(inner.doc) {
                    _ = tr.setSelection(inner.selection.map(tr.doc, Mapping()))
                    if inner.storedMarksSet { _ = tr.setStoredMarks(inner.storedMarks) }
                }
            }
            // Its own undo step: undo gives the typed `/query` back.
            dispatch((view.separateUndoStep?(tr) ?? tr).scrollIntoView())
            return true
        }
        #if os(macOS)
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        #endif
    }

    /// Close the menu, leaving the text as it is.
    public func close() {
        guard range != nil else { return }
        range = nil
        query = ""
        items = []
        selectedIndex = 0
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        #if os(macOS)
        menu.hide()
        #else
        view?.suggestionsDidChange()
        #endif
    }

    // MARK: Showing

    #if !os(macOS)
    private func show() {
        view?.suggestionsDidChange()
    }

    /// Close when the keyboard goes away (dismissed interactively, or focus moved): the app's
    /// list sits above the keyboard, and the format bar should be back when it returns.
    private func observe(_ view: ProseTextView) {
        observers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
    #else
    private func show() {
        guard let view, let range else { return }
        menu.accent = view.suggestionAccentColor
        menu.update(items: items, selected: selectedIndex, emptyText: trigger.emptyText)
        guard let anchor = anchorRect(range.from) else { return menu.hide() }
        menu.show(below: anchor, in: view)
    }

    /// The trigger character's line box in view coordinates.
    func anchorRect(_ pos: Int) -> CGRect? {
        guard let view, let tlm = view.textLayoutManager, let tcs = view.textContentStorage else { return nil }
        let offset = view.renderer.stringOffset(pos, bias: 1)
        guard let start = tcs.location(tcs.documentRange.location, offsetBy: offset),
              let end = tcs.location(start, offsetBy: 1), let textRange = NSTextRange(location: start, end: end) else { return nil }
        tlm.ensureLayout(for: textRange)
        var rect: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r
            return false
        }
        return rect.map { $0.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y) }
    }

    /// Close on a scroll the user makes, focus leaving the window, or the window changing;
    /// follow the caret when the view scrolls itself (to keep the caret visible as you type).
    private func observe(_ view: ProseTextView) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: AnyObject?, _ action: @escaping @MainActor (SuggestionController) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        if let scroll = view.enclosingScrollView {
            on(NSScrollView.willStartLiveScrollNotification, scroll) { $0.close() }
            scroll.contentView.postsBoundsChangedNotifications = true
            on(NSView.boundsDidChangeNotification, scroll.contentView) { $0.viewScrolled() }
        }
        if let window = view.window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification,
                         NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                on(name, window) { $0.close() }
            }
        }
    }

    private func viewScrolled() {
        guard let view, let range, let anchor = anchorRect(range.from) else { return close() }
        guard view.visibleRect.intersects(anchor) else { return close() }
        menu.show(below: anchor, in: view)
    }
    #endif
}

extension ProseTextView {
    /// The controllers for `suggestionTriggers`, one each.
    public var suggestions: [SuggestionController] { suggestionControllers }

    /// The open suggestion menu, if any.
    public var activeSuggestion: SuggestionController? { suggestionControllers.first { $0.isOpen } }

    func closeSuggestions() {
        for s in suggestionControllers { s.close() }
    }
}
