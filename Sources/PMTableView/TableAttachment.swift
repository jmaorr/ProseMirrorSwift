#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if os(macOS) || os(iOS)
import PMModel
import PMState
import PMTextKit
import PMTables

/// How cell content renders, static or in the cell editor: the note's style, except that
/// blocks a cell can't show natively draw as a plain label, and a table inside a cell is a
/// read-only card.
public struct CellDocStyle: DocStyle {
    public var base: DocStyle
    /// Rendering a header cell: its text is semibold, as on the web.
    public var header = false
    /// The cell being rendered. A cell renders as its own root, which its blocks don't see as
    /// an ancestor; the base style gets it prepended, so it can style blocks inside cells.
    public var cell: Node?

    public init(_ base: DocStyle) { self.base = base }

    public func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        var (attrs, deco) = base.paragraph(textblock, ancestors: withCell(ancestors), marker: marker)
        if header, let font = attrs[.font] as? PlatformFont { attrs[.font] = Self.semibold(font) }
        return (attrs, deco)
    }

    public func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        var out = base.inline(marks, base: attrs, textblock: textblock, ancestors: withCell(ancestors))
        if header, let font = out[.font] as? PlatformFont { out[.font] = Self.semibold(font) }
        return out
    }

    private func withCell(_ ancestors: [Node]) -> [Node] {
        guard let cell, ancestors.first !== cell else { return ancestors }
        return [cell] + ancestors
    }

    #if os(macOS)
    static func semibold(_ font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold) { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    #else
    static func semibold(_ font: UIFont) -> UIFont {
        if font.isBold { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        let semibold = UIFont(descriptor: descriptor, size: font.pointSize)
        // A face without a semibold (the descriptor matched the same font): bold instead.
        return semibold.fontName == font.fontName ? font.adding(bold: true, italic: false) : semibold
    }
    #endif

    public func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        var (attrs, deco) = base.leafBlock(node, ancestors: withCell(ancestors))
        if attrs[.attachment] != nil {
            attrs[.attachment] = nil
            let label = deco ?? BlockDecoration()
            label.leafLabel = node.attrs["alt"]?.stringValue ?? node.attrs["filename"]?.stringValue ?? node.type.name
            deco = label
        }
        return (attrs, deco)
    }

    public func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        base.inlineLeaf(node, base: attrs)
    }

    public func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? {
        base.marker(for: child, in: parent, index: index)
    }

    public func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        guard node.type.tableRole == .table else { return nil }
        let (attrs, _) = base.paragraph(node.type.schema.nodes["paragraph"].flatMap { $0.createAndFill() } ?? node,
                                        ancestors: [], marker: nil)
        let deco = BlockDecoration()
        let map = try? TableMap.get(node)
        deco.leafLabel = "Table — \(map?.height ?? 0)×\(map?.width ?? 0), edit on web"
        deco.background = PlatformColor.quaternaryLabelColor.withAlphaComponent(0.12)
        var out = attrs
        out[.pmBlock] = deco
        return out
    }
}

#if os(macOS)
/// A table in the note's text: one attachment character whose view is the table's grid.
public final class TableAttachment: NSTextAttachment {
    public let grid: TableGridView
    public private(set) lazy var host = TableHostView(grid: grid)
    /// The note's text view, which lays the attachment out.
    weak var textView: ProseTextView?

    init(grid: TableGridView) {
        self.grid = grid
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        // Without an image TextKit draws a file icon behind the view (nil stops it asking for the view).
        image = NSImage(size: NSSize(width: 1, height: 1))
        grid.onHeightChange = { [weak self] oldHeight, rowsChanged in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.host.gridHeightChanged(from: oldHeight, animated: rowsChanged) { [weak self] in self?.invalidateHostLayout() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                                      textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        if let view = parentView as? ProseTextView {
            textView = view
            MainActor.assumeIsolated {
                grid.hostTextView = view
                if view.clickBelowContent == nil {
                    view.clickBelowContent = { view, _ in
                        view.window?.makeFirstResponder(view)
                        return addLineAfterFinalTable(view.state, view.dispatch, view)
                    }
                }
            }
            // TextKit adds an attachment's view on a later layout pass, which nothing asks for
            // when a note opens: ask, or the table stays blank until the next edit or scroll.
            RunLoop.main.perform(inModes: [.common]) { [weak view] in
                MainActor.assumeIsolated {
                    guard let view, view.window != nil else { return }
                    view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                }
            }
        }
        return TableViewProvider(textAttachment: self, parentView: parentView,
                          textLayoutManager: textContainer?.textLayoutManager, location: location)
    }

    public override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                          textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                          position: CGPoint) -> CGRect {
        // The grid lines up with the text; row grips hang into the margin (the host doesn't clip).
        let width = max(proposedLineFragment.width - 2, 40)
        MainActor.assumeIsolated { host.setWidth(width) }
        return CGRect(x: 0, y: 0, width: width, height: MainActor.assumeIsolated { host.height })
    }

    /// The table's height changed: lay its line out again.
    @MainActor func invalidateHostLayout() {
        guard let textView else { return }
        textView.invalidateLayout(forString: NSRange(location: textView.renderer.stringOffset(grid.tablePos, bias: 1), length: 1))
    }
}

final class TableViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        view = (textAttachment as? TableAttachment)?.host
    }
}
#endif

