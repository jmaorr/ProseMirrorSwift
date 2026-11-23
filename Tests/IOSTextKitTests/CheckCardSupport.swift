// A test-only schema and style with a checkable card: BasicSchema plus a `card_list` of `card`s
// (a title paragraph, then any blocks), each drawn in a chrome box with a round checkbox, footer controls and,
// when its attributes say so, a strip of pills. Enough to drive PMTextKit's chrome machinery
// (boxes, controls, markers, strips, decoration tiles) on iOS without an app's own schema.
#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTransform
import PMTextKit
import PMExampleSetup

enum CheckCard {
    /// BasicSchema's nodes and marks plus `card_list` (a block of cards) and `card` (attrs:
    /// checked, status, duration, due, scheduled). Cards sit in a list, as list items do: the
    /// renderer asks for the markers of a container's children.
    static let schema: Schema = {
        let list = NodeSpec(content: "card+", group: "block")
        let card = NodeSpec(content: "paragraph block*",
                            attrs: [("checked", AttributeSpec(default: false)),
                                    ("status", AttributeSpec(default: "")),
                                    ("duration", AttributeSpec(default: "")),
                                    ("due", AttributeSpec(default: "")),
                                    ("scheduled", AttributeSpec(default: ""))],
                            defining: true)
        return try! Schema(SchemaSpec(nodes: BasicSchema.nodes + [("card_list", list), ("card", card)], marks: BasicSchema.marks))
    }()

    /// A card list holding one card: its title, then a paragraph per description line.
    static func json(_ title: String, description: [String] = [], checked: Bool = false, strip: Bool = false,
                     status: String = "In Progress") -> JSONValue {
        var attrs: [(String, JSONValue)] = [("checked", .bool(checked))]
        if strip {
            attrs += [("status", .string(status)), ("duration", "30m"), ("due", "Nov 21"), ("scheduled", "Nov 22, 2:00 PM")]
        }
        return J.node("card_list", nil, [J.node("card", .object(JSONObject(attrs)), [J.p(title)] + description.map { J.p($0) })])
    }

    static func doc(_ blocks: [JSONValue]) throws -> Node { try schema.nodeFromJSON(J.doc(blocks)) }

    static func state(_ doc: Node, selection: Selection? = nil) -> EditorState {
        EditorState.create(EditorStateConfig(doc: doc, selection: selection ?? Selection.atStart(doc), plugins: exampleSetup(schema: schema)))
    }

    /// Positions of every card, in order.
    static func positions(_ doc: Node) -> [Int] {
        var out: [Int] = []
        doc.descendants { node, pos, _, _ in
            if node.type.name == "card" { out.append(pos) }
            return true
        }
        return out
    }

    /// The card holding `pos`, if any.
    static func card(around pos: Int, in doc: Node) -> Int? {
        let rpos = doc.resolve(pos)
        var depth = rpos.depth
        while depth > 0 {
            if rpos.node(depth).type.name == "card" { return rpos.before(depth) }
            depth -= 1
        }
        return nil
    }

    /// Ticks or unticks the card holding `pos`.
    static func toggle(at pos: Int) -> Command {
        return { state, dispatch, _ in
            guard let cardPos = card(around: pos, in: state.doc), let node = state.doc.nodeAt(cardPos) else { return false }
            var attrs = node.attrs
            attrs["checked"] = .bool(node.attrs["checked"]?.boolValue != true)
            guard let tr = try? state.tr.setNodeMarkup(cardPos, nil, attrs) else { return false }
            dispatch?(tr)
            return true
        }
    }

    /// A new empty card after the one at `pos`, with the caret in its title.
    static func newCard(after pos: Int) -> Command {
        return { state, dispatch, _ in
            guard let node = state.doc.nodeAt(pos), let fresh = schema.nodes["card"]!.createAndFill() else { return false }
            let at = pos + node.nodeSize
            guard let tr = try? state.tr.insert(at, fresh) else { return false }
            _ = tr.setSelection(TextSelection.create(tr.doc, at + 2))
            dispatch?(tr)
            return true
        }
    }

    /// An empty paragraph at the end of the card at `pos`, with the caret in it.
    static func addNote(at pos: Int) -> Command {
        return { state, dispatch, _ in
            guard let node = state.doc.nodeAt(pos), let para = schema.nodes["paragraph"]!.createAndFill() else { return false }
            let at = pos + node.nodeSize - 1
            guard let tr = try? state.tr.insert(at, para) else { return false }
            _ = tr.setSelection(TextSelection.create(tr.doc, at + 1))
            dispatch?(tr)
            return true
        }
    }

    /// Deletes the card at `pos` (its list too, when it's the only card).
    static func delete(at pos: Int) -> Command {
        return { state, dispatch, _ in
            guard let node = state.doc.nodeAt(pos) else { return false }
            let rpos = state.doc.resolve(pos)
            let (from, to) = rpos.parent.childCount == 1 ? (rpos.before(), rpos.after()) : (pos, pos + node.nodeSize)
            guard let tr = try? state.tr.delete(from, to) else { return false }
            dispatch?(tr)
            return true
        }
    }

    static let controlTitles = ["New Card", "Note", "Delete"]

