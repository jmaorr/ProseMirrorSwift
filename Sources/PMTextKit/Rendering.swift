#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)
import PMModel
import PMState

// Projection of a ProseMirror document onto a flat attributed string.
//
// Every textblock becomes one string paragraph: its inline content followed by
// "\n". Inside a textblock positions map 1:1 onto UTF-16 offsets (text is
// UTF-16 in both worlds, and every inline leaf renders as exactly one
// character). Block leaves (horizontal rule, image) render as one U+FFFC plus
// "\n". Block structure that has no text of its own (lists, quotes) exists only
// as paragraph styling and decorations, so the open/close tokens of container
// nodes have no string counterpart.

/// What gets drawn in the margin of a paragraph's first line.
public enum BlockMarker: Equatable {
    case bullet(depth: Int)
    case number(Int)
    case checkbox(checked: Bool, round: Bool = false)
    case disclosure(expanded: Bool)
    /// Arbitrary text, right-aligned at the marker edge.
    case label(String)
}

/// Non-text drawing for a paragraph, read by `BlockLayoutFragment`.
public final class BlockDecoration: NSObject {
    public var marker: BlockMarker?
    /// x of the marker's right edge, relative to the text container's line start.
    public var markerRight: CGFloat = 0
    public var markerColor: PlatformColor = .secondaryLabelColor
    /// x positions of vertical quote bars.
    public var quoteBars: [CGFloat] = []
    /// Fill behind the paragraph, from `backgroundInset` to the line end.
    public var background: PlatformColor?
    public var backgroundInset: CGFloat = 0
    /// Draw a horizontal rule through the paragraph (for block leaves like `horizontalRule`).
    public var rule = false
    /// Placeholder label drawn for block leaves that have no native rendering.
    public var leafLabel: String?
    public var font: PlatformFont = .systemFont(ofSize: PlatformFont.systemFontSize)
    public var quoteBarColor: PlatformColor = .tertiaryLabelColor
    public var quoteBarWidth: CGFloat = 3
    public var ruleColor: PlatformColor = .separatorColor
    /// Checked checkbox fill; nil is green for round boxes, the accent colour for square ones.
    public var checkFill: PlatformColor?
    public var checkMark: PlatformColor = .white
    public var checkStroke: PlatformColor = .tertiaryLabelColor
    /// Checkbox corner radius; nil is round for round boxes, 3.5 otherwise.
    public var checkRadius: CGFloat?
    public var backgroundRadius: CGFloat = 0
    /// Side of the checkbox (and disclosure hit area).
    public var markerSize: CGFloat = 14
    /// How much of a strike-through to draw across the paragraph's lines (0...1). nil for a
    /// paragraph that never strikes through, so a tick animation draws none there either.
    public var strikeProgress: CGFloat?

    public override init() {}

    /// By value, so re-rendering an unchanged paragraph leaves its attributes untouched.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? BlockDecoration else { return false }
        return marker == o.marker && markerRight == o.markerRight && markerColor == o.markerColor &&
            quoteBars == o.quoteBars && background == o.background && backgroundInset == o.backgroundInset &&
            rule == o.rule && leafLabel == o.leafLabel && font == o.font &&
            quoteBarColor == o.quoteBarColor && quoteBarWidth == o.quoteBarWidth && ruleColor == o.ruleColor &&
            checkFill == o.checkFill && checkMark == o.checkMark && checkStroke == o.checkStroke &&
            checkRadius == o.checkRadius && backgroundRadius == o.backgroundRadius && strikeProgress == o.strikeProgress &&
            markerSize == o.markerSize
    }

    public override var hash: Int { markerRight.hashValue ^ quoteBars.count ^ (leafLabel?.hashValue ?? 0) }
}

public extension NSAttributedString.Key {
    static let pmBlock = NSAttributedString.Key("pm.blockDecoration")
    /// On a collapsed run's characters: the attributes (an NSDictionary) typing next to it uses.
    static let pmCollapsedRun = NSAttributedString.Key("pm.collapsedRun")
}

