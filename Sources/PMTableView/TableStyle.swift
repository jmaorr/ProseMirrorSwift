#if os(macOS)
import AppKit
/// Insets inside a table cell.
public typealias TableInsets = NSEdgeInsets
#elseif os(iOS)
import UIKit
public typealias TableInsets = UIEdgeInsets
#endif
#if os(macOS) || os(iOS)
import PMTextKit

/// How tables look. Colours come from the editor's theme (the app's DocStyle supplies them), so a
/// theme can restyle tables without touching the grid.
public struct TableStyle {
    /// Grid rules.
    public var rule: PlatformColor = .separatorColor
    /// Header cell fill.
    public var headerFill: PlatformColor = .quaternaryLabelColor.withAlphaComponent(0.5)
    /// Selection outline and tint, resize line, grips while dragging.
    public var accent: PlatformColor = .controlAccentColor
    /// Grip glyphs and "+" buttons.
    public var gripGlyph: PlatformColor = .secondaryLabelColor
    /// The page behind the table: a lifted (dragged) cell is filled with it.
    public var background: PlatformColor = .textBackgroundColor
    /// Behind the cell editor.
    public var editorFill: PlatformColor = .clear
    /// Inside each cell (as the web: 6px × 10px).
    public var cellPadding = TableInsets(top: 6, left: 10, bottom: 6, right: 10)
    public var ruleWidth: CGFloat = 1
    /// Narrowest a column without a set width gets (Tiptap's cellMinWidth).
    public var minFlexibleWidth: CGFloat = 25
    /// Narrowest width the native editor writes when a column is resized.
    public var minWrittenWidth: CGFloat = 48
    /// Room left of and above the grid for the row and column grips.
    public var gutter: CGFloat = 18
    /// Selection outline width and tint alpha.
    public var selectionOutline: CGFloat = 2
    public var selectionTint: CGFloat = 0.08
    /// How far a wide table fades out at an edge it scrolls past.
    public var edgeFade: CGFloat = 32

    public init() {}
}
#endif
