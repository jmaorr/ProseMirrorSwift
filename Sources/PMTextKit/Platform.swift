// Platform glue so the renderer, styles and decoration drawing compile for AppKit and UIKit
// alike. Only what differs between the two lives here; NSAttributedString, NSParagraphStyle,
// NSTextAttachment and TextKit 2 are shared already. On macOS every name below resolves to
// the AppKit call the code used before, so its output is unchanged.
#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformFontDescriptor = UIFontDescriptor
#endif

#if os(macOS) || canImport(UIKit)
import CoreText

#if canImport(UIKit) && !os(macOS)
// AppKit's names for the system colours the renderer and styles use, so shared code reads
// the same on both platforms. Each is the matching dynamic UIKit colour.
public extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var quaternaryLabelColor: UIColor { .quaternaryLabel }
    static var linkColor: UIColor { .link }
    static var separatorColor: UIColor { .separator }
    static var controlAccentColor: UIColor { .tintColor }
    static var textColor: UIColor { .label }
    static var textBackgroundColor: UIColor { .systemBackground }
    /// AppKit's is the text background (white / near-black); a card on a page is the same.
    static var controlBackgroundColor: UIColor { .systemBackground }
    static var shadowColor: UIColor { .black }
    static var selectedTextBackgroundColor: UIColor { .tintColor.withAlphaComponent(0.2) }

    /// AppKit's sRGB initialiser; UIKit's `init(red:green:blue:alpha:)` is extended sRGB, the same
    /// for components in 0...1.
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// AppKit's `alphaComponent`.
    var alphaComponent: CGFloat {
        var a: CGFloat = 0
        if getRed(nil, green: nil, blue: nil, alpha: &a) { return a }
        return cgColor.alpha
    }
}

public extension UIFont {
    /// AppKit's `systemFontSize` is 13; UIKit's body text is 17 (UIFont.systemFontSize is 14).
    static var smallSystemFontSize: CGFloat { 12 }
}
#endif

public extension PlatformFont {
    /// The same font with tabular (monospaced) digits, for list numbers.
    var withMonospacedDigits: PlatformFont {
        #if os(macOS)
        let desc = fontDescriptor.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]],
        ])
        return NSFont(descriptor: desc, size: pointSize) ?? self
        #else
        let desc = fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: desc, size: pointSize)
        #endif
    }

    /// The font from `descriptor` at `size`, or nil (AppKit's failable initialiser; UIKit's
    /// never fails).
    static func make(_ descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont? {
        #if os(macOS)
        return NSFont(descriptor: descriptor, size: size)
        #else
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    /// The same font with bold and/or italic added (AppKit: falling back to the font manager
    /// for faces whose descriptor has no bold), or the font itself.
    func adding(bold: Bool, italic: Bool) -> PlatformFont {
        guard bold || italic else { return self }
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let desc = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        var font = NSFont(descriptor: desc, size: pointSize) ?? self
        if bold, !font.fontDescriptor.symbolicTraits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let desc = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: desc, size: pointSize)
        #endif
    }

    var isBold: Bool {
        #if os(macOS)
        return fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    var isItalic: Bool {
        #if os(macOS)
        return fontDescriptor.symbolicTraits.contains(.italic)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }
}

public extension PlatformImage {
    /// An SF Symbol by name.
    static func symbol(_ name: String, accessibilityDescription: String? = nil) -> PlatformImage? {
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        #else
        // UIImage(systemName:) hands out a shared, cached instance: label a configured copy so one
        // image's description doesn't replace every other's.
        guard let shared = UIImage(systemName: name) else { return nil }
        guard let accessibilityDescription else { return shared }
        let image = shared.withConfiguration(UIImage.SymbolConfiguration(scale: .default))
        image.accessibilityLabel = accessibilityDescription
        return image
        #endif
    }
}

public extension NSAttributedString.Key {
    /// A hover tooltip on macOS. iOS has no hover text; the key is set but nothing reads it.
    static let pmToolTip = NSAttributedString.Key("NSToolTip")
}

public extension PlatformBezierPath {
    /// A rounded rectangle with the same corner shape on both platforms (UIKit's own
    /// rounded-rect initialiser draws continuous corners).
    static func rounded(_ rect: CGRect, radius: CGFloat) -> PlatformBezierPath {
        #if os(macOS)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #else
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return UIBezierPath(cgPath: CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        #endif
    }
}

extension CGRect {
    /// Fill with the current fill colour (AppKit's `NSRect.fill()`).
    func pmFill() {
        #if os(macOS)
        fill()
        #else
        UIRectFillUsingBlendMode(self, .normal)
        #endif
    }
}

/// The graphics context AppKit or UIKit is drawing into right now.
func currentCGContext() -> CGContext? {
    #if os(macOS)
    return NSGraphicsContext.current?.cgContext
    #else
    return UIGraphicsGetCurrentContext()
    #endif
}

/// Replaces the system's Reduce Motion setting (tests; the setting itself can't be changed from
/// a test). nil follows the system.
nonisolated(unsafe) var reduceMotionOverride: Bool?

/// Whether the user asked for reduced motion.
func prefersReducedMotion() -> Bool {
    if let reduceMotionOverride { return reduceMotionOverride }
    #if os(macOS)
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #else
    return UIAccessibility.isReduceMotionEnabled
    #endif
}
#endif