/// Native chrome around a container node: a box drawn behind its paragraphs and
/// space reserved for controls while the node is active (the selection is inside it).
/// Vertical values become paragraph spacing; text indentation stays the style's job.
public struct ChromeBox {
    /// Gap kept outside the box, above and below it.
    public var margin: CGFloat = 4
    /// Space between the box edge and the text, above and below.
    public var paddingTop: CGFloat = 8
    public var paddingBottom: CGFloat = 8
    /// Extra height under the content while active, where controls go.
    public var footer: CGFloat = 0
    /// x of the box's left and right edges, from the line start / line end.
    public var insetLeft: CGFloat = 0
    public var insetRight: CGFloat = 0
    /// Where the first control sits, from the box's left edge.
    public var controlsInset: CGFloat = 10
    public var cornerRadius: CGFloat = 10
    public var fill: PlatformColor?
    public var activeFill: PlatformColor?
    public var border: PlatformColor?
    public var activeBorder: PlatformColor?
    /// Border while the pointer is over the box (at rest); nil keeps `border`.
    public var hoverBorder: PlatformColor?
    /// Soft drop shadow around the box while collapsed; fades out as it opens.
    public var shadow: PlatformColor?
    public var shadowRadius: CGFloat = 8
    /// Focus ring drawn outside the border while active.
    public var activeRing: PlatformColor?
    public var activeRingWidth: CGFloat = 3
    /// Tint for the active node's glass buttons.
    public var controlTint: PlatformColor?
    /// While inactive (and done collapsing) the node renders as the one attachment
    /// `DocStyle.collapsed` gives instead of its text; it turns back into text as it activates.
    public var collapsible = false
    /// Takes the active state (and controls) while the selection is in it. False for a purely
    /// visual box, such as a code block's background, which a card around it stays active over.
    public var activates = true

    public init() {}
}

/// A button shown in an active node's footer. `action` gets the node's position.
public struct ChromeControl {
    /// The control's name: what tests and accessibility call it, and its label.
    public var title: String
    public var symbol: String?
    /// A key glyph shown before the label, dimmed ("↵", "⇥").
    public var shortcut: String?
    public var trailing: Bool
    /// Hover tints it red.
    public var destructive: Bool
    public var action: (Int) -> Command

    public init(title: String, symbol: String? = nil, shortcut: String? = nil, trailing: Bool = false,
                destructive: Bool = false, action: @escaping (Int) -> Command) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.trailing = trailing
        self.destructive = destructive
        self.action = action
    }
}

/// A rendered chrome box: the node and the string range of its paragraphs.
public struct ChromeRegion {
    /// Position before the node.
    public var pos: Int
    public var strStart: Int
    /// End of the node's last paragraph, including its "\n".
    public var strEnd: Int
    public var box: ChromeBox
    /// 0 collapsed ... 1 active, as rendered.
    public var progress: CGFloat
    /// Rendered as its collapsed attachment rather than its text.
    public var collapsed = false
    /// Pills drawn under the content (`DocStyle.strip(for:)`), and the height reserved for them
    /// at the renderer's `layoutWidth` when this was rendered.
    public var strip: ChromeStrip? = nil
    public var stripHeight: CGFloat = 0
}

/// A stretch of a textblock's inline content shown as one attachment while the selection
/// isn't in it (a bare URL drawn as a link chip, a URL-only paragraph as a card). The text stays
/// in the storage 1:1, so positions map as usual: the run's first character becomes U+FFFC
/// carrying the attachment and the rest are drawn hidden (near-zero size, clear). The document
/// is never touched; the run turns back into its text when the selection moves into it.
public struct CollapsedRun {
    /// Offsets into the textblock's content (UTF-16 units, so also position offsets).
    public var range: Range<Int>
    /// Opens for a caret at either end too, not only inside. A paragraph-wide card opens at its
    /// edges; an inline chip stays a chip with the caret just before or after it (a selection
    /// of exactly the run, or anything inside it, opens either).
    public var opensAtEdges: Bool
    /// Attributes for the attachment character (an `.attachment` among them). A
    /// `.paragraphStyle` among them restyles the whole paragraph (for a run that fills it).
    public var attributes: () -> [NSAttributedString.Key: Any]

    public init(range: Range<Int>, opensAtEdges: Bool, attributes: @escaping () -> [NSAttributedString.Key: Any]) {
        self.range = range
        self.opensAtEdges = opensAtEdges
        self.attributes = attributes
    }
}

/// A rendered collapsible run: its document range and whether it was drawn collapsed.
public struct RunRegion {
    /// Positions (relative to the block while cached, absolute in `DocRenderer.runs`).
    public var from: Int
    public var to: Int
    public var opensAtEdges: Bool
    public var collapsed: Bool
    /// String offset of its first character (relative like `from`).
    public var strStart: Int
}

