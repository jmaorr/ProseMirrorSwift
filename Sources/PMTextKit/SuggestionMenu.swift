#if os(macOS)
import AppKit
import QuartzCore

/// Geometry of the suggestion menu (design rules: popovers radius 8 with the popover shadow,
/// items radius 6, menus 13pt, 4pt grid).
enum SuggestionMenuMetrics {
    static let width: CGFloat = 256
    static let inset: CGFloat = 4
    static let rowHeight: CGFloat = 40
    static let rowPadding: CGFloat = 8
    static let tile: CGFloat = 28
    static let tileGap: CGFloat = 10
    /// Rows shown before the list scrolls; the half row shows there's more.
    static let visibleRows: CGFloat = 7.5
    static let radius: CGFloat = 8
    static let itemRadius: CGFloat = 6
    /// Between the trigger's line and the menu.
    static let gap: CGFloat = 4
    /// Room around the menu in its panel for the shadow (blur 12, y 4).
    static let shadowMargin: CGFloat = 16
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    static let emptyFont = NSFont.systemFont(ofSize: 13)
    static let glyphFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    static func height(rows: Int) -> CGFloat {
        inset * 2 + rowHeight * min(CGFloat(max(rows, 1)), visibleRows)
    }
}

/// The menu window: borderless and non-activating, so the text view stays key and first
/// responder and keeps getting the keys (it forwards the menu's keys to its controller).
final class SuggestionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows a `SuggestionController`'s items in a child panel under the caret line.
@MainActor
final class SuggestionMenu {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var accent: NSColor = .controlAccentColor { didSet { list.accent = accent } }

    private(set) lazy var panel: SuggestionPanel = {
        let panel = SuggestionPanel()
        panel.contentView = container
        return panel
    }()
    let container = SuggestionMenuContainer()
    var list: SuggestionListView { container.list }
    /// Whether it opened above the line (no room below); kept while it stays open.
    private(set) var placedAbove: Bool?
    /// The menu's frame (without the shadow margin) in screen coordinates.
    private(set) var menuFrame: CGRect = .zero
    private var visible = false
    private var fadeGeneration = 0

    init() {
        list.onHover = { [weak self] in self?.onHover?($0) }
        list.onClick = { [weak self] in self?.onClick?($0) }
    }

    func update(items: [SuggestionItem], selected: Int, emptyText: String) {
        list.set(items: items, selected: selected, emptyText: emptyText)
        container.layoutMenu(height: SuggestionMenuMetrics.height(rows: items.count))
        list.scrollToSelected()
    }

    func setSelected(_ index: Int, scroll: Bool) {
        list.selected = index
        if scroll { list.scrollToSelected() }
    }

