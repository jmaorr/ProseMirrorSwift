#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)

/// A chrome box's drop shadow, drawn from a small cached image instead of a live blur.
///
/// The live version (still used when the cache is off) casts a Gaussian shadow from an opaque
/// copy of the box for every box on every redraw: the dominant cost of drawing a note with
/// many cards. Here the shadow alone (no box) is rendered once per (colour, blur, corner radius,
/// scale) around a box just big enough for its corners to stand clear of each other, and drawn
/// nine-slice: corners as they are, edges stretched along the box. A box too short (or narrow)
/// for that gets a template of its own exact height (or width) on that axis. The caller clips
/// to outside the box, as for the live shadow, so the box's edge is anti-aliased by its own path
/// wherever it lands, not by the template's.
enum ChromeShadow {
    /// Off casts every shadow live, as before the cache. For tests.
    static var usesCache = true
    /// Templates rendered so far (tests check that boxes share them).
    private(set) static var renderCount = 0

    private struct Key: Hashable {
        var color: [CGFloat]
        var space: String
        var blur: CGFloat
        var radius: CGFloat
        var scale: CGFloat
        /// A fixed (unstretched) box length in pixels on that axis, or nil to stretch.
        var fixedWidth: Int?
        var fixedHeight: Int?
    }

    private final class Template {
        let image: CGImage
        private struct Area: Hashable { var x, y, width, height: Int }
        private var pieces: [Area: CGImage] = [:]
        init(image: CGImage) { self.image = image }
        /// The part of the image at these pixels (from the top left).
        func piece(x: Int, y: Int, width: Int, height: Int) -> CGImage? {
            let area = Area(x: x, y: y, width: width, height: height)
            if let piece = pieces[area] { return piece }
            let piece = image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
            pieces[area] = piece
            return piece
        }
    }

    /// One span along an axis: source pixels and where they land, in user space.
    private struct Span {
        enum Kind { case near, middle, far, whole }
        var src: Int, srcLength: Int
        var dst: CGFloat, dstLength: CGFloat
        var kind: Kind
    }

    /// Stretching templates, shared by every box of a look.
    private static var cache: [Key: Template] = [:]
    /// Templates made for one short box's exact height or width, most recent last: few, so a box
    /// whose height animates (a card opening) can't evict the shared ones.
    private static var fixedCache: [(key: Key, template: Template)] = []
    private static let fixedCacheLimit = 8

    /// How far past the box the shadow reaches (points). CoreGraphics' blur is a Gaussian with a
    /// standard deviation of about half the blur, so its tail is gone (well under 1/255 at the
    /// alphas themes use) by one and a half times the blur.
    static func extent(blur: CGFloat) -> CGFloat { (max(0, blur) * 1.5).rounded(.up) + 1 }

