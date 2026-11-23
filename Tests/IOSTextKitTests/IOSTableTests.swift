#if os(iOS)
import XCTest
import UIKit
import PMModel
import PMState
import PMTextKit
import PMTables
import PMTableView
import PMExampleSetup

/// Tables in the iOS text view, view-only: the shared grid geometry drawn by cell layers,
/// scrolling sideways when wide, selected as one character, never edited. BasicStyle's
/// `makeTextView(state:)` wires the tables up.
@MainActor
final class IOSTableTests: XCTestCase {
    private var hosts: [HostedTextView] = []

    override func tearDown() {
        for host in hosts { host.window.isHidden = true }
        hosts = []
        super.tearDown()
    }

    // MARK: Fixtures

    /// A `rows` × `cols` table, the first row header cells; `colwidth` sets every column.
    private func table(rows: Int, cols: Int, colwidth: Int? = nil, text: (Int, Int) -> String = { "R\($0)C\($1)" }) -> JSONValue {
        J.node("table", nil, (0..<rows).map { r in
            J.node("table_row", nil, (0..<cols).map { c in
                var attrs: [(String, JSONValue)] = [("colspan", 1), ("rowspan", 1)]
                if let colwidth { attrs.append(("colwidth", [.number(Double(colwidth))])) }
                return J.node(r == 0 ? "table_header" : "table_cell", .object(JSONObject(attrs)), [J.p(text(r, c))])
            })
        })
    }

    /// A text view showing `blocks` with its tables drawn, in a window.
    private func textView(_ blocks: [JSONValue], width: CGFloat = 402, dark: Bool = false) throws -> (ProseTextView, TableEmbeds) {
        let host = HostedTextView(try TestDocs.doc(blocks), width: width, dark: dark)
        hosts.append(host)
        layout(host.view)
        let tables = try XCTUnwrap((host.view.renderer.style as? BasicStyle)?.tables, "BasicStyle's tables")
        return (host.view, tables)
    }

    private func layout(_ view: ProseTextView) {
        let tlm = view.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        tlm.ensureLayout(for: tlm.documentRange)
        view.layoutIfNeeded()
    }