/// Styling hooks for the renderer. Implementations decide fonts, indentation and
/// markers per node type; the renderer only walks the document.
public protocol DocStyle {
    /// Attributes for a textblock's paragraph (font, paragraph style, color) plus decorations.
    func paragraph(_ textblock: Node, ancestors: [Node], marker: BlockMarker?) -> ([NSAttributedString.Key: Any], BlockDecoration?)
    /// Attributes for a run of inline content with the given marks, starting from the paragraph's attributes.
    func inline(_ marks: [Mark], base: [NSAttributedString.Key: Any], textblock: Node, ancestors: [Node]) -> [NSAttributedString.Key: Any]
    /// Attributes for a block leaf (horizontal rule, image, ...), rendered as one U+FFFC. An
    /// `.attachment` among them is drawn there (a view, through TextKit 2's view providers).
    func leafBlock(_ node: Node, ancestors: [Node]) -> ([NSAttributedString.Key: Any], BlockDecoration?)
    /// The single character an inline leaf renders as (e.g. "\u{2028}" for a hard break).
    func inlineLeaf(_ node: Node, base: [NSAttributedString.Key: Any]) -> NSAttributedString
    /// The marker for `child` (at `index`) inside `parent`, drawn on child's first textblock.
    func marker(for child: Node, in parent: Node, index: Int) -> BlockMarker?
    /// Chrome for a container node, or nil for none.
    func chrome(for node: Node) -> ChromeBox?
    /// A box behind a textblock (all its lines, as one), given where it sits. Defaults to none.
    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox?
    /// Controls shown while `node` is active.
    func controls(for node: Node) -> [ChromeControl]
    /// Pills drawn inside `node`'s chrome box under its content (a managed task's status and
    /// dates), or nil. Asked only when the node is rendered. Defaults to none.
    func strip(for node: Node) -> ChromeStrip?
    /// Attributes for a non-textblock node shown as one embedded object (a table drawn by its
    /// own view): it renders as one U+FFFC with these attributes (an `.attachment` among them),
    /// and its content isn't rendered as text. `pos` is the position before the node (relative
    /// to whatever is being rendered). Nil renders the node normally.
    func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]?
    /// Attributes (an attachment) for the one character that stands in for an inactive chrome
    /// node whose box is `collapsible`; nil renders its text as usual. `pos` is absolute.
    func collapsed(_ node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]?
    /// Runs of `textblock`'s content to show as attachments while the selection isn't in them.
    /// `pos` is the absolute position of its content start. Defaults to none.
    func collapsedRuns(in textblock: Node, at pos: Int, ancestors: [Node]) -> [CollapsedRun]
}

