#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(macOS) || canImport(UIKit)
import PMModel
import PMTransform
import PMState

/// Which chrome node is active and how far each one is expanded. Keyed by the
/// position before the node, mapped through every transaction, so a card keeps
/// its state while its content is edited. This is view state: it never enters
/// the document, the history or the collaboration layer.
final class ChromeState {
    struct Entry {
        /// Linear 0...1; `progress` eases it.
        var value: CGFloat
        var target: CGFloat
    }

    private(set) var entries: [Int: Entry] = [:]
    private(set) var activePos: Int?
    var duration: CFTimeInterval = 0.24
    var animates = true

    var settled: Bool { entries.values.allSatisfy { $0.value == $0.target } }

    /// Active, or still animating closed.
    func isOpen(_ pos: Int) -> Bool { entries[pos] != nil }

    func progress(_ pos: Int) -> CGFloat {
        guard let t = entries[pos]?.value else { return 0 }
        return t * t * (3 - 2 * t)
    }

    /// Follow the nodes through a document change, dropping any that are gone.
    func map(_ mapping: Mapping, isChrome: (Int) -> Bool) {
        var mapped: [Int: Entry] = [:]
        for (pos, entry) in entries {
            let result = mapping.mapResult(pos, assoc: 1)
            if !result.deletedAfter, isChrome(result.pos) { mapped[result.pos] = entry }
        }
        entries = mapped
        if let pos = activePos {
            let result = mapping.mapResult(pos, assoc: 1)
            activePos = !result.deletedAfter && isChrome(result.pos) ? result.pos : nil
        }
    }

    func setActive(_ pos: Int?) {
        for key in entries.keys { entries[key]!.target = 0 }
        if let pos { entries[pos, default: Entry(value: 0, target: 0)].target = 1 }
        activePos = pos
        if !animates { snap() }
    }

    func snap() {
        for key in entries.keys { entries[key]!.value = entries[key]!.target }
        entries = entries.filter { $0.value.target > 0 }
    }

    func reset() {
        entries = [:]
        activePos = nil
    }

    /// Advance every animation by `dt` seconds.
    func step(_ dt: CFTimeInterval) {
        let delta = CGFloat(dt / duration)
        for key in entries.keys {
            var e = entries[key]!
            e.value = e.value < e.target ? min(e.target, e.value + delta) : max(e.target, e.value - delta)
            entries[key] = e
        }
        entries = entries.filter { $0.value.value > 0 || $0.value.target > 0 }
    }
}

/// Counts for tests: how many chrome regions draws have looked at (TextKit lookups each).
enum ChromeDrawStats {
    static var regionsExamined = 0
}

/// What the shared chrome, selection and input code needs from a text view; the AppKit and UIKit
/// `ProseTextView`s both provide it. (Their own properties differ in optionality and name.)
protocol ProseViewHost: AnyObject {
    var state: EditorState { get }
    var renderer: DocRenderer { get }
    var hostLayoutManager: NSTextLayoutManager? { get }
    var hostContentManager: NSTextContentManager? { get }
    var hostTextContainer: NSTextContainer? { get }
    /// The text container's origin in view coordinates.
    var hostContainerOrigin: CGPoint { get }
    /// How far the pointer's hover look on the chrome at `pos` has faded in (0 on touch screens).
    func chromeHoverLevel(_ pos: Int) -> CGFloat
    /// The strip pill under the pointer in the chrome at `pos`, if any.
    func hoveredPill(_ pos: Int) -> Int?
}

extension ProseViewHost {
    /// The innermost node with chrome that contains the whole selection.
    func activeChromePos(_ state: EditorState) -> Int? {
        let sel = state.selection
        if sel is AllSelection { return nil }
        let from = sel.fromPos
        var depth = from.depth
        while depth > 0 {
            if let box = renderer.style.chrome(for: from.node(depth)), box.activates, sel.to <= from.end(depth) { return from.before(depth) }
            depth -= 1
        }
        return nil
    }

    func isChromeNode(at pos: Int) -> Bool {
        guard let node = state.doc.nodeAt(pos) else { return false }
        return renderer.style.chrome(for: node)?.activates == true
    }

    // MARK: Geometry

