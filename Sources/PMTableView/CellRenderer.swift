#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if os(macOS) || os(iOS)
import PMModel
import PMTextKit

/// One cell's content rendered and laid out, for drawing while the cell isn't being edited.
/// Positions are relative to the cell's content start.
public final class RenderedCell {
    public let node: Node
    public let string: NSAttributedString
    /// Paragraph spans; `pmStart` relative to the cell's content start.
    public let spans: [ParagraphSpan]
    public let text: TextSnapshot

    init(node: Node, style: CellDocStyle, width: CGFloat) {
        self.node = node
        var style = style
        style.header = node.type.tableRole == .headerCell
        style.cell = node
        let renderer = DocRenderer(style: style)
        let storage = NSTextStorage()
        // The cell is the root: its children are the rendered blocks.
        renderer.update(storage, to: node, force: true)
        string = NSAttributedString(attributedString: storage)
        spans = renderer.spans
        // The final paragraph break would add an empty line below the text.
        var drawn = string.length > 0 && string.string.hasSuffix("\n")
            ? string.attributedSubstring(from: NSRange(location: 0, length: string.length - 1)) : string
        // An empty cell still has a line: lay out an invisible character in the paragraph's
        // style, so the row is as tall as once something is typed.
        if drawn.length == 0, string.length > 0 {
            drawn = NSAttributedString(string: "\u{200B}", attributes: string.attributes(at: 0, effectiveRange: nil))
        }
        text = TextSnapshot(drawn, width: width)
    }

    private var measured: (width: CGFloat, height: CGFloat)?

    public func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        text.width = width
        let height = text.height
        measured = (width, height)
        return height
    }

    /// Rects covering `range` of the cell's string.
    public func rects(for range: NSRange) -> [CGRect] { text.rects(for: range) }

    /// The string offset under `point` (relative to the cell's content box).
    public func characterIndex(at point: CGPoint) -> Int? { text.characterIndex(at: point) }

    /// The document position, relative to the cell's content start, for a string offset.
    public func position(atString offset: Int) -> Int? {
        guard let span = spans.last(where: { $0.strStart <= offset }) else { return nil }
        if let size = span.embedSize { return offset > span.strStart ? span.pmStart + size : span.pmStart }
        return span.pmStart + min(offset - span.strStart, span.length)
    }
}

/// Rendered cells by node identity (nodes are immutable), so typing in one cell re-renders
/// only that cell.
public final class CellCache {
    private var cells: [ObjectIdentifier: RenderedCell] = [:]
    private var order: [ObjectIdentifier] = []
    public let limit: Int

    public init(limit: Int = 2000) { self.limit = limit }

    public func cell(for node: Node, style: CellDocStyle, width: CGFloat) -> RenderedCell {
        let key = ObjectIdentifier(node)
        if let cached = cells[key], cached.node === node {
            cached.text.width = width
            return cached
        }
        let rendered = RenderedCell(node: node, style: style, width: width)
        cells[key] = rendered
        order.append(key)
        if order.count > limit {
            let drop = order.removeFirst()
            cells[drop] = nil
        }
        return rendered
    }

    public func removeAll() {
        cells.removeAll()
        order.removeAll()
    }
}

/// Something drawn over a cell's text: a misspelling underline or a find highlight.
public struct CellOverlay: Equatable {
    public enum Kind: Equatable {
        case underline(PlatformColor)
        case highlight(PlatformColor)
    }

    public var range: NSRange
    public var kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Draws one cell's text (and any overlays) inside its padding.
public final class CellLayer: CALayer {
    public var cell: RenderedCell? { didSet { setNeedsDisplay() } }
    /// Drawn over the text. Unused in v1; spelling and Find in tables will fill it.
    public var overlays: [CellOverlay] = [] { didSet { setNeedsDisplay() } }
    public var padding = TableInsets()
    /// The cell's resting fill (header cells); the layer's background shows it.
    public var fill: CGColor? { didSet { backgroundColor = fill } }
    /// The cell editor is over this cell: draw its fill and rules but not its text.
    public var hidesText = false { didSet { if hidesText != oldValue { setNeedsDisplay() } } }
    #if os(macOS)
    /// The table's appearance. Core Animation draws layers with whatever appearance happens
    /// to be current (often the light one), so the text's dynamic colours resolve against
    /// this instead: dark mode text stays light.
    public var drawingAppearance: NSAppearance? {
        didSet { if drawingAppearance?.name != oldValue?.name { setNeedsDisplay() } }
    }
    #else
    /// The table's traits (iOS): the text's dynamic colours resolve against these when the
    /// layer draws, so dark mode text stays light.
    public var drawingTraits: UITraitCollection? {
        didSet {
            if drawingTraits?.userInterfaceStyle != oldValue?.userInterfaceStyle
                || drawingTraits?.accessibilityContrast != oldValue?.accessibilityContrast { setNeedsDisplay() }
        }
    }
    #endif

    public override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        // Redrawn at the new size at once; while the frame slides, the text stays put rather
        // than stretching.
        contentsGravity = .topLeft
        masksToBounds = true
        #if os(macOS)
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        #else
        let scale = UITraitCollection.current.displayScale
        contentsScale = scale > 0 ? scale : 2
        #endif
    }

    public override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? CellLayer {
            cell = other.cell
            overlays = other.overlays
            padding = other.padding
            fill = other.fill
            hidesText = other.hidesText
            #if os(macOS)
            drawingAppearance = other.drawingAppearance
            #else
            drawingTraits = other.drawingTraits
            #endif
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(in ctx: CGContext) {
        #if os(macOS)
        guard let appearance = drawingAppearance else { return drawCell(in: ctx) }
        appearance.performAsCurrentDrawingAppearance { drawCell(in: ctx) }
        #else
        guard let traits = drawingTraits else { return drawCell(in: ctx) }
        traits.performAsCurrent { drawCell(in: ctx) }
        #endif
    }

    private func drawCell(in ctx: CGContext) {
        guard let cell, !hidesText else { return }
        // Layers draw bottom-up on macOS; text draws top-down. (UIKit's layer contexts are
        // top-down already.)
        ctx.saveGState()
        #if os(macOS)
        let flip = !contentsAreFlipped()
        #else
        let flip = false
        #endif
        if flip {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let origin = CGPoint(x: padding.left, y: padding.top)
        for overlay in overlays {
            guard case .highlight(let color) = overlay.kind else { continue }
            ctx.setFillColor(color.cgColor)
            for rect in cell.rects(for: overlay.range) { ctx.fill(rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        cell.text.draw(in: ctx, at: origin)
        for overlay in overlays {
            guard case .underline(let color) = overlay.kind else { continue }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            for rect in cell.rects(for: overlay.range) {
                let y = origin.y + rect.maxY - 1
                ctx.move(to: CGPoint(x: origin.x + rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: origin.x + rect.maxX, y: y))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
#endif
