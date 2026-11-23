#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)

/// One pill in a chrome box's strip: a label after a status dot or a symbol.
public struct ChromePill: Equatable {
    /// What the pill stands for ("status", "dueDate"): the tap callback gets it.
    public var id: String
    public var text: String
    /// SF Symbol drawn before the text; nil draws `dot` (or nothing).
    public var symbol: String?
    /// A small round dot before the text (a status colour), when there's no symbol.
    public var dot: PlatformColor?
    /// What VoiceOver says for it ("Status: In progress", "Due Nov 21").
    public var accessibilityLabel: String

    public init(id: String, text: String, symbol: String? = nil, dot: PlatformColor? = nil, accessibilityLabel: String) {
        self.id = id
        self.text = text
        self.symbol = symbol
        self.dot = dot
        self.accessibilityLabel = accessibilityLabel
    }
}

/// A row of small pills drawn inside a chrome box under its content (a managed task card's
/// status, duration and dates). Not text: the box grows to fit it, as it does for its footer,
/// and the pills wrap onto more rows when the box is narrow. Sizes are in points, already
/// scaled by the style's zoom. Widths are measured once, when it's made.
public struct ChromeStrip {
    public private(set) var pills: [ChromePill]
    public let font: PlatformFont
    public let textColor: PlatformColor
    /// Symbols and the fallback dot.
    public var iconColor: PlatformColor
    public var fill: PlatformColor
    /// Fill of the pill under the pointer.
    public var hoverFill: PlatformColor
    /// Where the pills start, from the box's left edge (the card's text column).
    public var inset: CGFloat
    /// Room kept clear at the box's right edge.
    public var trailingInset: CGFloat
    /// Space between the content above and the first row.
    public var topGap: CGFloat
    /// Between pills, and between rows.
    public var gap: CGFloat
    public var paddingX: CGFloat
    public var paddingY: CGFloat
    public var cornerRadius: CGFloat
    public var iconSize: CGFloat
    public var iconGap: CGFloat
    public var dotSize: CGFloat
    /// Each pill's width, padding included.
    public private(set) var widths: [CGFloat] = []
    public private(set) var pillHeight: CGFloat = 0
    /// Each pill's label, set once.
    private var labels: [NSAttributedString] = []

    public init(pills: [ChromePill], font: PlatformFont, textColor: PlatformColor, iconColor: PlatformColor, fill: PlatformColor,
                hoverFill: PlatformColor, inset: CGFloat, trailingInset: CGFloat, topGap: CGFloat = 4, gap: CGFloat = 5,
                paddingX: CGFloat = 8, paddingY: CGFloat = 2, cornerRadius: CGFloat = 10, iconSize: CGFloat = 10,
                iconGap: CGFloat = 3, dotSize: CGFloat = 6) {
        self.pills = pills
        self.font = font
        self.textColor = textColor
        self.iconColor = iconColor
        self.fill = fill
        self.hoverFill = hoverFill
        self.inset = inset
        self.trailingInset = trailingInset
        self.topGap = topGap
        self.gap = gap
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.cornerRadius = cornerRadius
        self.iconSize = iconSize
        self.iconGap = iconGap
        self.dotSize = dotSize
        measure()
    }

    private mutating func measure() {
        // The web pill's line height (1.4) plus its padding.
        pillHeight = ceil(font.pointSize * 1.4 + 2 * paddingY)
        labels = pills.map { NSAttributedString(string: $0.text, attributes: [.font: font, .foregroundColor: textColor]) }
        widths = zip(pills, labels).map { pill, label in
            let text = ceil(label.size().width)
            let lead = pill.symbol != nil ? iconSize + iconGap : pill.dot != nil ? dotSize + iconGap : 0
            return ceil(lead + text + 2 * paddingX)
        }
    }

    /// The pills' frames for a strip `width` wide, from its top left (the gap above included).
    /// A pill wider than the strip gets a row to itself, at its own width. Width 0 or less is
    /// unlimited: one row.
    public func frames(width: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        var x: CGFloat = 0, y = topGap
        for w in widths {
            if x > 0, width > 0, x + w > width {
                x = 0
                y += pillHeight + gap
            }
            out.append(CGRect(x: x, y: y, width: w, height: pillHeight))
            x += w + gap
        }
        return out
    }

    /// Height the strip takes in its box at `width`: the gap above and every row.
    public func height(width: CGFloat) -> CGFloat {
        guard let last = frames(width: width).last else { return 0 }
        return last.maxY
    }

    /// Draw the pills with their tops at `origin` (the strip's top left, view coordinates).
    /// `hovered` is the index of the pill under the pointer.
    func draw(at origin: CGPoint, width: CGFloat, hovered: Int?) {
        for (index, (frame, pill)) in zip(frames(width: width), pills).enumerated() {
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            let path = PlatformBezierPath.rounded(rect, radius: min(cornerRadius, rect.height / 2))
            (index == hovered ? hoverFill : fill).setFill()
            path.fill()
            var x = rect.minX + paddingX
            if let symbol = pill.symbol {
                Self.drawSymbol(symbol, in: CGRect(x: x, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize), color: iconColor)
                x += iconSize + iconGap
            } else if let dot = pill.dot {
                dot.setFill()
                PlatformBezierPath(ovalIn: CGRect(x: x, y: rect.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()
                x += dotSize + iconGap
            }
            let text = labels[index]
            let size = text.size()
            text.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
        }
    }

    /// A symbol's shape as a mask (its alpha), its size in points, by name and point
    /// size. Rasterised once; drawing then only fills the mask with the colour, which resolves
    /// for the current appearance as it draws. (Drawing the symbol itself every time cost about
    /// 0.1 ms a pill.) Drawing happens on the main thread only.
    nonisolated(unsafe) private static var masks: [String: (image: CGImage, size: CGSize)] = [:]
    private static let maskScale: CGFloat = 3

    private static func mask(_ name: String, pointSize: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "\(name)/\(pointSize)"
        if let cached = masks[key] { return cached }
        #if os(macOS)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        #else
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }
        #endif
        let size = image.size
        let w = Int(ceil(size.width * maskScale)), h = Int(ceil(size.height * maskScale))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: maskScale, y: maskScale)
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        #else
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        #endif
        guard let cg = ctx.makeImage() else { return nil }
        if masks.count > 64 { masks.removeAll() }
        masks[key] = (cg, size)
        return (cg, size)
    }

    /// An SF Symbol fitted into `box`, in `color`, in the current (top-down) context.
    static func drawSymbol(_ name: String, in box: CGRect, color: PlatformColor) {
        guard let (image, size) = mask(name, pointSize: box.height * 0.9) else { return }
        #if os(macOS)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        #endif
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        ctx.saveGState()
        // Masks draw bottom-up; the views' contexts are top-down.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        ctx.clip(to: local, mask: image)
        color.setFill()
        ctx.fill(local)
        ctx.restoreGState()
    }
}

/// A pill hit by a click or tap: the chrome node it belongs to, which pill, and where it is.
public struct ChromePillHit: Equatable {
    /// Position before the chrome node (the card).
    public var pos: Int
    public var index: Int
    public var id: String
    /// The pill's frame, view coordinates (content coordinates on iOS).
    public var rect: CGRect
}
#endif
