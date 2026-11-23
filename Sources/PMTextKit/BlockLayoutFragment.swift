#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)

/// Layout fragment that carries a paragraph's `BlockDecoration`. NSTextView clips
/// fragment drawing to the text's own bounds, and decorations live in the margin,
/// so `ProseTextView` draws them from its background pass via `drawDecoration`.
final class BlockLayoutFragment: NSTextLayoutFragment {
    var decoration: BlockDecoration!
    weak var host: FragmentHost?

    /// Text draws at the host's focus alpha (focus dimming).
    override func draw(at point: CGPoint, in context: CGContext) {
        guard let host, let tlm = textLayoutManager else { return super.draw(at: point, in: context) }
        let offset = tlm.offset(from: tlm.documentRange.location, to: rangeInElement.location)
        let (alpha, tick) = MainActor.assumeIsolated { (host.focusAlpha(atString: offset), host.checkAnimation(atString: offset)) }
        context.saveGState()
        if alpha < 1 { context.setAlpha(alpha) }
        super.draw(at: point, in: context)
        if let base = decoration?.strikeProgress, case let strike = tick?.strike ?? base, strike > 0 {
            drawStrike(at: point, in: context, progress: strike)
        }
        context.restoreGState()
    }

    /// A strike-through across each line's text, `progress` of the way from the left.
    private func drawStrike(at point: CGPoint, in context: CGContext, progress: CGFloat) {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return }
        let attrs = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? PlatformFont ?? .systemFont(ofSize: PlatformFont.systemFontSize)
        let color = attrs[.foregroundColor] as? PlatformColor ?? .labelColor
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(1, font.pointSize / 16))
        for line in textLineFragments {
            let range = line.characterRange
            var end = range.upperBound
            let text = line.attributedString.string as NSString
            while end > range.location, let scalar = UnicodeScalar(text.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            guard end > range.location else { continue }
            let x0 = line.locationForCharacter(at: range.location).x
            let x1 = line.locationForCharacter(at: end).x
            let baseline = line.typographicBounds.minY + line.glyphOrigin.y
            let y = point.y + baseline - font.xHeight / 2
            let left = point.x + line.typographicBounds.minX + x0
            context.move(to: CGPoint(x: left, y: y))
            context.addLine(to: CGPoint(x: left + (x1 - x0) * progress, y: y))
            context.strokePath()
        }
    }

    static let checkboxSize: CGFloat = 14

    /// Rect of the checkbox in text container coordinates, if any.
    /// The clickable marker's rect: a checkbox or a disclosure triangle.
    func checkboxRect(lineStart: CGFloat) -> CGRect? {
        guard let decoration else { return nil }
        switch decoration.marker {
        case .checkbox?, .disclosure?: break
        default: return nil
        }
        guard let line = textLineFragments.first else { return nil }
        let size = decoration.markerSize
        let baseline = layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        // Between the x-height's middle and the cap height's: next to mixed-case text a marker
        // centred on the x-height alone looks low.
        let font = decoration.font
        let midY = baseline - (font.xHeight + font.capHeight) / 4
        return CGRect(x: lineStart + decoration.markerRight - size, y: midY - size / 2, width: size, height: size)
    }

    /// Draw the decoration in view coordinates. `origin` is the text container's
    /// origin in the view; `lineStart` the container x where unindented text starts;
    /// `lineWidth` the usable container width.
    func drawDecoration(origin: CGPoint, lineStart: CGFloat, lineWidth: CGFloat, checkScale: CGFloat = 1, hover: CGFloat = 0) {
        let d = decoration!
        let frame = layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        let left = origin.x + lineStart

        if let bg = d.background {
            bg.setFill()
            let rect = CGRect(x: left + d.backgroundInset, y: frame.minY, width: lineWidth - d.backgroundInset, height: frame.height)
            if d.backgroundRadius > 0 {
                PlatformBezierPath.rounded(rect, radius: d.backgroundRadius).fill()
            } else {
                rect.pmFill()
            }
        }
        for x in d.quoteBars {
            d.quoteBarColor.setFill()
            CGRect(x: left + x, y: frame.minY, width: d.quoteBarWidth, height: frame.height).pmFill()
        }
        if d.rule {
            d.ruleColor.setFill()
            CGRect(x: left + d.backgroundInset, y: frame.midY - 0.5, width: lineWidth - d.backgroundInset, height: 1).pmFill()
        }
        if let label = d.leafLabel {
            let attrs: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: 12), .foregroundColor: PlatformColor.secondaryLabelColor]
            (label as NSString).draw(at: CGPoint(x: left + d.backgroundInset + 8, y: frame.minY + 6), withAttributes: attrs)
        }

        guard let marker = d.marker, let line = textLineFragments.first else { return }
        let baseline = frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let right = left + d.markerRight
        switch marker {
        case .bullet(let depth):
            drawMarkerText(["•", "◦", "▪"][depth % 3], rightEdge: right, baseline: baseline, font: d.font, color: d.markerColor)
        case .number(let n):
            drawMarkerText("\(n).", rightEdge: right, baseline: baseline, font: d.font.withMonospacedDigits, color: d.markerColor)
        case .checkbox(let checked, let round):
            guard var r = checkboxRect(lineStart: lineStart) else { return }
            r.origin.x += origin.x
            r.origin.y += origin.y
            if checkScale != 1 { r = r.insetBy(dx: r.width * (1 - checkScale) / 2, dy: r.height * (1 - checkScale) / 2) }
            Checkbox.draw(in: r, checked: checked, round: round, fill: d.checkFill, mark: d.checkMark, stroke: d.checkStroke,
                          radius: d.checkRadius, hover: hover)
        case .disclosure(let expanded):
            drawMarkerText(expanded ? "▾" : "▸", rightEdge: right, baseline: baseline, font: d.font, color: d.markerColor)
        case .label(let text):
            drawMarkerText(text, rightEdge: right, baseline: baseline, font: d.font, color: d.markerColor)
        }
    }

    private func drawMarkerText(_ s: String, rightEdge: CGFloat, baseline: CGFloat, font: PlatformFont, color: PlatformColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        // Flipped view: draw(at:) takes the top-left corner of the line box.
        (s as NSString).draw(at: CGPoint(x: rightEdge - size.width, y: baseline - font.ascender), withAttributes: attrs)
    }
}

