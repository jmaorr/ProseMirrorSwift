#if os(iOS)
import UIKit
import PMModel
import PMState
import PMTextKit
import PMTables

/// A table in the note's text: one attachment character whose view is the table's grid
/// (view-only on iOS for now). `TableEmbeds` keeps one per table across edits.
public final class TableAttachment: NSTextAttachment {
    public let grid: TableGridView
    public private(set) lazy var host: TableHostView = MainActor.assumeIsolated {
        let host = TableHostView(grid: grid)
        host.onTap = { [weak self] in self?.selectTable() }
        return host
    }

    init(grid: TableGridView) {
        self.grid = grid
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        grid.onHeightChange = { [weak self] in MainActor.assumeIsolated { self?.invalidateHostLayout() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // UIKit gives an attachment that sizes itself no view: the provider sizes it.
    public override func viewProvider(for parentView: UIView?, location: any NSTextLocation,
                                      textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = TableViewProvider(textAttachment: self, parentView: parentView,
                                         textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    /// The note's text view showing the table, if it's on screen.
    @MainActor var textView: ProseTextView? {
        var v: UIView? = host.superview
        while let current = v, !(current is ProseTextView) { v = current.superview }
        return v as? ProseTextView
    }

    /// A tap selects the whole table: one character in the text, never a caret in a cell. It
    /// doesn't raise the keyboard (the text view stays first responder only if it was), so a
    /// stray keystroke can't replace the table.
    @MainActor func selectTable() {
        guard let textView, grid.table != nil else { return }
        let state = textView.state
        guard !((state.selection as? NodeSelection)?.from == grid.tablePos) else { return }
        textView.dispatch(state.tr.setSelection(NodeSelection.create(state.doc, grid.tablePos)))
    }

    /// The table's height changed: lay its line out again.
    @MainActor func invalidateHostLayout() {
        host.setNeedsLayout()
        guard let textView, let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let offset = textView.renderer.stringOffset(grid.tablePos, bias: 1)
        guard let start = tcm.location(tcm.documentRange.location, offsetBy: offset),
              let end = tcm.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else { return }
        tlm.invalidateLayout(for: range)
        textView.setNeedsLayout()
        tlm.textViewportLayoutController.layoutViewport()
    }
}

final class TableViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? TableAttachment else { return }
        view = MainActor.assumeIsolated { attachment.host }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let attachment = textAttachment as? TableAttachment else { return .zero }
        // TextKit proposes the line's width inside the line fragment padding: the column.
        let width = max(proposedLineFragment.width, 40)
        return MainActor.assumeIsolated {
            attachment.host.setWidth(width)
            return CGRect(x: 0, y: 0, width: width, height: attachment.host.height)
        }
    }
}
#endif