public extension DocStyle {
    func chrome(for node: Node) -> ChromeBox? { nil }
    func chrome(forTextblock node: Node, ancestors: [Node]) -> ChromeBox? { nil }
    func controls(for node: Node) -> [ChromeControl] { [] }
    func strip(for node: Node) -> ChromeStrip? { nil }
    func embed(for node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? { nil }
    func collapsed(_ node: Node, at pos: Int, ancestors: [Node]) -> [NSAttributedString.Key: Any]? { nil }
    func collapsedRuns(in textblock: Node, at pos: Int, ancestors: [Node]) -> [CollapsedRun] { [] }
}

/// One string paragraph and the document range it renders.
public struct ParagraphSpan {
    /// Textblock: position of its content start. Block leaf: position before the node.
    public var pmStart: Int
    /// UTF-16 length without the trailing "\n" (textblock content size, or 1 for a leaf).
    public var length: Int
    public var strStart: Int
    public var isLeaf: Bool
    /// For an embedded node (`DocStyle.embed`): its size in document positions, all of which
    /// map to its one character. Nil for anything else.
    public var embedSize: Int? = nil
}

/// A rendered top-level block, cached by node identity (nodes are immutable).
final class RenderedBlock {
    let node: Node
    let string: NSAttributedString
    /// Spans with positions relative to the block (pmStart relative to the position before the node).
    let spans: [ParagraphSpan]
    /// Chrome regions, positions and offsets relative to the block.
    let chromes: [ChromeRegion]
    /// Collapsible runs, positions and offsets relative to the block.
    let runs: [RunRegion]
    init(node: Node, string: NSAttributedString, spans: [ParagraphSpan], chromes: [ChromeRegion], runs: [RunRegion]) {
        self.node = node
        self.string = string
        self.spans = spans
        self.chromes = chromes
        self.runs = runs
    }
}

public final class DocRenderer {
    /// Changing it takes effect at the next forced `update`.
    public var style: DocStyle
    private var blocks: [RenderedBlock] = []
    public private(set) var spans: [ParagraphSpan] = []
    public private(set) var chromes: [ChromeRegion] = []
    /// Indices into `chromes`, outer (longer) boxes first: the order boxes draw in. Kept with `chromes`.
    private(set) var chromeDrawOrder: [Int] = []
    /// How far any chrome box, its shadow or ring reaches past its text, above or below (points).
    private(set) var chromeReach: CGFloat = 0
    /// Collapsible runs (`DocStyle.collapsedRuns`), absolute, in document order.
    public private(set) var runs: [RunRegion] = []
    public private(set) var doc: Node?
    /// How expanded the chrome of the node at a position is (0...1). The view animates it.
    public var chromeProgress: (Int) -> CGFloat = { _ in 0 }
    /// Whether the chrome node at a position is active or still animating; a collapsible one
    /// renders collapsed only when it isn't.
    public var chromeOpen: (Int) -> Bool = { _ in false }
    /// Whether a collapsible run (from, to, opensAtEdges) shows as text: the view says so while
    /// the selection is in it. Without a view runs stay collapsed.
    public var runOpen: (_ from: Int, _ to: Int, _ opensAtEdges: Bool) -> Bool = { _, _, _ in false }
    /// Whether the last `refreshChrome` replaced text (a node collapsed or expanded), so the
    /// view's selection needs setting again.
    public private(set) var refreshChangedText = false
    /// Paragraphs (by content start position) whose checkbox flipped in the last update.
    public private(set) var toggledChecks: [Int] = []
    /// The position before the container whose children are rendered (a table cell), or nil
    /// for the whole document.
    public private(set) var scope: Int?
    /// The document position where the rendered content starts: 0, or inside the scope node.
    public var scopeStart: Int { scope.map { $0 + 1 } ?? 0 }
    /// Width of a line of text (the container less its line padding): what chrome strips wrap
    /// to. 0 until the view knows it (strips then take one row). See `setLayoutWidth`.
    public private(set) var layoutWidth: CGFloat = 0
    /// Whether any rendered chrome box has a strip (pointer tracking skips its lookups if not).
    public private(set) var hasStrips = false

    public init(style: DocStyle) { self.style = style }

    /// The width a box's strip has to lay its pills out in.
    func stripWidth(_ strip: ChromeStrip, in box: ChromeBox) -> CGFloat {
        guard layoutWidth > 0 else { return 0 }
        return max(1, layoutWidth - box.insetLeft - box.insetRight - strip.inset - strip.trailingInset)
    }

    /// Height a box's strip reserves at the current `layoutWidth`.
    func stripHeight(_ strip: ChromeStrip?, in box: ChromeBox) -> CGFloat {
        strip.map { $0.height(width: stripWidth($0, in: box)) } ?? 0
    }

    /// The text column is `width` wide now: boxes whose strips wrap differently there are
    /// rendered again (only those). Without `storage` the width is only noted, for the next
    /// render (a view seeds it before rendering a note, so strips don't move once it's laid
    /// out). Returns whether anything changed.
    @discardableResult
    public func setLayoutWidth(_ width: CGFloat, storage: NSTextStorage?) -> Bool {
        guard width != layoutWidth else { return false }
        layoutWidth = width
        guard hasStrips, let storage else { return false }
        return refreshChrome(storage)
    }

    /// Whether a cached block still matches the chrome progress it would get at `offset`.
    private func chromeFresh(_ block: RenderedBlock, at offset: Int) -> Bool {
        block.chromes.allSatisfy { c in
            let pos = offset + c.pos
            if c.box.collapsible, c.collapsed == chromeOpen(pos) { return false }
            if c.strip != nil, stripHeight(c.strip, in: c.box) != c.stripHeight { return false }
            return c.collapsed || chromeProgress(pos) == c.progress
        } && block.runs.allSatisfy { r in
            r.collapsed != runOpen(offset + r.from, offset + r.to, r.opensAtEdges)
        }
    }

