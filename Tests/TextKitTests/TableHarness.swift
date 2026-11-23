// A text view with tables drawn by PMTableView's grids, on BasicSchema and BasicStyle, for the
// table tests.
#if os(macOS)
import XCTest
import AppKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import PMExampleSetup

/// A document view with tables drawn by grids, in an offscreen window: BasicStyle with
/// TableEmbeds (as `BasicStyle.makeTextView(state:)` sets it up) and exampleSetup's plugins
/// (on macOS: the table navigation keys and `tableEditing`).
@MainActor
final class TableHarness {
    let core: EditorCore
    let tables: TableEmbeds
    let view: ProseTextView
    let window: NSWindow

    init(_ doc: Node, width: CGFloat = 640, plugins: [Plugin]? = nil) throws {
        let schema = BasicSchema.schema
        core = EditorCore(state: EditorState.create(EditorStateConfig(doc: doc, plugins: plugins ?? exampleSetup(schema: schema))))
        var style = BasicStyle()
        let cellStyle = style
        tables = TableEmbeds(core: core, tableStyle: style.tableStyle, cellStyle: cellStyle)
        style.tables = tables
        view = ProseTextView(core: core, style: style)
        view.animatesChrome = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 30, height: 10)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        scroll.documentView = view
        window.contentView = scroll
        settle()
        // TextKit adds attachment views on a later pass.
        settle()
    }

    func settle() {
        // Drawing sets the current appearance; leave it as it was for other tests.
        let appearance = NSAppearance.current
        defer { NSAppearance.current = appearance }
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        view.layoutSubtreeIfNeeded()
        view.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        for grid in tables.grids { grid.superview?.superview?.superview?.layoutSubtreeIfNeeded() }
    }

    var grid: TableGridView { tables.grids.first! }

    func dispatch(_ tr: Transaction) {
        core.dispatch(tr)
        settle()
    }

    /// Top of the paragraph at a string offset, in the view.
    func lineTop(atString offset: Int) -> CGFloat {
        let tlm = view.textLayoutManager!
        let loc = tlm.textContentManager!.location(tlm.documentRange.location, offsetBy: offset)!
        tlm.ensureLayout(for: NSTextRange(location: loc))
        return tlm.textLayoutFragment(for: loc)!.layoutFragmentFrame.minY
    }

    /// Absolute position before cell (row, col) of the first table.
    func cellPos(_ row: Int, _ col: Int) throws -> Int {
        let map = try TableMap.get(grid.table!)
        return grid.tableStart + map.map[row * map.width + col]
    }

    func text(_ row: Int, _ col: Int) throws -> String { core.state.doc.nodeAt(try cellPos(row, col))!.textContent }

    func mouse(_ type: NSEvent.EventType, _ row: Int, _ col: Int, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        let rect = grid.layout.cellRect(pos: try cellPos(row, col) - grid.tableStart)!
        return NSEvent.mouseEvent(with: type, location: grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: flags,
                                  timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func key(_ view: NSView, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        settle()
    }

    /// A cell selection from (r0, c0) to (r1, c1), with the grid focused.
    func selectCells(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) throws {
        window.makeFirstResponder(grid)
        dispatch(core.state.tr.setSelection(try CellSelection.create(core.state.doc, try cellPos(r0, c0), try cellPos(r1, c1))))
    }

    /// p("above"), a table of paragraph cells, and p("below") unless `textAfter` is false.
    static func grid(_ rows: [[String]], textAfter: Bool = true) throws -> TableHarness {
        var content: [JSONValue] = [J.p("above"), J.table(rows)]
        if textAfter { content.append(J.p("below")) }
        return try TableHarness(try TestDocs.doc(content))
    }

    /// The host view around the first table's grid.
    func host() throws -> TableHostView { try XCTUnwrap(grid.enclosingScrollView?.superview as? TableHostView) }

    /// Writes the view as a PNG (for looking at, when TABLE_SNAPSHOT_DIR is set).
    func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["TABLE_SNAPSHOT_DIR"] else { return }
        settle()
        let appearance = NSAppearance.current
        defer { NSAppearance.current = appearance }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}

/// Table JSON helpers beyond Support's `J.table`: cells with attributes and any content.
enum TableJ {
    static func cell(_ content: [JSONValue], colwidth: JSONValue = .null, colspan: Int = 1, rowspan: Int = 1,
                     type: String = "table_cell") -> JSONValue {
        J.node(type, ["colspan": .number(Double(colspan)), "rowspan": .number(Double(rowspan)), "colwidth": colwidth], content)
    }
    static func textCell(_ text: String, colwidth: JSONValue = .null, colspan: Int = 1, rowspan: Int = 1,
                         type: String = "table_cell") -> JSONValue {
        cell([J.p(text)], colwidth: colwidth, colspan: colspan, rowspan: rowspan, type: type)
    }
    static func table(_ rows: [[JSONValue]]) -> JSONValue {
        J.node("table", nil, rows.map { J.node("table_row", nil, $0) })
    }

    /// Seeded tables, well-formed and malformed (ragged rows, spans that overlap or run past
    /// the table, missing and oversized colwidths), each in a document with a paragraph after.
    static func corpus(seed: Int, count: Int) throws -> [Node] {
        var state = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1)
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(n, 1)))
        }
        return try (0..<count).map { _ in
            let rows = 1 + next(4)
            let table: [[JSONValue]] = (0..<rows).map { r in
                (0..<(1 + next(4))).map { c in
                    let colspan = next(5) == 0 ? 2 + next(2) : 1
                    let rowspan = next(5) == 0 ? 2 + next(3) : 1
                    let widths: JSONValue
                    switch next(4) {
                    case 0: widths = .array((0..<colspan).map { _ in .number(Double(40 + next(200))) })
                    case 1: widths = .array([.number(Double(80))])
                    default: widths = .null
                    }
                    let content: [JSONValue] = next(6) == 0 ? [J.ul(["x", "y"])] : [J.p(next(3) == 0 ? "" : "r\(r)c\(c)")]
                    return cell(content, colwidth: widths, colspan: colspan, rowspan: rowspan, type: next(4) == 0 ? "table_header" : "table_cell")
                }
            }
            return try TestDocs.doc([TableJ.table(table), J.p("after")])
        }
    }

    /// Every table in `doc`, in document order, with the position before it.
    static func tables(_ doc: Node) -> [(node: Node, pos: Int)] {
        var out: [(Node, Int)] = []
        doc.descendants { node, pos, _, _ in
            if node.type.tableRole == .table { out.append((node, pos)) }
            return true
        }
        return out
    }
}

/// The pixels a layer draws, RGBA.
func tableBitmap(_ layer: CALayer) -> [UInt8] {
    let w = Int(max(layer.bounds.width, 1)), h = Int(max(layer.bounds.height, 1))
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.draw(in: ctx)
    return data
}

let tableArrowKeys: [String: (String, UInt16)] = [
    "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
    "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
]
#endif