    /// A text view on `doc` in a window, checkbox clicks ticking cards (and reported to `onToggle`).
    @MainActor
    static func host(_ doc: Node, style: CheckCardStyle = CheckCardStyle(), width: CGFloat = 402,
                     onToggle: ((Int, Bool) -> Void)? = nil) -> HostedTextView {
        let hosted = HostedTextView(state: state(doc), style: style, width: width)
        let tv = hosted.view
        tv.animatesChecks = false
        tv.onMarkerClick = { [weak tv] pos in
            guard let tv, let cardPos = card(around: pos, in: tv.state.doc) else { return false }
            guard tv.run(toggle(at: pos)) else { return false }
            onToggle?(cardPos, tv.state.doc.nodeAt(cardPos)?.attrs["checked"]?.boolValue == true)
            return true
        }
        hosted.settle()
        return hosted
    }
}

/// BasicStyle, plus the card: a rounded box with a border and a soft shadow, a round checkbox
/// beside its title, controls in a footer while the caret is in it, and a strip of pills for
/// whichever of status, duration, due and scheduled are set.
struct CheckCardStyle: DocStyle {
    var base = BasicStyle(fontSize: 17)
    var shadow = true
    /// The card's text, from the box's left edge: padding, an 18 pt checkbox, a gap.
    static let textInset: CGFloat = 46

    private func cardDepth(_ ancestors: [Node]) -> Int { ancestors.filter { $0.type.name == "card" }.count }

    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        let inCard = cardDepth(ancestors) > 0
        let isCheck: Bool
        if case .checkbox? = marker { isCheck = true } else { isCheck = false }
        var (attrs, deco) = base.paragraph(textblock, ancestors: ancestors, marker: isCheck ? nil : marker)
        guard inCard else { return (attrs, deco) }
        let shift = Self.textInset * CGFloat(cardDepth(ancestors))
        let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent += shift
        style.headIndent += shift
        style.tailIndent = -16
        style.lineHeightMultiple = 1
        style.paragraphSpacing = 2
        attrs[.paragraphStyle] = style
        if let deco, deco.marker != nil { deco.markerRight += shift }
        if case .checkbox? = marker {
            let d = deco ?? BlockDecoration()
            d.font = attrs[.font] as? UIFont ?? base.bodyFont
            d.marker = marker
            d.markerSize = 18
            d.markerRight = style.headIndent - 12
            d.checkStroke = .tertiaryLabel
            d.checkFill = .systemGreen
            deco = d
        }
        return (attrs, deco)
    }

    func inline(_ marks: [Mark], base attrs: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        base.inline(marks, base: attrs, textblock: textblock, ancestors: ancestors)
    }

    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        base.leafBlock(node, ancestors: ancestors)
    }

    func inlineLeaf(_ node: Node, base attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        base.inlineLeaf(node, base: attrs)
    }

    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? {
        if child.type.name == "card" { return .checkbox(checked: child.attrs["checked"]?.boolValue == true, round: true) }
        return base.marker(for: child, in: parent, index: index)
    }

    func chrome(for node: Node) -> ChromeBox? {
        guard node.type.name == "card" else { return nil }
        var box = ChromeBox()
        box.margin = 3
        box.paddingTop = 18
        box.paddingBottom = 18
        box.footer = 30
        box.controlsInset = Self.textInset - 8
        box.cornerRadius = 12
        box.fill = .secondarySystemBackground
        box.border = .separator
        box.activeBorder = .systemBlue
        box.hoverBorder = .systemGray
        box.shadow = shadow ? UIColor(white: 0, alpha: 0.18) : nil
        box.shadowRadius = 8
        return box
    }

    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? { base.chrome(forTextblock: node, ancestors: ancestors) }

    func controls(for node: Node) -> [ChromeControl] {
        guard node.type.name == "card" else { return [] }
        return [ChromeControl(title: "New Card", shortcut: "↵") { CheckCard.newCard(after: $0) },
                ChromeControl(title: "Note", shortcut: "⇥") { CheckCard.addNote(at: $0) },
                ChromeControl(title: "Delete", trailing: true, destructive: true) { CheckCard.delete(at: $0) }]
    }

    func strip(for node: Node) -> ChromeStrip? {
        guard node.type.name == "card" else { return nil }
        func value(_ key: String) -> String? {
            guard let s = node.attrs[key]?.stringValue, !s.isEmpty else { return nil }
            return s
        }
        var pills: [ChromePill] = []
        if let s = value("status") { pills.append(ChromePill(id: "status", text: s, dot: .systemBlue, accessibilityLabel: "Status: \(s)")) }
        if let s = value("duration") { pills.append(ChromePill(id: "duration", text: s, symbol: "clock", accessibilityLabel: "Duration: \(s)")) }
        if let s = value("due") { pills.append(ChromePill(id: "dueDate", text: s, symbol: "calendar", accessibilityLabel: "Due \(s)")) }
        if let s = value("scheduled") {
            pills.append(ChromePill(id: "scheduled", text: s, symbol: "calendar.badge.clock", accessibilityLabel: "Scheduled \(s)"))
        }
        guard !pills.isEmpty else { return nil }
        let size = base.fontSize
        return ChromeStrip(pills: pills, font: .systemFont(ofSize: size * 0.7, weight: .medium),
                           textColor: .secondaryLabel, iconColor: .tertiaryLabel,
                           fill: UIColor(white: 0.5, alpha: 0.12), hoverFill: UIColor(white: 0.5, alpha: 0.2),
                           inset: Self.textInset, trailingInset: 16, topGap: 4, gap: 5, paddingX: 8, paddingY: 2,
                           cornerRadius: 10, iconSize: 10, iconGap: 3, dotSize: 6)
    }

    func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        base.embed(for: node, at: pos, ancestors: ancestors)
    }
}
#endif
