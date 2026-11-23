// tiptap-markdown 0.8.10's serializer state (`src/serialize/state.js`, `src/util/markdown.js`;
// MIT, Antoine Guingand): after each block, emphasis delimiters with whitespace inside are
// shifted inwards until they're valid CommonMark (markdown-it's scanDelims decides), and
// dropped if nothing is left between them. Lengths and offsets are UTF-16, as in JS.

import Foundation
import PMModel

open class TiptapMarkdownSerializerState: MarkdownSerializerState {
    public var inTable = false
    private var inlines: [(start: Int, end: Int?, delimiter: String)] = []

    open override func render(_ node: Node, _ parent: Node, _ index: Int) throws {
        try super.render(node, parent, index)
        // As in JS, a start (or end) of 0 counts as unset.
        if let top = inlines.last, top.start != 0, let end = top.end, end != 0 {
            var start = top.start
            let units = Array(out.utf16)
            while start < units.count, Self.isJSWhitespace(units[start]) { start += 1 }
            out = Self.trimInline(out, top.delimiter, start, end)
            inlines.removeLast()
        }
    }

    open override func markString(_ mark: Mark, _ open: Bool, _ parent: Node, _ index: Int) throws -> String {
        if let info = marks[mark.type.name], info.expelEnclosingWhitespace {
            if open {
                let delimiter: String
                if case .text(let s) = info.open { delimiter = s } else { delimiter = "" }
                inlines.append((out.utf16.count, nil, delimiter))
            } else if let top = inlines.popLast() {
                inlines.append((top.start, out.utf16.count, top.delimiter))
            }
        }
        return try super.markString(mark, open, parent, index)
    }

    // MARK: trimInline (util/markdown.js)

    static func shiftDelim(_ text: [UInt16], _ delim: [UInt16], _ start: Int, _ offset: Int) -> [UInt16] {
        var res = Array(text[0..<min(start, text.count)]) + Array(text[min(start + delim.count, text.count)...])
        let at = max(0, min(start + offset, res.count))
        res = Array(res[0..<at]) + delim + Array(res[at...])
        return res
    }

    public static func trimInline(_ text: String, _ delim: String, _ from: Int, _ to: Int) -> String {
        var res = Array(text.utf16)
        let d = Array(delim.utf16)
        var from = from, to = to
        // trimStart
        var pos = from
        while pos < to {
            if scanDelims(res, pos).canOpen { break }
            res = shiftDelim(res, d, pos, 1)
            pos += 1
        }
        from = pos
        // trimEnd
        pos = to
        while pos > from {
            if scanDelims(res, pos).canClose { break }
            res = shiftDelim(res, d, pos, -1)
            pos -= 1
        }
        to = pos
        if to - from < d.count + 1 {
            res = Array(res[0..<min(from, res.count)]) + Array(res[min(to + d.count, res.count)...])
        }
        return String(utf16CodeUnits: res, count: res.count)
    }

    // MARK: markdown-it 14 StateInline.scanDelims (canSplitWord: true)

    static func scanDelims(_ src: [UInt16], _ start: Int) -> (canOpen: Bool, canClose: Bool) {
        let max = src.count
        // Past the end JS reads NaN as the marker: no run, but the flanking checks still apply.
        let marker: UInt16? = start < max ? src[start] : nil
        func unit(_ i: Int) -> UInt32 { i >= 0 && i < max ? UInt32(src[i]) : 0 }
        var last: UInt32
        if start == 0 {
            last = 0x20
        } else if start == 1 {
            last = unit(0)
            if last & 0xF800 == 0xD800 { last = 0xFFFD }
        } else {
            last = unit(start - 1)
            if last & 0xFC00 == 0xDC00 {
                let high = unit(start - 2)
                last = high & 0xFC00 == 0xD800 ? 0x10000 + ((high - 0xD800) << 10) + (last - 0xDC00) : 0xFFFD
            } else if last & 0xFC00 == 0xD800 {
                last = 0xFFFD
            }
        }
        var pos = start
        while pos < max, let marker, src[pos] == marker { pos += 1 }
        var next: UInt32 = pos < max ? UInt32(src[pos]) : 0x20
        if next & 0xFC00 == 0xD800 {
            let low = unit(pos + 1)
            next = low & 0xFC00 == 0xDC00 ? 0x10000 + ((next - 0xD800) << 10) + (low - 0xDC00) : 0xFFFD
        } else if next & 0xFC00 == 0xDC00 {
            next = 0xFFFD
        }
        let lastPunct = isMdAsciiPunct(last) || isPunct(last)
        let nextPunct = isMdAsciiPunct(next) || isPunct(next)
        let lastSpace = isWhiteSpace(last), nextSpace = isWhiteSpace(next)
        let leftFlanking = !nextSpace && (!nextPunct || lastSpace || lastPunct)
        let rightFlanking = !lastSpace && (!lastPunct || nextSpace || nextPunct)
        return (leftFlanking, rightFlanking)
    }

    static func isWhiteSpace(_ c: UInt32) -> Bool {
        if c >= 0x2000 && c <= 0x200A { return true }
        return [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000].contains(c)
    }

    static func isMdAsciiPunct(_ c: UInt32) -> Bool {
        (0x21...0x2F).contains(c) || (0x3A...0x40).contains(c) || (0x5B...0x60).contains(c) || (0x7B...0x7E).contains(c)
    }

    /// Unicode punctuation or symbol (markdown-it: ucmicro P or S).
    static func isPunct(_ c: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// JS `/\s/` on one UTF-16 unit.
    static func isJSWhitespace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
}
