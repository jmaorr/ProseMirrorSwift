#if canImport(UIKit) && !os(macOS)
import UIKit
import PMModel
import PMState

/// The active node's controls (a task card's "New Task", "Description", "Delete") as quiet text
/// buttons in the footer the card reserves while active: the iOS counterpart of the AppKit
/// `ChromeControls`. Only the active node has buttons.
final class UIChromeControls {
    private(set) var pos: Int?
    private var signature: [String] = []
    private(set) var buttons: [ChromeButton] = []
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
        let footer = region.box.footer * progress
        let centerY = rect.maxY - region.box.paddingBottom / 2 - footer / 2
        var leading = rect.minX + region.box.controlsInset, trailing = rect.maxX - 8
        for (button, control) in zip(buttons, controls) {
            button.isHidden = false
            // At least 44 × 44 pt to touch; the label stays centred where it was.
            let label = button.intrinsicContentSize
            let size = CGSize(width: max(minimumTouchTarget, label.width), height: max(minimumTouchTarget, label.height))
            let x: CGFloat
            if control.trailing { trailing -= size.width; x = trailing; trailing -= 4 } else { x = leading; leading += size.width + 4 }
            button.frame = CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
            // While the footer opens the row is under 44 pt and the button reaches past the card,
            // over the next paragraph's first line: touches there stay the text's.
            button.touchClip = rect
            button.alpha = max(0, (progress - 0.4) / 0.6)
            button.isEnabled = progress > 0.5
        }
    }

    var visibleTitles: [String] { buttons.compactMap { $0.isHidden ? nil : $0.accessibilityIdentifier } }

    private func rebuild(in view: ProseTextView, controls: [ChromeControl]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        for (index, control) in controls.enumerated() {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            let label = (control.shortcut.map { $0 + " " } ?? "") + control.title
            config.attributedTitle = AttributedString(label, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
            ]))
            config.baseForegroundColor = control.destructive ? .systemRed : .secondaryLabel
            let button = ChromeButton(configuration: config, primaryAction: UIAction { [weak view] _ in
                view?.pressChromeControl(at: index)
            })
            button.accessibilityIdentifier = control.title
            button.accessibilityLabel = control.title
            button.alpha = 0
            view.addSubview(button)
            buttons.append(button)
        }
    }
}

/// A control button whose touch area (at least 44 × 44 pt) stops at its card's edge.
final class ChromeButton: UIButton {
    /// The card's rect in the button's superview (the text view); nil takes the whole frame.
    var touchClip: CGRect?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let touchClip, let superview else { return true }
        return touchClip.contains(convert(point, to: superview))
    }
}

extension ProseTextView {
    func layoutChromeControls() {
        let pos = chromeState.activePos
        let region = pos.flatMap { p in renderer.chromes.first { $0.pos == p } }
        if let region { ensureLayout(for: region) }
        let controls = pos.flatMap { state.doc.nodeAt($0) }.map { renderer.style.controls(for: $0) } ?? []
        chromeControls.update(in: self, pos: pos, region: region, controls: controls)
    }

    func pressChromeControl(at index: Int) {
        guard let pos = chromeControls.pos, index < chromeControls.controls.count else { return }
        // A button press is its own undo step, and the next typing starts another.
        runChromeControl(chromeControls.controls[index], at: pos)
    }

    /// The active chrome node and its control buttons, for tests.
    public var activeChrome: (pos: Int, progress: CGFloat, buttons: [String])? {
        guard let pos = chromeState.activePos else { return nil }
        return (pos, chromeState.progress(pos), chromeControls.visibleTitles)
    }

    /// Press the active node's control with this title, as a tap would. For tests.
    public func pressChromeControl(_ title: String) {
        guard let index = chromeControls.controls.firstIndex(where: { $0.title == title }) else { return }
        pressChromeControl(at: index)
    }
}
#endif
