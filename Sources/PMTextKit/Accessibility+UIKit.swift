#if canImport(UIKit) && !os(macOS)
import UIKit
import PMState

/// A VoiceOver custom action the editor offers for the current selection: a name and the
/// command it runs.
public struct EditorAccessibilityAction {
    public var name: String
    public var command: Command

    public init(name: String, command: @escaping Command) {
        self.name = name
        self.command = command
    }
}

extension ProseTextView {
    /// The actions for the state's selection ("Mark done" in a task card); set by the editor,
    /// which knows what its blocks are. Asked each time VoiceOver wants the text view's actions.
    public var accessibilityActionsProvider: ((EditorState) -> [EditorAccessibilityAction])? {
        get { cardControlState.accessibilityActions }
        set { cardControlState.accessibilityActions = newValue }
    }

    /// The text view's own actions (UIKit's), then the editor's for the selection.
    public override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let own = super.accessibilityCustomActions ?? []
            let mine = (cardControlState.accessibilityActions?(state) ?? []).map { action in
                UIAccessibilityCustomAction(name: action.name) { [weak self] _ in self?.run(action.command) ?? false }
            }
            // The pills of the card holding the selection ("Status: In progress").
            let pills = pillAccessibilityActions().map { action in
                UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                    guard let tap = self?.onChromePillTap else { return false }
                    tap(action.hit)
                    return true
                }
            }
            return own + mine + pills
        }
        set { super.accessibilityCustomActions = newValue }
    }
}
#endif