    /// Re-style blocks whose chrome progress changed. Only a collapsible node turning into its
    /// attachment or back changes the text (see `refreshChangedText`); otherwise the selection
    /// and marked text stay put. Returns whether anything changed.
    @discardableResult
    public func refreshChrome(_ storage: NSTextStorage) -> Bool {
        var changed = false
        refreshChangedText = false
        var pos = scopeStart, str = 0
        storage.beginEditing()
        for i in blocks.indices {
            let b = blocks[i]
            var length = b.string.length
            if !b.chromes.isEmpty || !b.runs.isEmpty, !chromeFresh(b, at: pos) {
                let fresh = render(b.node, at: pos)
                // A collapsed run keeps the length but swaps its first character for U+FFFC.
                if fresh.string.length == b.string.length, fresh.string.string == b.string.string {
                    fresh.string.enumerateAttributes(in: NSRange(location: 0, length: fresh.string.length)) { attrs, range, _ in
                        storage.setAttributes(attrs, range: NSRange(location: str + range.location, length: range.length))
                    }
                } else {
                    storage.replaceCharacters(in: NSRange(location: str, length: b.string.length), with: fresh.string)
                    refreshChangedText = true
                }
                blocks[i] = fresh
                length = fresh.string.length
                changed = true
            }
            pos += b.node.nodeSize
            str += length
        }
        storage.endEditing()
        if changed { rebuildSpans() }
        return changed
    }

    /// Bring `storage` in line with `doc`, re-rendering only top-level blocks whose node changed.
    /// With `scope` (the position before a container node, such as a table cell) only that
    /// node's children are rendered; positions in spans stay absolute.
    public func update(_ storage: NSTextStorage, to doc: Node, scope: Int? = nil, force: Bool = false) {
        if !force, let current = self.doc, current === doc, scope == self.scope { return }
        let root = scope.flatMap { doc.nodeAt($0) } ?? doc
        self.scope = root === doc ? nil : scope
        let rootStart = scopeStart
        var cache: [ObjectIdentifier: RenderedBlock] = [:]
        if !force { for b in blocks { cache[ObjectIdentifier(b.node)] = b } }
        var newBlocks: [RenderedBlock] = []
        root.forEach { child, offset, _ in
            if let cached = cache[ObjectIdentifier(child)], chromeFresh(cached, at: rootStart + offset) {
                newBlocks.append(cached)
            } else {
                newBlocks.append(render(child, at: rootStart + offset))
            }
        }

        // Replace only the changed middle section of the storage.
        var prefix = 0
        if !force {
            while prefix < blocks.count && prefix < newBlocks.count && blocks[prefix] === newBlocks[prefix] { prefix += 1 }
        }
        var suffix = 0
        if !force {
            while suffix < blocks.count - prefix && suffix < newBlocks.count - prefix &&
                blocks[blocks.count - 1 - suffix] === newBlocks[newBlocks.count - 1 - suffix] { suffix += 1 }
        }
        let oldStart = blocks[0..<prefix].reduce(0) { $0 + $1.string.length }
        // Measured from the storage: AppKit may have edited the changed blocks' text itself.
        let suffixLength = blocks[(blocks.count - suffix)...].reduce(0) { $0 + $1.string.length }
        let oldLength = force ? storage.length : storage.length - oldStart - suffixLength
        let replacement = NSMutableAttributedString()
        for b in newBlocks[prefix..<(newBlocks.count - suffix)] { replacement.append(b.string) }
        storage.beginEditing()
        if force {
            storage.replaceCharacters(in: NSRange(location: 0, length: oldLength), with: replacement)
        } else {
            Self.apply(replacement, to: storage, in: NSRange(location: oldStart, length: oldLength))
        }
        storage.endEditing()

        toggledChecks = force ? [] : Self.toggledChecks(old: Array(blocks[prefix..<(blocks.count - suffix)]),
                                                         new: Array(newBlocks[prefix..<(newBlocks.count - suffix)]),
                                                         offset: rootStart + newBlocks[0..<prefix].reduce(0) { $0 + $1.node.nodeSize })
        blocks = newBlocks
        self.doc = doc
        rebuildSpans()
    }

    /// Checkboxes that flipped between re-rendered blocks standing in the same place.
    private static func toggledChecks(old: [RenderedBlock], new: [RenderedBlock], offset: Int) -> [Int] {
        guard old.count == new.count else { return [] }
        func checks(_ b: RenderedBlock) -> [Bool?] {
            b.spans.map { span -> Bool? in
                guard span.strStart < b.string.length,
                      let d = b.string.attribute(.pmBlock, at: span.strStart, effectiveRange: nil) as? BlockDecoration,
                      case .checkbox(let checked, _) = d.marker else { return nil }
                return checked
            }
        }
        var out: [Int] = []
        var pos = offset
        for (o, n) in zip(old, new) {
            let a = checks(o), b = checks(n)
            if a.count == b.count {
                for k in b.indices where a[k] != nil && b[k] != nil && a[k] != b[k] { out.append(pos + n.spans[k].pmStart) }
            }
            pos += n.node.nodeSize
        }
        return out
    }