    /// Draw the shadow of `rect`'s rounded box (the box path is `rect` inset by half a point, as
    /// the box draws it) in `color`, faded by `alpha`, into a context already clipped to outside
    /// the box. Returns false, drawing nothing, when no template could be made; the caller then
    /// casts it live.
    static func draw(around rect: CGRect, cornerRadius: CGFloat, blur: CGFloat, color: CGColor, alpha: CGFloat,
                     in ctx: CGContext) -> Bool {
        guard rect.width > 1, rect.height > 1 else { return false }
        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = min(4, max(1, hypot(device.a, device.b).rounded()))
        let ext = extent(blur: blur)
        let extPx = Int(ext * scale)
        // A corner piece runs from the image edge past the corner curve and the shadow's reach.
        let capPx = Int(((cornerRadius + 2 * ext) * scale).rounded(.up))
        // On an axis whose box is long enough the template stretches; otherwise it is the box's
        // own length, so nothing on that axis is scaled.
        func fixedLength(_ length: CGFloat) -> Int? {
            length * scale >= CGFloat(2 * capPx + 1 - 2 * extPx) ? nil : max(1, Int((length * scale).rounded()))
        }
        guard let components = color.components else { return false }
        let key = Key(color: components, space: (color.colorSpace?.name as String?) ?? "", blur: blur, radius: cornerRadius,
                      scale: scale, fixedWidth: fixedLength(rect.width), fixedHeight: fixedLength(rect.height))
        let template: Template
        if key.fixedWidth == nil, key.fixedHeight == nil {
            if let cached = cache[key] {
                template = cached
            } else {
                guard let made = render(key, color: color, extPx: extPx, capPx: capPx) else { return false }
                if cache.count >= 64 { cache.removeAll() }
                cache[key] = made
                template = made
            }
        } else if let index = fixedCache.firstIndex(where: { $0.key == key }) {
            let entry = fixedCache.remove(at: index)
            fixedCache.append(entry)
            template = entry.template
        } else {
            guard let made = render(key, color: color, extPx: extPx, capPx: capPx) else { return false }
            if fixedCache.count >= fixedCacheLimit { fixedCache.removeFirst() }
            fixedCache.append((key, made))
            template = made
        }

        // Spans per axis, ascending in user space. CoreGraphics draws an image bottom row
        // lowest, so source rows count up from the image's bottom; the template is symmetric, so
        // in a flipped context (where each piece lands mirrored) a piece's mirror image is its
        // opposite piece, which is what belongs there.
        let outer = rect.insetBy(dx: -ext, dy: -ext)
        func spans(fixed: Int?, size: Int, start: CGFloat, length: CGFloat) -> [Span] {
            if fixed != nil { return [Span(src: 0, srcLength: size, dst: start, dstLength: length, kind: .whole)] }
            let cap = CGFloat(capPx) / scale
            return [Span(src: 0, srcLength: capPx, dst: start, dstLength: cap, kind: .near),
                    Span(src: capPx, srcLength: 1, dst: start + cap, dstLength: length - 2 * cap, kind: .middle),
                    Span(src: capPx + 1, srcLength: capPx, dst: start + length - cap, dstLength: cap, kind: .far)]
        }
        // Beside a stretched middle only the band outside the box shows (the rest is clipped);
        // it reaches two points into the box, past the path's half-point inset and its
        // anti-aliased edge, whose pixels the clip lets partly through.
        let bandPx = min(capPx, extPx + Int(2 * scale)), band = CGFloat(bandPx) / scale
        func outerBands(_ span: Span) -> [Span] {
            if span.kind == .whole, span.srcLength < 2 * bandPx { return [span] }
            var near = span, far = span
            near.srcLength = bandPx
            near.dstLength = band
            far.src = span.src + span.srcLength - bandPx
            far.srcLength = bandPx
            far.dst = span.dst + span.dstLength - band
            far.dstLength = band
            switch span.kind {
            case .near: return [near]
            case .far: return [far]
            case .whole: return [near, far]
            case .middle: return [span]
            }
        }
        let width = template.image.width, height = template.image.height
        let xs = spans(fixed: key.fixedWidth, size: width, start: outer.minX, length: outer.width)
        let ys = spans(fixed: key.fixedHeight, size: height, start: outer.minY, length: outer.height)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        for row in ys {
            for column in xs {
                // The middle of a stretched box is inside it, clipped away: nothing to draw.
                if row.kind == .middle, column.kind == .middle { continue }
                for y in column.kind == .middle ? outerBands(row) : [row] {
                    for x in row.kind == .middle ? outerBands(column) : [column] {
                        guard x.dstLength > 0, y.dstLength > 0,
                              let piece = template.piece(x: x.src, y: height - y.src - y.srcLength,
                                                         width: x.srcLength, height: y.srcLength) else { continue }
                        ctx.draw(piece, in: CGRect(x: x.dst, y: y.dst, width: x.dstLength, height: y.dstLength))
                    }
                }
            }
        }
        ctx.restoreGState()
        return true
    }

    private static func render(_ key: Key, color: CGColor, extPx: Int, capPx: Int) -> Template? {
        // Pixels per axis: a stretched template is cap, one pixel, cap; a fixed one the box plus the reach.
        let w = key.fixedWidth.map { $0 + 2 * extPx } ?? 2 * capPx + 1
        let h = key.fixedHeight.map { $0 + 2 * extPx } ?? 2 * capPx + 1
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = key.scale
        bmp.scaleBy(x: s, y: s)
        let ext = CGFloat(extPx) / s
        let full = CGRect(x: 0, y: 0, width: CGFloat(w) / s, height: CGFloat(h) / s)
        let box = full.insetBy(dx: ext, dy: ext).insetBy(dx: 0.5, dy: 0.5)
        let r = max(0, min(key.radius, box.width / 2, box.height / 2))
        let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        // The shadow only: the box is filled out of the image and its shadow offset back in.
        // A bitmap context's shadow is in its base space (pixels), not affected by the scale.
        let away = full.width + 4 * ext
        bmp.setShadow(offset: CGSize(width: away * s, height: 0), blur: key.blur * s, color: color)
        bmp.setFillColor(CGColor(gray: 0, alpha: 1))
        bmp.translateBy(x: -away, y: 0)
        bmp.addPath(path)
        bmp.fillPath()
        guard let image = bmp.makeImage() else { return nil }
        renderCount += 1
        return Template(image: image)
    }
}

#endif
