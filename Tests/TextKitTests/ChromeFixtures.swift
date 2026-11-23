// Test-only styles and a schema for PMTextKit features BasicStyle doesn't use: chrome boxes
// around container nodes (with controls and a shadow) and checkable list items.
#if os(macOS)
import AppKit
import PMModel
import PMState
import PMTextKit
import PMExampleSetup

/// BasicStyle, with every `blockquote` drawn as a card: a filled, bordered box with a soft shadow
/// that opens (grows a footer with a "Done" control) while the selection is in it.
struct BoxedQuoteStyle: DocStyle {
    var base = BasicStyle()
    var shadow: PlatformColor? = NSColor(white: 0, alpha: 0.35)
    var footer: CGFloat = 34
    /// Done: puts the caret after the quote.
    var controls = true

    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.paragraph(textblock, ancestors: ancestors, marker: marker)
    }
    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }
    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.leafBlock(node, ancestors: ancestors)
    }
    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? { base.marker(for: child, in: parent, index: index) }
    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? { base.chrome(forTextblock: node, ancestors: ancestors) }
    func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        base.embed(for: node, at: pos, ancestors: ancestors)
    }

    func chrome(for node: Node) -> ChromeBox? {
        guard node.type.name == "blockquote" else { return nil }
        var box = ChromeBox()
        box.margin = 6
        box.paddingTop = 10
        box.paddingBottom = 10
        box.footer = controls ? footer : 0
        box.insetLeft = -8
        box.insetRight = 8
        box.cornerRadius = 10
        box.fill = NSColor(white: 0.97, alpha: 1)
        box.activeFill = .white
        box.border = NSColor(white: 0, alpha: 0.12)
        box.activeBorder = NSColor(white: 0, alpha: 0.25)
        box.shadow = shadow
        box.shadowRadius = 8
        return box
    }

    func controls(for node: Node) -> [ChromeControl] {
        guard controls, node.type.name == "blockquote" else { return [] }
        return [ChromeControl(title: "Done", symbol: "checkmark") { pos in
            { state, dispatch, _ in
                guard let quote = state.doc.nodeAt(pos) else { return false }
                let after = pos + quote.nodeSize
                dispatch?(state.tr.setSelection(Selection.near(state.doc.resolve(min(after, state.doc.content.size)))))
                return true
            }
        }]
    }
}

/// BasicSchema plus a checklist: `check_list` of `check_item`s (a `checked` attribute, then a
/// paragraph and any blocks), and a style that draws a checkbox beside each item and strikes
/// ticked items through.
enum ChecklistFixture {
    static let schema: Schema = {
        let nodes = BasicSchema.nodes + [
            ("check_list", NodeSpec(content: "check_item+", group: "block")),
            ("check_item", NodeSpec(content: "paragraph block*", attrs: [("checked", AttributeSpec(default: false))], defining: true)),
        ]
        return try! Schema(SchemaSpec(nodes: nodes, marks: BasicSchema.marks))
    }()

    /// A doc with one checklist of `items` (text, checked).
    static func doc(_ items: [(String, Bool)]) throws -> Node {
        try schema.nodeFromJSON(J.doc([J.node("check_list", nil, items.map { text, checked in
            J.node("check_item", ["checked": .bool(checked)], [J.p(text)])
        })]))
    }

    /// Ticks or unticks the item around `pos`.
    static func toggle(at pos: Int) -> Command {
        { state, dispatch, _ in
            let rp = state.doc.resolve(pos)
            for depth in stride(from: rp.depth, through: 1, by: -1) where rp.node(depth).type.name == "check_item" {
                let item = rp.node(depth)
                let checked = item.attrs["checked"]?.boolValue ?? false
                guard let tr = try? state.tr.setNodeAttribute(rp.before(depth), "checked", .bool(!checked)) else { return false }
                dispatch?(tr)
                return true
            }
            return false
        }
    }

    struct Style: DocStyle {
        var base = BasicStyle()

        func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
            var (attrs, deco) = base.paragraph(textblock, ancestors: ancestors, marker: marker)
            guard let item = ancestors.last, item.type.name == "check_item" else { return (attrs, deco) }
            let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let indent = 24 * CGFloat(ancestors.filter { $0.type.name == "check_list" }.count)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            attrs[.paragraphStyle] = style
            let d = deco ?? BlockDecoration()
            d.font = attrs[.font] as? NSFont ?? base.bodyFont
            if let marker {
                d.marker = marker
                d.markerRight = indent - 6
            }
            d.strikeProgress = item.attrs["checked"]?.boolValue == true ? 1 : 0
            deco = d
            return (attrs, deco)
        }
        func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
            base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
        }
        func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
            base.leafBlock(node, ancestors: ancestors)
        }
        func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString { base.inlineLeaf(node, base: attrs) }
        func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? {
            if parent.type.name == "check_list" { return .checkbox(checked: child.attrs["checked"]?.boolValue == true) }
            return base.marker(for: child, in: parent, index: index)
        }
    }
}
#endif