    /// Make `storage[range]` equal `replacement`, writing only the characters and attribute
    /// runs that differ. After an edit AppKit made itself the characters already match, so
    /// the text it is tracking (a corrected word, marked text) is left alone.
    private static func apply(_ replacement: NSAttributedString, to storage: NSTextStorage, in range: NSRange) {
        let old = storage.string as NSString, new = replacement.string as NSString
        let common = min(range.length, new.length)
        var prefix = 0
        while prefix < common && old.character(at: range.location + prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < common - prefix &&
            old.character(at: range.upperBound - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if prefix + suffix < range.length || prefix + suffix < new.length {
            storage.replaceCharacters(in: NSRange(location: range.location + prefix, length: range.length - prefix - suffix),
                                      with: replacement.attributedSubstring(from: NSRange(location: prefix, length: new.length - prefix - suffix)))
        }
        replacement.enumerateAttributes(in: NSRange(location: 0, length: new.length)) { attrs, run, _ in
            let target = NSRange(location: range.location + run.location, length: run.length)
            var effective = NSRange()
            let current = storage.attributes(at: target.location, effectiveRange: &effective)
            if NSIntersectionRange(effective, target) == target, (current as NSDictionary).isEqual(to: attrs) { return }
            storage.setAttributes(attrs, range: target)
        }
    }

    private func rebuildSpans() {
        spans.removeAll(keepingCapacity: true)
        chromes.removeAll(keepingCapacity: true)
        runs.removeAll(keepingCapacity: true)
        var pos = scopeStart, str = 0
        for b in blocks {
            for s in b.spans {
                spans.append(ParagraphSpan(pmStart: pos + s.pmStart, length: s.length, strStart: str + s.strStart, isLeaf: s.isLeaf,
                                           embedSize: s.embedSize))
            }
            for var c in b.chromes {
                c.pos += pos
                c.strStart += str
                c.strEnd += str
                chromes.append(c)
            }
            for var r in b.runs {
                r.from += pos
                r.to += pos
                r.strStart += str
                runs.append(r)
            }
            pos += b.node.nodeSize
            str += b.string.length
        }
        hasStrips = chromes.contains { $0.strip != nil }
        chromeDrawOrder = chromes.indices.sorted { chromes[$0].strEnd - chromes[$0].strStart > chromes[$1].strEnd - chromes[$1].strStart }
        chromeReach = chromes.reduce(0) { reach, c in
            let box = c.box
            let outset = max(box.shadow == nil ? 0 : ChromeShadow.extent(blur: box.shadowRadius), box.activeRing == nil ? 0 : box.activeRingWidth)
            return max(reach, max(box.paddingTop, box.paddingBottom + box.footer + c.stripHeight) + outset + 1)
        }
    }

    /// `offset` is the block's absolute position, used to look up chrome progress.
    private func render(_ node: Node, at offset: Int) -> RenderedBlock {
        let out = NSMutableAttributedString()
        var spans: [ParagraphSpan] = []
        var chromes: [ChromeRegion] = []
        var runs: [RunRegion] = []
        walk(node, pos: 0, offset: offset, ancestors: [], marker: nil, out: out, spans: &spans, chromes: &chromes, runs: &runs)
        return RenderedBlock(node: node, string: out, spans: spans, chromes: chromes, runs: runs)
    }

    /// Reserve the chrome's vertical space as paragraph spacing on its first and last paragraphs.
    private func applyChrome(_ box: ChromeBox, progress: CGFloat, stripHeight: CGFloat = 0, to out: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let string = out.string as NSString
        let first = string.paragraphRange(for: NSRange(location: range.location, length: 0))
        let last = string.paragraphRange(for: NSRange(location: range.upperBound - 1, length: 0))
        func adjust(_ paragraph: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            out.enumerateAttribute(.paragraphStyle, in: paragraph) { value, run, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                change(style)
                out.addAttribute(.paragraphStyle, value: style, range: run)
            }
        }
        adjust(first) { $0.paragraphSpacingBefore = box.margin + box.paddingTop }
        adjust(last) { $0.paragraphSpacing = stripHeight + box.paddingBottom + box.footer * progress + box.margin }
    }

    /// `pos` is relative to the start of the top-level block being rendered.
    private func walk(_ node: Node, pos: Int, offset: Int, ancestors: [Node], marker: BlockMarker?, out: NSMutableAttributedString,
                      spans: inout [ParagraphSpan], chromes: inout [ChromeRegion], runs: inout [RunRegion]) {
        if !node.isTextblock && !node.isLeaf, let attrs = style.embed(for: node, at: offset + pos, ancestors: ancestors) {
            // An attachment goes on the object character only, as for block leaves.
            var lineEnd = attrs
            lineEnd[.attachment] = nil
            let start = out.length
            out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: lineEnd))
            spans.append(ParagraphSpan(pmStart: pos, length: 1, strStart: start, isLeaf: true, embedSize: node.nodeSize))
        } else if node.isTextblock {
            let (attrs, deco) = style.paragraph(node, ancestors: ancestors, marker: marker)
            var paraAttrs = attrs
            if let deco { paraAttrs[.pmBlock] = deco }
            let start = out.length
            node.forEach { child, _, _ in
                if let text = child as? TextNode {
                    out.append(NSAttributedString(string: text.string, attributes: style.inline(child.marks, base: paraAttrs, textblock: node, ancestors: ancestors)))
                } else {
                    let base = style.inline(child.marks, base: paraAttrs, textblock: node, ancestors: ancestors)
                    let leaf = style.inlineLeaf(child, base: base)
                    precondition(leaf.length == 1, "inline leaves must render as one UTF-16 unit")
                    out.append(leaf)
                }
            }
            out.append(NSAttributedString(string: "\n", attributes: paraAttrs))
            spans.append(ParagraphSpan(pmStart: pos + 1, length: node.content.size, strStart: start, isLeaf: false))
            collapseRuns(in: node, contentPos: pos + 1, offset: offset, ancestors: ancestors, paraAttrs: paraAttrs,
                         strStart: start, out: out, runs: &runs)
            if var box = style.chrome(forTextblock: node, ancestors: ancestors) {
                box.activates = false
                applyChrome(box, progress: 0, to: out, range: NSRange(location: start, length: out.length - start))
                chromes.append(ChromeRegion(pos: pos, strStart: start, strEnd: out.length, box: box, progress: 0))
            }
        } else if node.isLeaf {
            let (attrs, deco) = style.leafBlock(node, ancestors: ancestors)
            var paraAttrs = attrs
            if let deco { paraAttrs[.pmBlock] = deco }
            let start = out.length
            // An attachment (a view drawn for the leaf) goes on the object character only.
            var lineEnd = paraAttrs
            lineEnd[.attachment] = nil
            out.append(NSAttributedString(string: "\u{FFFC}", attributes: paraAttrs))
            out.append(NSAttributedString(string: "\n", attributes: lineEnd))
            spans.append(ParagraphSpan(pmStart: pos, length: 1, strStart: start, isLeaf: true))
        } else if let box = style.chrome(for: node), box.collapsible, !chromeOpen(offset + pos),
                  let attrs = style.collapsed(node, at: offset + pos, ancestors: ancestors) {
            // An inactive collapsible node: one attachment character for the whole node.
            var lineEnd = attrs
            lineEnd[.attachment] = nil
            let start = out.length
            out.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: lineEnd))
            spans.append(ParagraphSpan(pmStart: pos, length: 1, strStart: start, isLeaf: true, embedSize: node.nodeSize))
            let range = NSRange(location: start, length: out.length - start)
            applyChrome(box, progress: 0, to: out, range: range)
            chromes.append(ChromeRegion(pos: pos, strStart: start, strEnd: out.length, box: box, progress: 0, collapsed: true))
        } else {
            let inner = ancestors + [node]
            let start = out.length
            var first = true
            var index = 0
            node.forEach { child, childOffset, _ in
                // A container's own marker goes on its first textblock; children may bring their own.
                let childMarker = style.marker(for: child, in: node, index: index) ?? (first ? marker : nil)
                walk(child, pos: pos + 1 + childOffset, offset: offset, ancestors: inner, marker: childMarker, out: out,
                     spans: &spans, chromes: &chromes, runs: &runs)
                first = false
                index += 1
            }
            if var box = style.chrome(for: node) {
                let progress = chromeProgress(offset + pos)
                // Shown as text while closed: the style gave no attachment, so don't expect one.
                if box.collapsible, !chromeOpen(offset + pos) { box.collapsible = false }
                let strip = style.strip(for: node)
                let stripHeight = stripHeight(strip, in: box)
                applyChrome(box, progress: progress, stripHeight: stripHeight, to: out, range: NSRange(location: start, length: out.length - start))
                chromes.append(ChromeRegion(pos: pos, strStart: start, strEnd: out.length, box: box, progress: progress,
                                            strip: strip, stripHeight: stripHeight))
            }
        }
    }

    /// Font for a collapsed run's hidden characters: as near zero width as TextKit allows.
    private static let hiddenFont = PlatformFont.systemFont(ofSize: 0.01)

    /// Draw the style's collapsible runs in a just-rendered textblock as attachments, unless open.
    private func collapseRuns(in node: Node, contentPos: Int, offset: Int, ancestors: [Node], paraAttrs: [NSAttributedString.Key: Any],
                              strStart: Int, out: NSMutableAttributedString, runs: inout [RunRegion]) {
        let size = node.content.size
        for run in style.collapsedRuns(in: node, at: offset + contentPos, ancestors: ancestors)
        where run.range.lowerBound >= 0 && run.range.upperBound <= size && !run.range.isEmpty {
            let from = contentPos + run.range.lowerBound, to = contentPos + run.range.upperBound
            let open = runOpen(offset + from, offset + to, run.opensAtEdges)
            let first = strStart + run.range.lowerBound
            runs.append(RunRegion(from: from, to: to, opensAtEdges: run.opensAtEdges, collapsed: !open, strStart: first))
            guard !open else { continue }
            var attrs = paraAttrs
            for (key, value) in run.attributes() { attrs[key] = value }
            // What typing next to the run uses, rather than the hidden characters' look.
            attrs[.pmCollapsedRun] = paraAttrs as NSDictionary
            let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
            if let paragraphStyle, paragraphStyle !== paraAttrs[.paragraphStyle] as? NSParagraphStyle {
                out.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: strStart, length: size + 1))
            }
            out.replaceCharacters(in: NSRange(location: first, length: 1), with: NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            if run.range.count > 1 {
                var hidden = paraAttrs
                hidden[.paragraphStyle] = paragraphStyle
                hidden[.font] = Self.hiddenFont
                hidden[.foregroundColor] = PlatformColor.clear
                hidden[.pmCollapsedRun] = paraAttrs as NSDictionary
                out.setAttributes(hidden, range: NSRange(location: first + 1, length: run.range.count - 1))
            }
        }
    }

    // MARK: Position mapping

    /// Index of the last span with `key(span) <= value`, or nil.
    private func lastSpan(where key: (ParagraphSpan) -> Int, atMost value: Int) -> Int? {
        var lo = 0, hi = spans.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if key(spans[mid]) <= value { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// String offset for a document position. Positions between textblocks snap
    /// forward (bias > 0) to the next paragraph start, or backward to the previous paragraph end.
    public func stringOffset(_ pos: Int, bias: Int = 1) -> Int {
        guard !spans.isEmpty else { return 0 }
        guard let i = lastSpan(where: { $0.pmStart }, atMost: pos) else { return spans[0].strStart }
        let s = spans[i]
        // Between two block leaves (an image right before a file card), the end of a range
        // (bias < 0) stays on the first one's character rather than reaching the second's.
        if bias < 0, pos == s.pmStart, i > 0, spans[i - 1].isLeaf,
           spans[i - 1].pmStart + (spans[i - 1].embedSize ?? spans[i - 1].length) == pos {
            return spans[i - 1].strStart + 1
        }
        if let size = s.embedSize {
            // Every position inside an embedded node maps to its one character.
            if pos == s.pmStart { return s.strStart }
            if pos < s.pmStart + size { return bias > 0 ? s.strStart + 1 : s.strStart }
            if bias > 0, i + 1 < spans.count { return spans[i + 1].strStart }
            return s.strStart + 1
        }
        if pos <= s.pmStart + s.length { return s.strStart + (pos - s.pmStart) }
        if bias > 0, i + 1 < spans.count { return spans[i + 1].strStart }
        return s.strStart + s.length
    }

    /// Document position for a string offset, and the span it falls in.
    public func docPosition(_ offset: Int) -> (pos: Int, span: ParagraphSpan)? {
        guard let i = lastSpan(where: { $0.strStart }, atMost: offset) else { return nil }
        let s = spans[i]
        if let size = s.embedSize { return (offset > s.strStart ? s.pmStart + size : s.pmStart, s) }
        return (s.pmStart + min(offset - s.strStart, s.length), s)
    }

    public func span(atString offset: Int) -> ParagraphSpan? {
        lastSpan(where: { $0.strStart }, atMost: offset).map { spans[$0] }
    }
}
#endif