    private func attachmentViews(_ view: ProseTextView) -> [UIView] {
        let tlm = view.textLayoutManager!
        var views: [UIView] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            views += fragment.textAttachmentViewProviders.compactMap(\.view)
            return true
        }
        return views
    }

    private func host(_ view: ProseTextView) throws -> TableHostView {
        try XCTUnwrap(attachmentViews(view).compactMap { $0 as? TableHostView }.first, "the table's view")
    }

    private func columnWidth(_ view: ProseTextView) -> CGFloat {
        view.textContainer.size.width - view.textContainer.lineFragmentPadding * 2
    }

    private func isInside(_ child: UIView, _ ancestor: UIView) -> Bool {
        var v: UIView? = child.superview
        while let current = v {
            if current === ancestor { return true }
            v = current.superview
        }
        return false
    }

    /// The table's position in the doc.
    private func tablePos(_ doc: Node) -> Int? {
        var found: Int?
        doc.descendants { node, pos, _, _ in
            if found == nil, node.type.tableRole == .table { found = pos }
            return found == nil
        }
        return found
    }

    /// Whether a position is inside a table node.
    private func isInTable(_ pos: ResolvedPos) -> Bool {
        (0...pos.depth).contains { pos.node($0).type.tableRole == .table }
    }

    // MARK: Tests

    /// The grid's cells are where the shared `TableLayout` puts them (as on the Mac), each
    /// drawn by a layer with the cell's rendered text, the header row filled, every cell ruled;
    /// the view is TextKit's attachment view in the text view, as wide as the column.
    func testTableRendersCellsLikeMac() throws {
        let (tv, tables) = try textView([J.p("Seed order"), table(rows: 4, cols: 3), J.p("After")])
        let host = try host(tv)
        XCTAssertTrue(isInside(host, tv), "TextKit hosts the view in the text view")
        let grid = host.grid
        XCTAssertTrue(tables.grid(at: grid.tablePos) === grid)
        let table = try XCTUnwrap(grid.table)
        let map = try TableMap.get(table)
        XCTAssertEqual(map.width, 3)
        XCTAssertEqual(map.height, 4)

        let column = columnWidth(tv)
        XCTAssertEqual(host.bounds.width, column, accuracy: 2, "as wide as the column")
        // The layout the Mac would make at this width, measured with fresh cells.
        let fresh = CellCache()
        let expected = TableLayout.make(table: table, map: map, availableWidth: grid.availableWidth, style: grid.style,
                                        contentHeight: { pos, width in
                                            fresh.cell(for: table.nodeAt(pos)!, style: grid.cellStyle, width: width).height(forWidth: width)
                                        })
        XCTAssertEqual(grid.layout, expected)
        XCTAssertEqual(grid.layout.columnWidths.reduce(0, +), grid.availableWidth, accuracy: 0.5, "fills the column")
        XCTAssertEqual(host.bounds.height, expected.size.height + grid.style.ruleWidth, accuracy: 0.5)

        let header = table.type.schema.nodes["table_header"]!
        for (pos, rect) in expected.cellRects {
            let layer = try XCTUnwrap(grid.cellLayer(at: pos), "a layer for the cell at \(pos)")
            // Each cell layer covers its rect and the rule on its right and bottom edges.
            let frame = layer.frame
            XCTAssertEqual(frame.minX, rect.minX, accuracy: 0.001)
            XCTAssertEqual(frame.minY, rect.minY, accuracy: 0.001)
            XCTAssertEqual(frame.width, rect.width + grid.style.ruleWidth, accuracy: 0.001)
            XCTAssertEqual(frame.height, rect.height + grid.style.ruleWidth, accuracy: 0.001)
            let node = table.nodeAt(pos)!
            XCTAssertEqual(layer.cell?.string.string.trimmingCharacters(in: .newlines), node.textContent)
            XCTAssertEqual(layer.borderWidth, grid.style.ruleWidth)
            XCTAssertEqual(layer.padding.left, grid.style.cellPadding.left)
            XCTAssertEqual(layer.padding.top, grid.style.cellPadding.top)
            XCTAssertEqual(layer.fill != nil, node.type === header, "header cells are filled")
        }
        // Header text is semibold, as on the Mac.
        let headerCell = try XCTUnwrap(grid.cellLayer(at: map.map[0])?.cell)
        let bodyCell = try XCTUnwrap(grid.cellLayer(at: map.map[3])?.cell)
        let headerFont = try XCTUnwrap(headerCell.string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let bodyFont = try XCTUnwrap(bodyCell.string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertNotEqual(headerFont.fontDescriptor, bodyFont.fontDescriptor, "header cells are semibold")

        XCTAssertTrue(host.isAccessibilityElement)
        XCTAssertEqual(host.accessibilityLabel, "Table, 4 rows, 3 columns")
    }

    /// In dark mode the rules and header fill resolve to the dark colours.
    func testTableColoursFollowDarkMode() throws {
        let (light, _) = try textView([table(rows: 2, cols: 2)])
        let (dark, _) = try textView([table(rows: 2, cols: 2)], dark: true)
        let lightGrid = try host(light).grid, darkGrid = try host(dark).grid
        let pos = try XCTUnwrap(lightGrid.layout.cellRects.keys.min())
        let lightLayer = try XCTUnwrap(lightGrid.cellLayer(at: pos)), darkLayer = try XCTUnwrap(darkGrid.cellLayer(at: pos))
        XCTAssertNotEqual(lightLayer.borderColor, darkLayer.borderColor)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(darkLayer.borderColor, darkGrid.style.rule.resolvedColor(with: traits).cgColor)
        XCTAssertEqual(darkLayer.fill, darkGrid.style.headerFill.resolvedColor(with: traits).cgColor)
        XCTAssertEqual(darkLayer.drawingTraits?.userInterfaceStyle, .dark)
    }

    /// How bright the text a cell layer draws is (0 black ... 1 white), drawn as Core
    /// Animation would, with the layer's own traits.
    private func textBrightness(_ layer: CellLayer) -> CGFloat {
        let size = layer.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            layer.draw(in: context.cgContext)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        var total: CGFloat = 0, count: CGFloat = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = y * cg.bytesPerRow + x * 4
                guard bytes[i + 3] > 240 else { continue }
                total += (CGFloat(bytes[i]) + CGFloat(bytes[i + 1]) + CGFloat(bytes[i + 2])) / (3 * 255)
                count += 1
            }
        }
        // The text's ink: its solid pixels' mean brightness.
        return count > 0 ? total / count : -1
    }

    /// Switching light ↔ dark redraws the cells' text in the new mode's ink (TextKit resolves
    /// dynamic colours when it lays text out, so the cells are laid out again).
    func testCellTextFollowsAppearanceChanges() throws {
        let (tv, _) = try textView([J.p("Seed plan"), table(rows: 2, cols: 2),
                                    J.p("Weekly"), table(rows: 2, cols: 10, colwidth: 150)])
        for host in attachmentViews(tv).compactMap({ $0 as? TableHostView }) {
            let pos = try XCTUnwrap(host.grid.layout.cellRects.keys.max())
            XCTAssertLessThan(textBrightness(try XCTUnwrap(host.grid.cellLayer(at: pos))), 0.4, "dark ink in light mode")
        }
        tv.window?.overrideUserInterfaceStyle = .dark
        layout(tv)
        for host in attachmentViews(tv).compactMap({ $0 as? TableHostView }) {
            let layer = try XCTUnwrap(host.grid.cellLayer(at: try XCTUnwrap(host.grid.layout.cellRects.keys.max())))
            XCTAssertEqual(layer.drawingTraits?.userInterfaceStyle, .dark)
            XCTAssertGreaterThan(textBrightness(layer), 0.6, "light ink in dark mode")
        }
        tv.window?.overrideUserInterfaceStyle = .light
        layout(tv)
        for host in attachmentViews(tv).compactMap({ $0 as? TableHostView }) {
            let layer = try XCTUnwrap(host.grid.cellLayer(at: try XCTUnwrap(host.grid.layout.cellRects.keys.max())))
            XCTAssertLessThan(textBrightness(layer), 0.4, "dark ink again in light mode")
        }
    }

    /// A table wider than the column (ten 150 pt columns) scrolls sideways inside a view as
    /// wide as the column; the document itself doesn't get wider.
    func testWideTableScrollsHorizontally() throws {
        let (tv, _) = try textView([J.p("Harvest log"), table(rows: 3, cols: 10, colwidth: 150)])
        let host = try host(tv)
        let column = columnWidth(tv)
        XCTAssertEqual(host.bounds.width, column, accuracy: 2)
        XCTAssertEqual(host.grid.layout.size.width, 1500)
        let scroll = host.scrollView
        XCTAssertEqual(scroll.frame.width, host.bounds.width, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.width, 1500 + host.grid.style.ruleWidth, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.height, scroll.frame.height, accuracy: 0.5, "no vertical scrolling")
        XCTAssertTrue(host.scrolls)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertFalse(scroll.alwaysBounceVertical)
        scroll.setContentOffset(CGPoint(x: 600, y: 0), animated: false)
        XCTAssertEqual(scroll.contentOffset.x, 600)
        XCTAssertLessThanOrEqual(tv.contentSize.width, tv.bounds.width + 0.5, "the document doesn't scroll sideways")

        // A narrow table fits and doesn't scroll.
        let (narrow, _) = try textView([table(rows: 2, cols: 3)])
        XCTAssertFalse(try self.host(narrow).scrolls)
    }

    /// The table is one character in the text; tapping it selects it as one character (a node
    /// selection of the table), and a caret put on its character never lands inside a cell.
    func testTableSelectsAsOneCharacter() throws {
        let (tv, _) = try textView([J.p("Before"), table(rows: 3, cols: 4), J.p("After")])
        let pos = try XCTUnwrap(tablePos(tv.state.doc))
        let offset = tv.renderer.stringOffset(pos, bias: 1)
        let ns = tv.textStorage.string as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: offset, length: 1)), "\u{FFFC}")
        XCTAssertEqual(tv.textStorage.string, "Before\n\u{FFFC}\nAfter\n", "the whole table is one character")
        let host = try host(tv)
        XCTAssertTrue(tv.textStorage.attribute(.attachment, at: offset, effectiveRange: nil) is TableAttachment)

        host.tap(at: CGPoint(x: 20, y: 10))
        let selection = try XCTUnwrap(tv.state.selection as? NodeSelection, "a node selection, not \(tv.state.selection)")
        XCTAssertEqual(selection.from, pos)
        XCTAssertTrue(selection.node.type.tableRole == .table)
        XCTAssertEqual(tv.selectedRange, NSRange(location: offset, length: 1))

        // A caret put on the table's character (arrow keys, a tap beside it) selects the table.
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.selectedRange = NSRange(location: offset, length: 0)
        tv.delegate?.textViewDidChangeSelection?(tv)
        XCTAssertFalse(isInTable(tv.state.selection.fromPos), "caret went into the table: \(tv.state.selection)")
        XCTAssertFalse(isInTable(tv.state.selection.toPos))

        // Nothing puts the selection in a cell: a selection set in one becomes the table's.
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 4)))
        XCTAssertEqual((tv.state.selection as? NodeSelection)?.from, pos)
        let map = try TableMap.get(tv.state.doc.nodeAt(pos)!)
        tv.dispatch(tv.state.tr.setSelection(try CellSelection.create(tv.state.doc, pos + 1 + map.map[0], pos + 1 + map.map[5])))
        XCTAssertEqual((tv.state.selection as? NodeSelection)?.from, pos)
    }

    /// Tapping a cell opens no cell editor and changes nothing; typing then doesn't reach a cell.
    func testTableIsNotEditableOnIOS() throws {
        let (tv, tables) = try textView([J.p("Before"), table(rows: 3, cols: 4), J.p("After")])
        let host = try host(tv)
        let grid = host.grid
        let before = tv.state.doc
        let cell = try XCTUnwrap(grid.layout.cellRects.values.first { $0.minY > 0 && $0.minX > 0 })
        host.tap(at: CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertNil(grid.editor, "no cell editor")
        XCTAssertFalse(tables.composing)
        XCTAssertTrue(tv.state.doc.eq(before), "doc unchanged")
        XCTAssertFalse(isInTable(tv.state.selection.fromPos), "no caret in a cell")
        XCTAssertFalse(host.subviews.contains { $0 is UITextView } || grid.subviews.contains { $0 is UITextView })
        // No table editing gestures on iOS: only the tap.
        XCTAssertEqual(host.gestureRecognizers?.count, 1)
        let table = try XCTUnwrap(grid.table)
        XCTAssertEqual(table.textContent, before.nodeAt(grid.tablePos)?.textContent)
    }

    /// A tap selects the table without raising the keyboard: the text view becomes first
    /// responder only if it already was, so a stray keystroke can't replace the table.
    func testTapSelectsWithoutKeyboard() throws {
        let (tv, _) = try textView([J.p("Before"), table(rows: 2, cols: 2), J.p("After")])
        let host = try host(tv)
        XCTAssertFalse(tv.isFirstResponder)
        host.tap(at: CGPoint(x: 20, y: 10))
        XCTAssertFalse(tv.isFirstResponder, "the tap raised the keyboard")
        XCTAssertEqual((tv.state.selection as? NodeSelection)?.from, host.grid.tablePos)

        // Already editing: it stays first responder, and the table is selected.
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, 2)))
        XCTAssertTrue(tv.becomeFirstResponder())
        host.tap(at: CGPoint(x: 20, y: 10))
        XCTAssertTrue(tv.isFirstResponder)
        XCTAssertEqual((tv.state.selection as? NodeSelection)?.from, host.grid.tablePos)
    }

    /// With the keyboard up, a selected table isn't replaced by typing, a correction, dictation
    /// or a composition (BasicStyle's text view keeps tables, which iOS can't make again);
    /// Backspace still deletes it on purpose.
    func testSelectedTableIsNotReplacedByText() throws {
        let (tv, _) = try textView([J.h(1, "Plan"), table(rows: 2, cols: 2), J.p("After")])
        XCTAssertTrue(tv.becomeFirstResponder())
        let host = try host(tv)
        func selectTable() {
            host.tap(at: CGPoint(x: 20, y: 10))
            XCTAssertEqual((tv.state.selection as? NodeSelection)?.from, host.grid.tablePos)
        }
        selectTable()
        let offset = tv.selectedRange.location
        tv.insertText("x")
        XCTAssertNotNil(tablePos(tv.state.doc), "typing replaced the table")
        selectTable()
        let range = tv.textRange(from: tv.position(from: tv.beginningOfDocument, offset: offset)!,
                                 to: tv.position(from: tv.beginningOfDocument, offset: offset + 1)!)!
        tv.replace(range, withText: "Corrected")
        XCTAssertNotNil(tablePos(tv.state.doc), "a replacement replaced the table")
        selectTable()
        XCTAssertFalse(tv.textView(tv, shouldChangeTextIn: NSRange(location: offset, length: 1), replacementText: "dictated"))
        XCTAssertNotNil(tablePos(tv.state.doc), "the gate let text replace the table")
        selectTable()
        tv.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
        tv.unmarkText()
        XCTAssertNotNil(tablePos(tv.state.doc), "a composition replaced the table")
        XCTAssertEqual(tv.state.doc.textContent, "PlanR0C0R0C1R1C0R1C1After", "nothing typed anywhere")
        selectTable()
        tv.deleteBackward()
        XCTAssertNil(tablePos(tv.state.doc), "Backspace deletes a selected table")
    }

    /// A range from inside a table to text past it, with no text before the table, grows to
    /// the table's own edge rather than shrinking to the table.
    func testRangeFromATableGrowsToItsEdge() throws {
        let (tv, _) = try textView([table(rows: 2, cols: 2), J.p("After")])
        let pos = try XCTUnwrap(tablePos(tv.state.doc))
        let size = tv.state.doc.nodeAt(pos)!.nodeSize
        let afterEnd = pos + size + 1 + "After".utf16.count
        tv.dispatch(tv.state.tr.setSelection(TextSelection.create(tv.state.doc, pos + 4, afterEnd)))
        let sel = tv.state.selection
        XCTAssertTrue(sel is TextSelection, "not \(sel)")
        XCTAssertEqual(sel.from, pos, "from the table's start")
        XCTAssertEqual(sel.to, afterEnd, "to where the range ended")
        XCTAssertFalse(isInTable(sel.fromPos))
    }

    /// An edit made elsewhere (as a remote change would: a cell's text and a new row)
    /// re-renders the grid and lays the table's line out again at its new height.
    func testTableReRendersOnChange() throws {
        let (tv, _) = try textView([J.p("Before"), table(rows: 2, cols: 2), J.p("After")])
        let host = try host(tv)
        let grid = host.grid
        let pos = grid.tablePos
        let oldHeight = host.bounds.height
        let table = try XCTUnwrap(grid.table)
        let map = try TableMap.get(table)
        let cellPos = map.map[2]
        // Text into the second row's first cell (inside its paragraph), and a third row.
        let tr = tv.state.tr
        _ = try tr.insertText(" — sown", pos + 1 + cellPos + 1 + 1 + "R1C0".utf16.count)
        let row = try XCTUnwrap(tv.state.doc.nodeAt(pos)?.child(1))
        _ = try tr.insert(pos + (tr.doc.nodeAt(pos)!.nodeSize) - 1, row)
        tv.dispatch(tr)
        layout(tv)

        XCTAssertEqual(grid.layout.rowHeights.count, 3)
        XCTAssertEqual(grid.cellLayer(at: cellPos)?.cell?.node.textContent, "R1C0 — sown")
        XCTAssertEqual(host.accessibilityLabel, "Table, 3 rows, 2 columns")
        let shown = try self.host(tv)
        XCTAssertTrue(shown === host, "the same view, kept across edits")
        XCTAssertGreaterThan(shown.bounds.height, oldHeight + 10, "the line was laid out at the new height")
    }

    /// A change replacing a range that covers an unchanged table (as a sync from another
    /// device may: a cell edited in an earlier table, the rest of the document rewritten with
    /// the same nodes) keeps that table's view, still updated: the text keeps the same node and
    /// so the same attachment, and the table's embeds must too, or the view is left behind.
    func testTableKeptWhenAChangeSpansIt() throws {
        let (tv, tables) = try textView([J.p("Seed plan"), table(rows: 2, cols: 2), J.p("Weekly"),
                                         table(rows: 2, cols: 3), J.p("End")])
        let doc = tv.state.doc
        let first = try XCTUnwrap(tablePos(doc))
        let firstTable = try XCTUnwrap(doc.nodeAt(first))
        let edited = try tv.state.schema.nodeFromJSON(table(rows: 2, cols: 2) { r, c in r == 1 && c == 0 ? "Beans" : "R\(r)C\(c)" })
        // Everything from the first table to the end, the later nodes the same instances.
        var rest: [Node] = [edited]
        for i in 2..<doc.childCount { rest.append(doc.child(i)) }
        let secondNode = doc.child(3)
        let tr = tv.state.tr
        _ = try tr.replaceWith(first, doc.content.size, rest)
        tv.dispatch(tr)
        layout(tv)
        XCTAssertTrue(tv.state.doc.child(3) === secondNode, "the later table is the same node")
        XCTAssertFalse(firstTable === tv.state.doc.child(1))

        let secondPos = first + edited.nodeSize + tv.state.doc.child(2).nodeSize
        let offset = tv.renderer.stringOffset(secondPos, bias: 1)
        let shown = try XCTUnwrap(tv.textStorage.attribute(.attachment, at: offset, effectiveRange: nil) as? TableAttachment)
        XCTAssertTrue(shown.grid === tables.grid(at: secondPos), "the shown table is the one the embeds update")
        XCTAssertEqual(shown.grid.tablePos, secondPos)
        XCTAssertNotNil(shown.grid.table)

        // Later changes still reach it.
        let map = try TableMap.get(secondNode)
        tv.dispatch(try tv.state.tr.insertText("Rain ", secondPos + 1 + map.map[3] + 2))
        XCTAssertEqual(shown.grid.cellLayer(at: map.map[3])?.cell?.node.textContent, "Rain R1C0")
    }
}
#endif