    /// The box around a chrome region, in view coordinates, as currently laid out.
    func chromeRect(_ region: ChromeRegion) -> CGRect? {
        guard let tlm = hostLayoutManager, let tcs = hostContentManager, let container = hostTextContainer, region.strEnd > region.strStart,
              let startLoc = tcs.location(tcs.documentRange.location, offsetBy: region.strStart),
              let endLoc = tcs.location(tcs.documentRange.location, offsetBy: region.strEnd - 1),
              let first = tlm.textLayoutFragment(for: startLoc), let last = tlm.textLayoutFragment(for: endLoc),
              let firstLine = first.textLineFragments.first,
              // At the end of the document TextKit adds an empty extra line to the last
              // paragraph; the box ends at the last line with text.
              let lastLine = last.textLineFragments.last(where: { $0.characterRange.length > 0 }) ?? last.textLineFragments.last else { return nil }
        let box = region.box
        let origin = hostContainerOrigin
        let padding = container.lineFragmentPadding
        let top = first.layoutFragmentFrame.minY + firstLine.typographicBounds.minY - box.paddingTop
        let bottom = last.layoutFragmentFrame.minY + lastLine.typographicBounds.maxY + region.stripHeight + box.paddingBottom
            + box.footer * region.progress
        let width = container.size.width - 2 * padding
        return CGRect(x: origin.x + padding + box.insetLeft, y: origin.y + top,
                      width: width - box.insetLeft - box.insetRight, height: bottom - top)
    }

    // MARK: Strip

    /// Where a region's strip sits inside its box `rect` (view coordinates): under the content,
    /// above the bottom padding and the footer.
    func stripRect(_ region: ChromeRegion, box rect: CGRect) -> CGRect? {
        guard let strip = region.strip, region.stripHeight > 0 else { return nil }
        let box = region.box
        let y = rect.maxY - box.footer * region.progress - box.paddingBottom - region.stripHeight
        return CGRect(x: rect.minX + strip.inset, y: y, width: max(1, rect.width - strip.inset - strip.trailingInset),
                      height: region.stripHeight)
    }

    /// The frames of a region's pills, view coordinates.
    func pillFrames(_ region: ChromeRegion) -> [CGRect] {
        guard let strip = region.strip, let rect = chromeRect(region), let area = stripRect(region, box: rect) else { return [] }
        return strip.frames(width: renderer.stripWidth(strip, in: region.box)).map { $0.offsetBy(dx: area.minX, dy: area.minY) }
    }

    /// The pill at `point` (view coordinates), if any.
    func pill(at point: CGPoint) -> ChromePillHit? {
        for region in chromeCandidates(in: CGRect(origin: point, size: .zero)) where region.strip != nil {
            for (index, frame) in pillFrames(region).enumerated() where frame.contains(point) {
                return ChromePillHit(pos: region.pos, index: index, id: region.strip!.pills[index].id, rect: frame)
            }
        }
        return nil
    }

    /// Every pill of the chrome node at `pos`, as hits (for VoiceOver and tests).
    func pills(atChrome pos: Int) -> [ChromePillHit] {
        guard let region = renderer.chromes.first(where: { $0.pos == pos }), let strip = region.strip else { return [] }
        return pillFrames(region).enumerated().map { ChromePillHit(pos: pos, index: $0.offset, id: strip.pills[$0.offset].id, rect: $0.element) }
    }

