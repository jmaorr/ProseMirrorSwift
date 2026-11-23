// A plain DocStyle for BasicSchema documents: system fonts and dynamic system colours, so it
// follows light and dark mode on macOS and iOS without being restyled.
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
import PMTableView

/// How `BasicSchema` documents look in a `ProseTextView`: system fonts, dynamic system colours
/// (light and dark), headings 1–6, bullet and number markers, a bar beside block quotes, a
/// rounded box behind code blocks, links, inline code, horizontal rules, image placeholders,
/// and tables drawn by PMTableView's native grid.
///
/// Use `makeTextView(state:)` to get a text view with tables wired up. A text view made with
/// `ProseTextView(state:style:)` directly works too, but shows table cells as plain paragraphs.
///
/// Every value is a plain property, so a copy can be adjusted before use:
///
/// ```swift
/// var style = BasicStyle()
/// style.fontSize = 16
/// let textView = style.makeTextView(state: state)
/// ```
public struct BasicStyle: DocStyle {
    /// Body text size in points. Headings and code scale from it.
    public var fontSize: CGFloat
    /// Heading sizes as multiples of `fontSize`, for levels 1 to 6.
    public var headingScale: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.9]
    /// Line height as a multiple of the font's.
    public var lineHeight: CGFloat = 1.25
    /// Space after a paragraph, as a multiple of `fontSize`.
    public var paragraphSpacing: CGFloat = 0.6
    /// How far each level of list indents its items.
    public var listIndent: CGFloat = 24
    /// How far a block quote indents its content (its bar sits in that space).
    public var quoteIndent: CGFloat = 16
    /// Body text colour.
    public var textColor: PlatformColor = .labelColor
    /// Block quote text, list markers and level 6 headings.
    public var secondaryTextColor: PlatformColor = .secondaryLabelColor
    /// Link text.
    public var linkColor: PlatformColor = .linkColor
    /// The bar beside a block quote.
    public var quoteBarColor: PlatformColor = .tertiaryLabelColor
    /// Horizontal rules.
    public var ruleColor: PlatformColor = .separatorColor
    /// The box behind a code block.
    public var codeBlockBackground: PlatformColor = BasicStyle.dynamic(light: PlatformColor(white: 0, alpha: 0.05),
                                                                       dark: PlatformColor(white: 1, alpha: 0.08))
    /// Behind inline code.
    public var inlineCodeBackground: PlatformColor = BasicStyle.dynamic(light: PlatformColor(white: 0, alpha: 0.07),
                                                                        dark: PlatformColor(white: 1, alpha: 0.12))
    /// The document's tables, drawn as native grids. `makeTextView(state:)` sets it; without
    /// it table cells render as plain paragraphs.
    public var tables: TableEmbeds?

    /// A style with body text at `fontSize` points: by default 14 on macOS and the body text
    /// style's size (Dynamic Type) on iOS.
    public init(fontSize: CGFloat? = nil) {
        #if os(macOS)
        self.fontSize = fontSize ?? 14
        #else
        self.fontSize = fontSize ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
    }

    /// The body font.
    public var bodyFont: PlatformFont { .systemFont(ofSize: fontSize) }

    /// The font of a heading at `level` (1–6).
    public func headingFont(level: Int) -> PlatformFont {
        let index = min(6, max(1, level)) - 1
        return .systemFont(ofSize: (fontSize * headingScale[index]).rounded(), weight: index < 2 ? .bold : .semibold)
    }

    /// Table colours, for `TableEmbeds`: system colours, so tables follow light and dark mode too.
    public var tableStyle: TableStyle {
        var style = TableStyle()
        style.rule = ruleColor
        style.headerFill = codeBlockBackground
        return style
    }

    /// A text view showing `state` in this style, with tables drawn by PMTableView. The text
    /// view keeps the tables (through its style) for as long as it lives.
    ///
    /// To restyle it later, keep `tables` on the new style: `textView.setStyle(newStyle)` with
    /// a style whose `tables` is nil turns tables back into paragraphs.
    @MainActor
    public func makeTextView(state: EditorState) -> ProseTextView {
        let core = EditorCore(state: state)
        var cellStyle = self
        cellStyle.tables = nil
        var style = self
        style.tables = TableEmbeds(core: core, tableStyle: tableStyle, cellStyle: cellStyle)
        let textView = ProseTextView(core: core, style: style)
        #if os(iOS)
        // Tables are view-only on iOS: typing over a selected table leaves it be.
        textView.keepsSelectedNode = { $0.type.tableRole == .table }
        #endif
        return textView
    }

    // MARK: DocStyle

    /// Paragraph attributes for a textblock: its font, colour, indentation and spacing, plus the
    /// marker and quote bars drawn beside it.
    public func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        let (x, bars) = indent(ancestors)
        let inCell = Self.inCell(ancestors)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = x
        style.headIndent = x
        style.lineHeightMultiple = inCell ? 1 : lineHeight
        style.paragraphSpacing = fontSize * paragraphSpacing * (inCell ? 0.5 : 1)
        if ancestors.last?.type.name == "list_item" { style.paragraphSpacing = fontSize * 0.25 }
        var font = bodyFont
        var color = textColor

        switch textblock.type.name {
        case "heading":
            let level = textblock.attrs["level"]?.intValue ?? 1
            font = headingFont(level: level)
            if level >= 6 { color = secondaryTextColor }
            style.lineHeightMultiple = 1.1
            style.paragraphSpacingBefore = inCell ? 0 : font.pointSize * 0.5
            style.paragraphSpacing = fontSize * 0.4
        case "code_block":
            font = .monospacedSystemFont(ofSize: (fontSize * 0.9).rounded(), weight: .regular)
            style.lineHeightMultiple = 1
            style.lineSpacing = font.pointSize * 0.3
            style.paragraphSpacing = 0
            // Padding inside the box `chrome(forTextblock:ancestors:)` draws.
            style.firstLineHeadIndent = x + Self.codePadding
            style.headIndent = x + Self.codePadding
            style.tailIndent = -Self.codePadding
        default:
            break
        }
        if ancestors.contains(where: { $0.type.name == "blockquote" }) { color = secondaryTextColor }

        var deco: BlockDecoration?
        func decoration() -> BlockDecoration {
            if let deco { return deco }
            let d = BlockDecoration()
            d.font = font
            d.quoteBarColor = quoteBarColor
            deco = d
            return d
        }
        if !bars.isEmpty { decoration().quoteBars = bars }
        if let marker {
            let d = decoration()
            if case .bullet = marker {
                d.marker = .bullet(depth: max(0, ancestors.filter { $0.type.name == "bullet_list" }.count - 1))
            } else {
                d.marker = marker
            }
            d.markerColor = secondaryTextColor
            d.markerRight = x - 8
        }
        return ([.font: font, .paragraphStyle: style, .foregroundColor: color], deco)
    }

    /// Inline attributes for marked text: `strong` bold, `em` italic, `code` monospaced on a
    /// tinted background, `link` coloured and underlined (with its address as the tooltip).
    public func inline(_ marks: [Mark], base: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any] {
        guard !marks.isEmpty else { return base }
        var attrs = base
        var font = base[.font] as? PlatformFont ?? bodyFont
        var bold = false, italic = false
        for mark in marks {
            switch mark.type.name {
            case "strong": bold = true
            case "em": italic = true
            case "code":
                font = .monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: .regular)
                attrs[.backgroundColor] = inlineCodeBackground
            case "link":
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.pmToolTip] = mark.attrs["href"]?.stringValue
            default:
                break
            }
        }
        attrs[.font] = font.adding(bold: bold, italic: italic)
        return attrs
    }

    /// Block leaves: a `horizontal_rule` draws a line across the column; anything else a label.
    public func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?) {
        let (x, bars) = indent(ancestors)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = x
        style.headIndent = x
        style.paragraphSpacingBefore = fontSize * 0.3
        style.paragraphSpacing = fontSize * paragraphSpacing
        let d = BlockDecoration()
        d.font = bodyFont
        d.quoteBars = bars
        d.quoteBarColor = quoteBarColor
        d.ruleColor = ruleColor
        d.backgroundInset = x
        if node.type.name == "horizontal_rule" {
            d.rule = true
        } else {
            d.leafLabel = node.type.name
            d.background = codeBlockBackground
            style.minimumLineHeight = fontSize * 2
        }
        return ([.font: bodyFont, .paragraphStyle: style, .foregroundColor: PlatformColor.clear], d)
    }

    /// Inline leaves: a `hard_break` is a line separator; an `image` is a photo symbol standing
    /// in for the picture (with its alt text as the tooltip). Loading `src` is left to apps.
    public func inlineLeaf(_ node: Node, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node.type.name {
        case "hard_break":
            return NSAttributedString(string: "\u{2028}", attributes: base)
        default:
            let alt = node.attrs["alt"]?.stringValue
            let attachment = NSTextAttachment()
            attachment.image = PlatformImage.symbol("photo", accessibilityDescription: alt ?? node.type.name)
            let side = (base[.font] as? PlatformFont)?.pointSize ?? fontSize
            attachment.bounds = CGRect(x: 0, y: -side * 0.15, width: side * 1.25, height: side)
            var attrs = base
            attrs[.attachment] = attachment
            attrs[.pmToolTip] = alt ?? node.attrs["src"]?.stringValue
            return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
        }
    }

    /// Bullets for `bullet_list` items and numbers (from the list's `order`) for `ordered_list` items.
    public func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker? {
        switch parent.type.name {
        case "bullet_list": return .bullet(depth: 0)
        case "ordered_list":
            // `order` is an untrusted attr: don't let the sum overflow.
            let (n, overflow) = (parent.attrs["order"]?.intValue ?? 1).addingReportingOverflow(index)
            return .number(overflow ? Int.max : n)
        default: return nil
        }
    }

    /// A rounded box behind each code block.
    public func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? {
        guard node.type.name == "code_block" else { return nil }
        var box = ChromeBox()
        box.margin = fontSize * 0.4
        box.paddingTop = Self.codePadding * 0.75
        box.paddingBottom = Self.codePadding * 0.75
        box.insetLeft = indent(ancestors).indent
        box.cornerRadius = 6
        box.fill = codeBlockBackground
        return box
    }

    /// A table as one native grid (through `tables`), or nil without `tables`.
    public func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? {
        guard node.type.tableRole == .table, let tables else { return nil }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = fontSize * 0.4
        style.paragraphSpacing = fontSize * paragraphSpacing
        return tables.attributes(for: node, at: pos, paragraph: [.font: bodyFont, .paragraphStyle: style])
    }

    // MARK: Helpers

    /// Inside a code block, between the box's edge and the text.
    static let codePadding: CGFloat = 12

    /// The indent of a block with these ancestors, and the x of each quote bar beside it.
    private func indent(_ ancestors: [Node]) -> (indent: CGFloat, bars: [CGFloat]) {
        var x: CGFloat = 0
        var bars: [CGFloat] = []
        // Room is short in a table cell: lists and quotes indent less.
        let scale: CGFloat = Self.inCell(ancestors) ? 0.7 : 1
        for node in ancestors {
            switch node.type.name {
            case "bullet_list", "ordered_list":
                x += listIndent * scale
            case "blockquote":
                bars.append(x + 2)
                x += quoteIndent * scale
            default:
                break
            }
        }
        return (x, bars)
    }

    private static func inCell(_ ancestors: [Node]) -> Bool {
        ancestors.contains { $0.type.tableRole == .cell || $0.type.tableRole == .headerCell }
    }

    /// A colour that is `light` in light mode and `dark` in dark mode.
    public static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        #else
        return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}
#endif