/// The checkbox look (design rules: Checkbox), for fragments and for views that draw one
/// themselves (a collapsed card).
public enum Checkbox {
    /// `fill` nil is green for round boxes, the accent colour for square ones; `radius` nil is
    /// round for round boxes, 3.5 otherwise.
    public static func draw(in r: CGRect, checked: Bool, round: Bool, fill: PlatformColor?, mark: PlatformColor = .white,
                            stroke: PlatformColor, radius: CGFloat? = nil, hover: CGFloat = 0) {
        let radius = radius ?? (round ? r.width / 2 : 3.5)
        let path = PlatformBezierPath.rounded(r, radius: radius)
        if checked {
            (fill ?? (round ? PlatformColor.systemGreen : PlatformColor.controlAccentColor)).setFill()
            path.fill()
            drawCheckmark(in: r, color: mark)
        } else {
            let ring = r.insetBy(dx: 0.75, dy: 0.75)
            let ringPath = PlatformBezierPath.rounded(ring, radius: max(0, radius - 0.75))
            ringPath.lineWidth = 1.5
            // Hover on a round (card) tick: the done colour's ring over a faint wash of it.
            let done = fill ?? .systemGreen
            let h = round ? hover : 0
            if h > 0 {
                done.withAlphaComponent(0.10 * h).setFill()
                path.fill()
            }
            // Cross-fade the resting ring into the done colour's.
            for (color, alpha) in [(stroke, 1 - h), (done, h)] where alpha > 0 {
                color.withAlphaComponent(color.alphaComponent * alpha).setStroke()
                ringPath.stroke()
            }
        }
    }

    /// SF Symbol `checkmark`, bold, half the box's size, centred.
    static func drawCheckmark(in box: CGRect, color: PlatformColor) {
        #if os(macOS)
        let config = NSImage.SymbolConfiguration(pointSize: box.width * 0.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        let config = UIImage.SymbolConfiguration(pointSize: box.width * 0.5, weight: .bold)
        guard let image = UIImage(systemName: "checkmark", withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
        #endif
    }
}

/// What a fragment asks its text view while drawing: focus dimming and tick animations.
@MainActor protocol FragmentHost: AnyObject {
    func focusAlpha(atString offset: Int) -> CGFloat
    func checkAnimation(atString offset: Int) -> CheckAnimationState?
}
#endif
