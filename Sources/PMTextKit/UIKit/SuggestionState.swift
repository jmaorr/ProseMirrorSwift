#if canImport(UIKit) && !os(macOS)
import Combine
import UIKit

/// The open suggestion menu (the slash command menu) on iOS, for the app to show: a SwiftUI
/// list above the keyboard instead of the Mac's NSPanel. It follows the text view's
/// `SuggestionController`s (`ProseTextView.suggestionTriggers`); there is one per view
/// (`ProseTextView.suggestionState`).
///
/// Hardware keys go to the controller through the view (↑/↓ move `highlighted`, Return and
/// Tab choose, Escape dismisses), as on the Mac. The menu closes when the caret leaves the
/// `/query`, on a space, when the view loses focus and when the keyboard hides.
@MainActor
public final class SuggestionState: ObservableObject {
    /// A menu is open (a trigger was typed and the caret is still in its query).
    @Published public private(set) var isActive = false
    /// The items on show: matching the query, best first, and able to run here. Empty while
    /// open with nothing matching (show `emptyText`).
    @Published public private(set) var items: [SuggestionItem] = []
    /// The selected row. Setting it selects that row in the menu (Return then chooses it).
    @Published public var highlighted = 0 {
        didSet {
            guard !refreshing, highlighted != oldValue else { return }
            view?.activeSuggestion?.select(highlighted)
        }
    }
    /// What has been typed after the trigger.
    @Published public private(set) var query = ""
    /// Shown when nothing matches the query.
    public private(set) var emptyText = ""

    private weak var view: ProseTextView?
    private var refreshing = false

    init(view: ProseTextView) {
        self.view = view
        refresh()
    }

    /// Remove the trigger and query and run the item at `index`, as one undo step.
    public func choose(_ index: Int) {
        view?.activeSuggestion?.choose(index)
    }

    /// Close the menu, leaving the typed text as it is.
    public func dismiss() {
        view?.activeSuggestion?.close()
    }

    /// Read the open controller (called by the view whenever one changes).
    func refresh() {
        refreshing = true
        defer { refreshing = false }
        let open = view?.activeSuggestion
        let active = open != nil
        let newItems = open?.items ?? []
        let newQuery = open?.query ?? ""
        let newHighlighted = open?.selectedIndex ?? 0
        // Publish only what changed, so SwiftUI redraws no more than it needs to.
        if isActive != active { isActive = active }
        if items.map(\.id) != newItems.map(\.id) || items.map(\.title) != newItems.map(\.title) { items = newItems }
        if query != newQuery { query = newQuery }
        if highlighted != newHighlighted { highlighted = newHighlighted }
        emptyText = open?.trigger.emptyText ?? ""
    }
}
#endif
