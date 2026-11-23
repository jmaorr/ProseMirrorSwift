#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)

/// Rendered text laid out at a width and drawn outside a text view, with the same layout
/// fragments and block decorations (list markers, quote bars) a `ProseTextView` draws: a
/// table cell that isn't being edited.
public final class TextSnapshot: NSObject, NSTextLayoutManagerDelegate {
    public let string: NSAttributedString
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer

    public init(_ string: NSAttributedString, width: CGFloat) {
        self.string = string
        container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        super.init()
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        layoutManager.delegate = self
        contentStorage.attributedString = string
    }

    public var width: CGFloat {
        get { container.size.width }
        set {
            guard newValue != container.size.width else { return }
            container.size = CGSize(width: max(newValue, 1), height: .greatestFiniteMagnitude)
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
        }
    }

    /// The laid-out text's height.
    public var height: CGFloat {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    /// The width the text needs without wrapping (its longest line).
    public var naturalWidth: CGFloat {
        let wide = TextSnapshot(string, width: 100_000)
        wide.layoutManager.ensureLayout(for: wide.layoutManager.documentRange)
        var widest: CGFloat = 0
        wide.layoutManager.enumerateTextLayoutFragments(from: wide.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                widest = max(widest, fragment.layoutFragmentFrame.minX + bounds.maxX)
            }
            return true
        }
        return ceil(widest)
    }

    /// Draws the text with its top-left at `origin`, into a flipped (top-down) context.
    public func draw(in context: CGContext, at origin: CGPoint) {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let block = fragment as? BlockLayoutFragment, block.decoration != nil {
                block.drawDecoration(origin: origin, lineStart: 0, lineWidth: container.size.width)
            }
            fragment.draw(at: CGPoint(x: origin.x + fragment.layoutFragmentFrame.minX, y: origin.y + fragment.layoutFragmentFrame.minY),
                          in: context)
            return true
        }
    }

    /// Rects (in the snapshot's coordinates) covering a character range.
    public func rects(for range: NSRange) -> [CGRect] {
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var out: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            out.append(rect)
            return true
        }
        return out
    }

    /// The character offset nearest `point`, or nil past the text.
    public func characterIndex(at point: CGPoint) -> Int? {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        for line in fragment.textLineFragments where line.typographicBounds.maxY >= local.y {
            let index = line.characterIndex(for: CGPoint(x: local.x, y: line.typographicBounds.midY))
            let base = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            return base + index
        }
        return nil
    }

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            fragment.decoration = paragraph.attributedString.attribute(.pmBlock, at: 0, effectiveRange: nil) as? BlockDecoration
        }
        return fragment
    }
}
#endif