    /// The string offsets [lower, upper) of the text laid out from `minY` to `maxY` (view
    /// coordinates), widened by how far boxes reach past their text: any chrome region whose box
    /// could touch that band overlaps it. Nil when TextKit can't say (every region may).
    func chromeStringRange(fromY minY: CGFloat, toY maxY: CGFloat) -> Range<Int>? {
        guard let tlm = hostLayoutManager else { return nil }
        let origin = hostContainerOrigin
        let reach = renderer.chromeReach
        let top = minY - reach - origin.y, bottom = maxY + reach - origin.y
        let start = tlm.documentRange.location
        let lower: Int
        if top <= 0 {
            lower = 0
        } else if let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: top)) {
            lower = tlm.offset(from: start, to: fragment.rangeInElement.location)
        } else {
            return nil
        }
        let upper = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bottom))).map {
            tlm.offset(from: start, to: $0.rangeInElement.endLocation)
        } ?? Int.max
        return lower..<max(lower, upper)
    }

    /// The chrome regions whose boxes could touch `rect` (view coordinates), in document order.
    func chromeCandidates(in rect: CGRect) -> [ChromeRegion] {
        let chromes = renderer.chromes
        guard let range = chromeStringRange(fromY: rect.minY, toY: rect.maxY) else { return chromes }
        return chromes.filter { $0.strStart < range.upperBound && $0.strEnd > range.lowerBound }
    }

    func drawChromeBoxes(in dirty: CGRect) {
        // Only regions whose text is near the dirty rect: the others' boxes (TextKit lookups
        // each) can't touch it. Outer boxes first, so a box inside another (a code block in a
        // card) draws on top.
        let chromes = renderer.chromes
        let range = chromeStringRange(fromY: dirty.minY, toY: dirty.maxY)
        for index in renderer.chromeDrawOrder {
            let region = chromes[index]
            if let range, region.strStart >= range.upperBound || region.strEnd <= range.lowerBound { continue }
            ChromeDrawStats.regionsExamined += 1
            let box = region.box
            let outset = max(box.shadow == nil ? 0 : ChromeShadow.extent(blur: box.shadowRadius), box.activeRing == nil ? 0 : box.activeRingWidth) + 1
            guard box.fill != nil || box.border != nil || region.progress > 0 || region.strip != nil, let rect = chromeRect(region),
                  rect.insetBy(dx: -outset, dy: -outset).intersects(dirty) else { continue }
            let path = PlatformBezierPath.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: box.cornerRadius)
            // Cross-fade the collapsed and active looks (mixing the colours themselves goes grey).
            let t = region.progress
            if let shadow = box.shadow, t < 1 {
                // Cast from an opaque copy of the box, clipped to outside it, so a
                // translucent fill doesn't thin the shadow or let it show through. The
                // shadow itself comes from a cached template (`ChromeShadow`) unless that is
                // off; the clip and the caster are the box's own path either way.
                let color = shadow.withAlphaComponent(shadow.alphaComponent * (1 - t))
                #if os(macOS)
                NSGraphicsContext.saveGraphicsState()
                let outside = NSBezierPath(rect: rect.insetBy(dx: -outset * 2, dy: -outset * 2))
                outside.append(path)
                outside.windingRule = .evenOdd
                outside.addClip()
                // Draws the cached shadow, if it can; otherwise the caster casts it live.
                let drewTemplate = ChromeShadow.usesCache && NSGraphicsContext.current.map {
                    ChromeShadow.draw(around: rect, cornerRadius: box.cornerRadius, blur: box.shadowRadius,
                                      color: shadow.cgColor, alpha: 1 - t, in: $0.cgContext)
                } == true
                if !drewTemplate {
                    let caster = NSShadow()
                    caster.shadowColor = color
                    caster.shadowBlurRadius = box.shadowRadius
                    caster.shadowOffset = .zero
                    caster.set()
                }
                // The caster itself (its anti-aliased edge shows through the clip's).
                NSColor.black.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                #else
                if let ctx = UIGraphicsGetCurrentContext() {
                    ctx.saveGState()
                    let outside = UIBezierPath(rect: rect.insetBy(dx: -outset * 2, dy: -outset * 2))
                    outside.append(path)
                    outside.usesEvenOddFillRule = true
                    outside.addClip()
                    // Draws the cached shadow, if it can; otherwise the caster casts it live.
                    let drewTemplate = ChromeShadow.usesCache
                        && ChromeShadow.draw(around: rect, cornerRadius: box.cornerRadius, blur: box.shadowRadius,
                                             color: shadow.cgColor, alpha: 1 - t, in: ctx)
                    if !drewTemplate {
                        ctx.setShadow(offset: .zero, blur: box.shadowRadius, color: color.cgColor)
                    }
                    // The caster itself (its anti-aliased edge shows through the clip's).
                    UIColor.black.setFill()
                    path.fill()
                    ctx.restoreGState()
                }
                #endif
            }
            if let ring = box.activeRing, t > 0 {
                let w = box.activeRingWidth
                let ringPath = PlatformBezierPath.rounded(rect.insetBy(dx: -w / 2, dy: -w / 2), radius: box.cornerRadius + w / 2)
                ringPath.lineWidth = w
                ring.withAlphaComponent(ring.alphaComponent * t).setStroke()
                ringPath.stroke()
            }
            for (color, alpha) in [(box.fill, 1 - t), (box.activeFill, t)] where alpha > 0 {
                guard let color else { continue }
                color.withAlphaComponent(color.alphaComponent * alpha).setFill()
                path.fill()
            }
            path.lineWidth = 1
            let h = chromeHoverLevel(region.pos)
            for (color, alpha) in [(box.border, (1 - t) * (1 - h)), (box.hoverBorder ?? box.border, (1 - t) * h), (box.activeBorder, t)]
            where alpha > 0 {
                guard let color else { continue }
                color.withAlphaComponent(color.alphaComponent * alpha).setStroke()
                path.stroke()
            }
            if let strip = region.strip, let area = stripRect(region, box: rect) {
                strip.draw(at: area.origin, width: renderer.stripWidth(strip, in: box), hovered: hoveredPill(region.pos))
            }
        }
    }
}

#endif