    /// Place the menu under `anchor` (the trigger's line, in `view`'s coordinates): flipped above
    /// it when there's no room below on the screen, and kept on the screen sideways.
    func show(below anchor: CGRect, in view: NSView) {
        guard let window = view.window else { return }
        let size = CGSize(width: SuggestionMenuMetrics.width, height: SuggestionMenuMetrics.height(rows: list.items.count))
        let line = window.convertToScreen(view.convert(anchor, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
        let frame = Self.place(size, line: line, screen: screen, above: &placedAbove)
        menuFrame = frame
        let m = SuggestionMenuMetrics.shadowMargin
        panel.appearance = view.effectiveAppearance
        panel.setFrame(frame.insetBy(dx: -m, dy: -m), display: visible)
        // Lay out now (not at the next display), so scrolling to the selection sees the list's size.
        container.layoutSubtreeIfNeeded()
        guard !visible else { return }
        visible = true
        fadeGeneration += 1
        // Only order in over a window on screen (tests run with windows that never are).
        guard window.isVisible else { return }
        panel.alphaValue = 0
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        placedAbove = nil
        fadeGeneration += 1
        let generation = fadeGeneration
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.panel.parent?.removeChildWindow(self.panel)
                self.panel.orderOut(nil)
            }
        })
    }

    var isVisible: Bool { visible }

    /// The menu's frame for `size` against the trigger's `line` (both in screen coordinates,
    /// y up): left edge so the icons line up under the trigger, below the line unless only
    /// above has room (`above` keeps the first choice while the menu stays open).
    static func place(_ size: CGSize, line: CGRect, screen: CGRect, above: inout Bool?) -> CGRect {
        let gap = SuggestionMenuMetrics.gap
        let roomBelow = line.minY - gap - screen.minY
        let roomAbove = screen.maxY - (line.maxY + gap)
        if above == nil || (above == false && roomBelow < size.height && roomAbove >= size.height)
            || (above == true && roomAbove < size.height && roomBelow >= size.height) {
            above = roomBelow < size.height && roomAbove > roomBelow
        }
        let y = above == true ? line.maxY + gap : line.minY - gap - size.height
        let lead = SuggestionMenuMetrics.inset + SuggestionMenuMetrics.rowPadding
        var x = line.minX - lead
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        return CGRect(x: x, y: max(min(y, screen.maxY - size.height), screen.minY), width: size.width, height: size.height)
    }

    /// VoiceOver keeps its focus in the text; say which item is selected.
    func announce(_ item: SuggestionItem) {
        let text = [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
        NSAccessibility.post(element: list, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// The panel's content: the popover shadow, a menu material clipped to radius 8, a hairline
/// border in `line`, and the scrolling list.
final class SuggestionMenuContainer: NSView {
    let shadowView = SuggestionShadowView()
    let material = NSVisualEffectView()
    let scrollView = NSScrollView()
    let list = SuggestionListView()
    let border = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(shadowView)

        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = SuggestionMenuMetrics.radius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        addSubview(material)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = list
        material.addSubview(scrollView)

        border.wantsLayer = true
        border.layer?.cornerRadius = SuggestionMenuMetrics.radius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1
        addSubview(border)

        setAccessibilityElement(false)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The menu's frame inside the panel (inside the shadow margin).
    var menuRect: CGRect { bounds.insetBy(dx: SuggestionMenuMetrics.shadowMargin, dy: SuggestionMenuMetrics.shadowMargin) }

    func layoutMenu(height: CGFloat) {
        let m = SuggestionMenuMetrics.shadowMargin
        setFrameSize(CGSize(width: SuggestionMenuMetrics.width + 2 * m, height: height + 2 * m))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let rect = menuRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView.frame = bounds
        material.frame = rect
        border.frame = rect
        // The list scrolls under the menu's top and bottom padding, to its rounded edge.
        let inset = SuggestionMenuMetrics.inset
        scrollView.frame = material.bounds
        scrollView.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        list.frame.size = CGSize(width: scrollView.contentSize.width, height: list.contentHeight)
        shadowView.menuRect = rect
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // `line`: ink @ 0.10 light / 0.15 dark.
            border.layer?.borderColor = NSColor.labelColor.withAlphaComponent(dark ? 0.15 : 0.10).cgColor
        }
        list.needsDisplay = true
    }
}

/// The popover shadow (blur 12, y 4, black @ 0.15), drawn only outside the menu's shape: the
/// material is translucent, and a shadow showing through it would grey the menu.
final class SuggestionShadowView: NSView {
    var menuRect: CGRect = .zero { didSet { if menuRect != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext, !menuRect.isEmpty else { return }
        let shape = CGPath(roundedRect: menuRect, cornerWidth: SuggestionMenuMetrics.radius, cornerHeight: SuggestionMenuMetrics.radius, transform: nil)
        c.saveGState()
        c.addRect(bounds)
        c.addPath(shape)
        c.clip(using: .evenOdd)
        c.setShadow(offset: CGSize(width: 0, height: isFlipped ? 4 : -4), blur: 12, color: NSColor.black.withAlphaComponent(0.15).cgColor)
        c.addPath(shape)
        c.setFillColor(NSColor.black.cgColor)
        c.fillPath()
        c.restoreGState()
    }
}

/// The rows, drawn in one view: icon tile, title and subtitle; the selected row in the accent.
final class SuggestionListView: NSView {
    private(set) var items: [SuggestionItem] = []
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true; updateAccessibility() } } }
    var emptyText = "No results"
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private var pressed: Int?
    private var lastMouse: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat { SuggestionMenuMetrics.rowHeight * CGFloat(max(items.count, 1)) }

    func set(items: [SuggestionItem], selected: Int, emptyText: String) {
        self.items = items
        self.selected = selected
        self.emptyText = emptyText
        frame.size.height = contentHeight
        needsDisplay = true
        updateAccessibility()
    }

    func rowRect(_ index: Int) -> CGRect {
        let inset = SuggestionMenuMetrics.inset
        return CGRect(x: inset, y: CGFloat(index) * SuggestionMenuMetrics.rowHeight,
                      width: bounds.width - 2 * inset, height: SuggestionMenuMetrics.rowHeight)
    }

    func scrollToSelected() {
        // The least scroll that shows the row and the menu's padding beside it (the clip view's
        // content insets past the first and last rows), so a row never sits cut at the edge.
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let inset = SuggestionMenuMetrics.inset
        let index = items.indices.contains(selected) ? selected : 0
        let row = rowRect(index)
        let height = clip.bounds.height
        var y = clip.bounds.minY
        if row.minY - inset < y { y = row.minY - inset }
        else if row.maxY + inset > y + height { y = row.maxY + inset - height }
        y = max(-inset, min(y, contentHeight + inset - height))
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func row(at point: NSPoint) -> Int? {
        let index = Int(point.y / SuggestionMenuMetrics.rowHeight)
        return items.indices.contains(index) && rowRect(index).contains(point) ? index : nil
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    /// An arrow, not the text view's I-beam it was carried over from.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseMoved(with event: NSEvent) {
        // Only a real move selects: the menu opening under a resting pointer must not take
        // the selection from the keyboard.
        let p = event.locationInWindow
        defer { lastMouse = p }
        guard let last = lastMouse, last != p, let index = row(at: convert(p, from: nil)) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = row(at: convert(event.locationInWindow, from: nil))
        if let pressed { onHover?(pressed) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, row(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        onClick?(pressed)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return drawEmpty() }
        for (i, item) in items.enumerated() {
            let rect = rowRect(i)
            guard rect.intersects(dirtyRect) else { continue }
            drawRow(item, in: rect, selected: i == selected)
        }
    }

    private func drawEmpty() {
        let attrs: [NSAttributedString.Key: Any] = [.font: SuggestionMenuMetrics.emptyFont, .foregroundColor: NSColor.secondaryLabelColor]
        let text = NSAttributedString(string: emptyText, attributes: attrs)
        let size = text.size()
        let row = rowRect(0)
        text.draw(at: CGPoint(x: row.midX - size.width / 2, y: row.midY - size.height / 2))
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func drawRow(_ item: SuggestionItem, in rect: CGRect, selected: Bool) {
        let m = SuggestionMenuMetrics.self
        if selected {
            accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: m.itemRadius, yRadius: m.itemRadius).fill()
        }
        // Icon tile: `fillHover` (ink @ 0.05 / 0.08), white @ 0.2 on the accent.
        let tile = CGRect(x: rect.minX + m.rowPadding, y: rect.midY - m.tile / 2, width: m.tile, height: m.tile)
        let tileFill = selected ? NSColor.white.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.05)
        tileFill.setFill()
        NSBezierPath(roundedRect: tile, xRadius: m.itemRadius, yRadius: m.itemRadius).fill()
        let glyphColor: NSColor = selected ? .white : .secondaryLabelColor
        switch item.icon {
        case .symbol(let name)?:
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(m.symbol.applying(.init(paletteColors: [glyphColor]))) {
                let size = image.size
                image.draw(in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
            }
        case .text(let glyph)?:
            let text = NSAttributedString(string: glyph, attributes: [.font: m.glyphFont, .foregroundColor: glyphColor])
            let size = text.size()
            text.draw(at: CGPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2))
        case nil:
            break
        }
        // Title (13 medium, `ink`) over subtitle (11, `soft`), centred on the row together.
        let textX = tile.maxX + m.tileGap
        let width = rect.maxX - m.rowPadding - textX
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: item.title, attributes: [
            .font: m.titleFont, .foregroundColor: selected ? NSColor.white : NSColor.labelColor, .paragraphStyle: para])
        let subtitle = item.subtitle.map {
            NSAttributedString(string: $0, attributes: [
                .font: m.subtitleFont, .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.75) : NSColor.secondaryLabelColor,
                .paragraphStyle: para])
        }
        let titleHeight = ceil(m.titleFont.ascender - m.titleFont.descender)
        let subtitleHeight = subtitle == nil ? 0 : ceil(m.subtitleFont.ascender - m.subtitleFont.descender)
        let total = titleHeight + subtitleHeight
        var y = rect.midY - total / 2
        title.draw(with: CGRect(x: textX, y: y, width: width, height: titleHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += titleHeight
        subtitle?.draw(with: CGRect(x: textX, y: y, width: width, height: subtitleHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel(items.isEmpty ? emptyText : "Suggestions")
        let selectedItem = items.indices.contains(selected) ? items[selected] : nil
        setAccessibilityValue(selectedItem.map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: ", ") })
    }
}
#endif
