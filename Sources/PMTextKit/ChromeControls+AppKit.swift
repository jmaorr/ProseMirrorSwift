#if os(macOS)
import AppKit
import PMModel
import PMState

/// Quiet text buttons for the active node's controls (design rules: Task card, action
/// buttons). Only the active node has views, so a note full of collapsed cards creates none.
final class ChromeControls {
    private(set) var pos: Int?
    private var signature: [String] = []
    private var buttons: [QuietButton] = []
    private(set) var controls: [ChromeControl] = []

    func update(in view: ProseTextView, pos: Int?, region: ChromeRegion?, controls newControls: [ChromeControl]) {
        let newSignature = newControls.map(\.title)
        if pos != self.pos || newSignature != signature { rebuild(in: view, controls: newControls) }
        self.pos = pos
        signature = newSignature
        controls = newControls
        guard let region, let rect = view.chromeRect(region) else {
            buttons.forEach { $0.isHidden = true }
            return
        }
        let progress = region.progress
        // Footer: the strip reserved under the content, which grows with `progress`.
        let footer = region.box.footer * progress
        let centerY = rect.maxY - region.box.paddingBottom / 2 - footer / 2
        // Line the first label up with the text column, the last with its right edge.
        var leading = rect.minX + region.box.controlsInset, trailing = rect.maxX - 8
        for (button, control) in zip(buttons, controls) {
            button.isHidden = false
            let size = button.fittingSize
            let x: CGFloat
            if control.trailing { trailing -= size.width; x = trailing; trailing -= 2 } else { x = leading; leading += size.width + 2 }
            button.frame = CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
            button.alphaValue = max(0, (progress - 0.4) / 0.6)
        }
    }

    /// Titles of the buttons currently shown.
    var visibleTitles: [String] { buttons.compactMap { $0.isHidden ? nil : $0.name } }

    func button(titled title: String) -> NSButton? { buttons.first { $0.name == title } }

    func removeAll() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        pos = nil
        signature = []
        controls = []
    }

    private func rebuild(in view: ProseTextView, controls: [ChromeControl]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        for (index, control) in controls.enumerated() {
            let button = QuietButton(control, target: view, action: #selector(ProseTextView.chromeControlPressed(_:)))
            button.tag = index
            button.alphaValue = 0
            view.addSubview(button)
            buttons.append(button)
        }
    }
}

/// An 11pt secondary-label text button: no border; hover fills it (red for destructive).
/// Design rules: Task card, action buttons.
public final class QuietButton: NSButton {
    public let name: String
    private let control: ChromeControl
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    /// Shown in place of the control's title (a "Copied" confirmation); nil shows the title.
    public var label: String? { didSet { if label != oldValue { restyle() } } }

    public init(_ control: ChromeControl, target: AnyObject?, action: Selector?) {
        name = control.title
        self.control = control
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(control.title)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var fittingSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 8)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Centre the label in the padded box.
        let size = attributedTitle.size()
        attributedTitle.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    public override func viewDidChangeEffectiveAppearance() { restyle() }

    private func restyle() {
        let ink: NSColor = hovering ? (control.destructive ? .systemRed : .labelColor) : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString()
        if let shortcut = control.shortcut {
            text.append(NSAttributedString(string: shortcut + " ", attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(0.7)]))
        }
        text.append(NSAttributedString(string: label ?? control.title, attributes: [.font: font, .foregroundColor: ink]))
        attributedTitle = text
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill: NSColor? = hovering ? (control.destructive ? NSColor.systemRed.withAlphaComponent(0.08)
                                                                   : NSColor.labelColor.withAlphaComponent(dark ? 0.08 : 0.05)) : nil
            layer?.backgroundColor = fill?.cgColor
        }
        needsDisplay = true
    }
}
#endif
