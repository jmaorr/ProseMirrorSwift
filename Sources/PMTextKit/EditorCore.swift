// Platform-neutral (Foundation only).
import Foundation
import PMState
import PMTransform

/// Something that shows an `EditorCore`'s state and updates after every change.
public protocol EditorCoreObserver: AnyObject {
    /// The core's state changed; `tr` is nil when the whole state was replaced.
    func coreDidUpdate(_ core: EditorCore, _ tr: Transaction?)
}

/// One editor state shared by several views (the note's text view and a table's cell editor):
/// every view dispatches here, the transaction is applied once, and every view updates.
public final class EditorCore {
    public private(set) var state: EditorState
    /// Called after every change, once observers have updated.
    public var onChange: ((EditorState, Transaction?) -> Void)?

    private struct Weak { weak var value: EditorCoreObserver? }
    private var observers: [Weak] = []

    public init(state: EditorState) { self.state = state }

    /// `first` puts the observer ahead of those already added: for bookkeeping (such as mapping
    /// positions) that views rely on when they update.
    public func addObserver(_ observer: EditorCoreObserver, first: Bool = false) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        if first { observers.insert(Weak(value: observer), at: 0) } else { observers.append(Weak(value: observer)) }
    }

    public func removeObserver(_ observer: EditorCoreObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    /// Applies `tr` (and whatever plugins append to it) and updates every view. Observers get
    /// one transaction covering all of it, so positions map through appended changes too
    /// (fixTables repairing a table): `tr` itself when nothing was appended.
    public func dispatch(_ tr: Transaction) {
        let before = state
        let (next, trs) = state.applyTransaction(tr)
        guard !trs.isEmpty else { return }
        state = next
        notify(trs.count == 1 ? tr : Self.combine(before, trs, next))
    }

    /// One transaction from `before` with the steps of `trs`, the root's metadata and the
    /// final selection.
    static func combine(_ before: EditorState, _ trs: [Transaction], _ after: EditorState) -> Transaction {
        let combined = before.tr
        for t in trs { for step in t.steps { _ = try? combined.step(step) } }
        for (key, value) in trs[0].allMeta { _ = combined.setMeta(key, value) }
        _ = combined.setSelection(after.selection.map(combined.doc, Mapping()))
        if trs.contains(where: \.scrolledIntoView) { _ = combined.scrollIntoView() }
        return combined
    }

    /// Replace the whole state (e.g. loading another document).
    public func setState(_ newState: EditorState) {
        state = newState
        notify(nil)
    }

    private func notify(_ tr: Transaction?) {
        for observer in observers.compactMap(\.value) { observer.coreDidUpdate(self, tr) }
        onChange?(state, tr)
    }
}