/// The note's table attachments, one per table, kept across edits (so a table's grid and cell
/// editor survive typing) and mapped through every change before the views update.
public final class TableEmbeds: EditorCoreObserver {
    public let core: EditorCore
    public var tableStyle: TableStyle { didSet { for a in attachments.values { a.grid.style = tableStyle } } }
    public var cellStyle: DocStyle { didSet { for a in attachments.values { a.grid.cellStyle = CellDocStyle(cellStyle) } } }
    private var attachments: [Int: TableAttachment] = [:]
    /// Called with each new grid, to configure it (the editor's commands, undo boundaries).
    public var configureGrid: ((TableGridView) -> Void)?

    public init(core: EditorCore, tableStyle: TableStyle, cellStyle: DocStyle) {
        self.core = core
        self.tableStyle = tableStyle
        self.cellStyle = cellStyle
        core.addObserver(self, first: true)
    }

    /// Attributes for the table at `pos`: its attachment, created on first use.
    public func attributes(for node: Node, at pos: Int, paragraph: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = paragraph
        attrs[.attachment] = attachment(at: pos)
        return attrs
    }

    public func attachment(at pos: Int) -> TableAttachment {
        if let existing = attachments[pos] { return existing }
        let grid = MainActor.assumeIsolated { TableGridView(core: core, tablePos: pos, style: tableStyle, cellStyle: CellDocStyle(cellStyle)) }
        let attachment = MainActor.assumeIsolated { TableAttachment(grid: grid) }
        attachments[pos] = attachment
        configureGrid?(grid)
        return attachment
    }

    /// The grid of the table at `pos`, if it has been shown.
    public func grid(at pos: Int) -> TableGridView? { attachments[pos]?.grid }

    public var grids: [TableGridView] { attachments.values.map(\.grid) }

    /// Whether a cell editor has a composition open (hold remote changes until it ends).
    public var composing: Bool { attachments.values.contains { $0.grid.editor?.composing ?? false } }

    public func coreDidUpdate(_ core: EditorCore, _ tr: Transaction?) {
        guard let tr else {
            attachments.removeAll()
            return
        }
        if tr.docChanged {
            var mapped: [Int: TableAttachment] = [:]
            // The tables in the new doc by node, found only if a table's position was replaced.
            var tablesByNode: [ObjectIdentifier: Int]?
            for (pos, attachment) in attachments {
                let result = tr.mapping.mapResult(pos, assoc: 1)
                if !result.deletedAfter, tr.doc.nodeAt(result.pos)?.type.tableRole == .table, mapped[result.pos] == nil {
                    attachment.grid.tablePos = result.pos
                    mapped[result.pos] = attachment
                    continue
                }
                // A change replacing a range that holds the table, with the table's own node in
                // it (a sync can rewrite a stretch of the note that way): the text keeps showing
                // this attachment (the renderer reuses unchanged nodes), so keep it too.
                if let node = tr.before.nodeAt(pos) {
                    if tablesByNode == nil { tablesByNode = Self.tables(in: tr.doc) }
                    if let kept = tablesByNode?[ObjectIdentifier(node)], mapped[kept] == nil {
                        attachment.grid.tablePos = kept
                        mapped[kept] = attachment
                        continue
                    }
                }
                MainActor.assumeIsolated { attachment.grid.tableRemoved() }
            }
            attachments = mapped
        }
        for attachment in attachments.values { MainActor.assumeIsolated { attachment.grid.update(tr) } }
    }

    /// The position of each table in `doc` (not tables inside table cells), by node.
    private static func tables(in doc: Node) -> [ObjectIdentifier: Int] {
        var out: [ObjectIdentifier: Int] = [:]
        doc.descendants { node, pos, _, _ in
            if node.type.tableRole == .table {
                out[ObjectIdentifier(node)] = pos
                return false
            }
            return !node.isTextblock
        }
        return out
    }
}
#endif
