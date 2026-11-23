// Ported from prosemirror-markdown 1.13.7 `src/to_markdown.ts` (MIT, Marijn Haverbeke and
// others; see LICENSE-PROSEMIRROR). The serializer only: parsing (markdown-it) isn't ported.
// Regular expressions are the JS ones run through NSRegularExpression on UTF-16, with JS's
// ASCII-only `\w` and `\d` spelled out, so edge cases behave the same.

import Foundation
import PMModel

/// How a mark is written: its opening and closing syntax.
public struct MarkSerializerSpec {
    public enum Delimiter {
        case text(String)
        case function((MarkdownSerializerState, Mark, Node, Int) -> String)
    }
    public var open: Delimiter
    public var close: Delimiter
    /// The order relative to other mixable marks can vary (`**a *b***` and `*a **b***`).
    public var mixable: Bool
    /// Move whitespace at the edges from inside the mark to outside it (CommonMark emphasis).
    public var expelEnclosingWhitespace: Bool
    /// `false` turns escaping off inside the mark (it must then be the innermost mark).
    public var escape: Bool

    public init(open: Delimiter, close: Delimiter, mixable: Bool = false, expelEnclosingWhitespace: Bool = false, escape: Bool = true) {
        self.open = open
        self.close = close
        self.mixable = mixable
        self.expelEnclosingWhitespace = expelEnclosingWhitespace
        self.escape = escape
    }

    public init(_ open: String, _ close: String, mixable: Bool = false, expelEnclosingWhitespace: Bool = false, escape: Bool = true) {
        self.init(open: .text(open), close: .text(close), mixable: mixable, expelEnclosingWhitespace: expelEnclosingWhitespace, escape: escape)
    }
}

public typealias NodeSerializer = (MarkdownSerializerState, Node, Node, Int) -> Void

public struct MarkdownSerializerOptions {
    /// Extra characters to escape (a regular expression; matches are prefixed with a backslash).
    public var escapeExtraCharacters: NSRegularExpression?
    /// The hard break node's name (default "hard_break").
    public var hardBreakNodeName = "hard_break"
    /// When false, nodes and marks without a serializer are rendered by their content only.
    public var strict = true
    /// Render lists tight (no blank lines between items) unless a node's `tight` attr says otherwise.
    public var tightLists = false
    public init() {}
}

public enum MarkdownSerializerError: Error, CustomStringConvertible {
    case unsupportedNode(String), unsupportedMark(String)
    public var description: String {
        switch self {
        case .unsupportedNode(let n): return "Token type `\(n)` not supported by Markdown renderer"
        case .unsupportedMark(let m): return "Mark type `\(m)` not supported by Markdown renderer"
        }
    }
}

/// A specification for serializing a ProseMirror document as Markdown/CommonMark text.
public struct MarkdownSerializer {
    public var nodes: [String: NodeSerializer]
    public var marks: [String: MarkSerializerSpec]
    public var options: MarkdownSerializerOptions
    /// Makes the state for a run (tiptap-markdown overrides it); defaults to MarkdownSerializerState.
    public var makeState: ([String: NodeSerializer], [String: MarkSerializerSpec], MarkdownSerializerOptions) -> MarkdownSerializerState

    public init(nodes: [String: NodeSerializer], marks: [String: MarkSerializerSpec], options: MarkdownSerializerOptions = .init(),
                makeState: (([String: NodeSerializer], [String: MarkSerializerSpec], MarkdownSerializerOptions) -> MarkdownSerializerState)? = nil) {
        self.nodes = nodes
        self.marks = marks
        self.options = options
        self.makeState = makeState ?? { MarkdownSerializerState(nodes: $0, marks: $1, options: $2) }
    }

    /// The content of `content` as CommonMark.
    public func serialize(_ content: Node, tightLists: Bool? = nil) throws -> String {
        var options = self.options
        if let tightLists { options.tightLists = tightLists }
        let state = makeState(nodes, marks, options)
        try state.renderContent(content)
        return state.out
    }
}

/// Serialization state, passed to node and mark serializers.
open class MarkdownSerializerState {
    public internal(set) var delim = ""
    public var out = ""
    public var closed: Node?
    public var inAutolink: Bool?
    public var atBlockStart = false
    public var inTightList = false

    public let nodes: [String: NodeSerializer]
    public let marks: [String: MarkSerializerSpec]
    public let options: MarkdownSerializerOptions
    /// An error thrown inside a node serializer (they can't throw); rethrown by render.
    var pendingError: Error?

    public init(nodes: [String: NodeSerializer], marks: [String: MarkSerializerSpec], options: MarkdownSerializerOptions) {
        self.nodes = nodes
        self.marks = marks
        self.options = options
    }

    public func setDelim(_ delim: String) { self.delim = delim }

    public func flushClose(_ size: Int = 2) {
        guard closed != nil else { return }
        if !atBlank() { out += "\n" }
        if size > 1 {
            let delimMin = Regex.replace(delim, #"\s+$"#, "")
            for _ in 1..<size { out += delimMin + "\n" }
        }
        closed = nil
    }

    func getMark(_ name: String) throws -> MarkSerializerSpec {
        if let info = marks[name] { return info }
        if options.strict { throw MarkdownSerializerError.unsupportedMark(name) }
        return MarkSerializerSpec("", "", mixable: true)
    }

    /// Render a block, prefixing each line with `delim` and the first with `firstDelim`.
    public func wrapBlock(_ delim: String, _ firstDelim: String?, _ node: Node, _ f: () throws -> Void) rethrows {
        let old = self.delim
        write(firstDelim ?? delim)
        self.delim += delim
        try f()
        self.delim = old
        closeBlock(node)
    }

    func atBlank() -> Bool { out.isEmpty || out.hasSuffix("\n") }

    /// Ensure the output ends with a newline.
    public func ensureNewLine() { if !atBlank() { out += "\n" } }

    /// Close pending blocks, add the delimiter, then `content` unescaped.
    public func write(_ content: String? = nil) {
        flushClose()
        if !delim.isEmpty && atBlank() { out += delim }
        if let content, !content.isEmpty { out += content }
    }

    public func closeBlock(_ node: Node) { closed = node }

    /// Add text, escaped unless `escape` is false.
    public func text(_ text: String, _ escape: Bool = true) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            write()
            // Escape exclamation marks in front of links.
            if !escape, line.hasPrefix("["), Regex.matches(out, #"(^|[^\\])\!$"#) {
                out = String(out.dropLast()) + "\\!"
            }
            out += escape ? esc(line, atBlockStart) : line
            if i != lines.count - 1 { out += "\n" }
        }
    }

    /// Render `node` as a block.
    open func render(_ node: Node, _ parent: Node, _ index: Int) throws {
        if let f = nodes[node.type.name] {
            f(self, node, parent, index)
            if let e = pendingError { pendingError = nil; throw e }
        } else if options.strict {
            throw MarkdownSerializerError.unsupportedNode(node.type.name)
        } else if !node.type.isLeaf {
            if node.type.inlineContent { try renderInline(node) } else { try renderContent(node) }
            if node.isBlock { closeBlock(node) }
        }
    }

    /// For node serializers (which can't throw): render, keeping an error for render to rethrow.
    public func renderOrRecord(_ body: () throws -> Void) {
        do { try body() } catch { pendingError = pendingError ?? error }
    }

    /// Render `parent`'s content as blocks.
    public func renderContent(_ parent: Node) throws {
        for i in 0..<parent.childCount { try render(parent.child(i), parent, i) }
    }

    /// Render `parent`'s content inline.
    public func renderInline(_ parent: Node, _ fromBlockStart: Bool = true) throws {
        atBlockStart = fromBlockStart
        var active: [Mark] = []
        var trailing = ""
        func progress(_ nodeIn: Node?, _ index: Int) throws {
            var node = nodeIn
            var marks = node?.marks ?? []

            // Drop marks from a hard break that's the last node inside them.
            if let n = node, n.type.name == options.hardBreakNodeName {
                marks = marks.filter { m in
                    if index + 1 == parent.childCount { return false }
                    let next = parent.child(index + 1)
                    return m.isInSet(next.marks) && (!next.isText || Regex.matches(next.text ?? "", #"\S"#))
                }
            }

            let inner = marks.last
            let noEsc = try inner.map { try getMark($0.type.name).escape == false } ?? false
            let len = marks.count - (noEsc ? 1 : 0)

            // Reorder mixable marks so their order matches `active`.
            outer: for i in 0..<len {
                let mark = marks[i]
                if try !getMark(mark.type.name).mixable { break }
                for j in 0..<active.count {
                    let other = active[j]
                    if try !getMark(other.type.name).mixable { break }
                    if mark.eq(other) {
                        if i > j {
                            marks = slice(marks, 0, j) + [mark] + slice(marks, j, i) + slice(marks, i + 1, len)
                        } else if j > i {
                            marks = slice(marks, 0, i) + slice(marks, i + 1, j) + [mark] + slice(marks, j, len)
                        }
                        continue outer
                    }
                }
            }

            // The prefix of the mark set that didn't change.
            var keep = 0
            while keep < min(active.count, len), marks[keep].eq(active[keep]) { keep += 1 }

            var leading = trailing
            trailing = ""
            // Expel enclosing whitespace from marks that need it.
            if let n = node, n.isText, try marks.contains(where: { mark in
                let info = try getMark(mark.type.name)
                return info.expelEnclosingWhitespace && !active.enumerated().contains { i, m in i < keep && m.eq(mark) }
            }) {
                let g = Regex.groups(n.text ?? "", #"^(\s*)(.*)$"#, multiline: true)
                let lead = g[1], rest = g[2]
                if !lead.isEmpty {
                    leading += lead
                    node = rest.isEmpty ? nil : (n as! TextNode).withText(rest)
                    if node == nil { marks = active }
                }
            }
            if let n = node, n.isText, try marks.enumerated().contains(where: { i, mark in
                let info = try getMark(mark.type.name)
                return info.expelEnclosingWhitespace && !isMarkAhead(parent, index + 1, Array(marks[0...i]))
            }) {
                let g = Regex.groups(n.text ?? "", #"^(.*?)(\s*)$"#, multiline: true)
                let rest = g[1], trail = g[2]
                if !trail.isEmpty {
                    trailing = trail
                    node = rest.isEmpty ? nil : (n as! TextNode).withText(rest)
                    if node == nil { marks = active }
                }
            }

            // Close the marks that need closing.
            if node != nil || index == parent.childCount {
                while keep < active.count {
                    text(try markString(active.removeLast(), false, parent, index), false)
                }
            }

            // Whitespace expelled earlier goes outside the marks.
            if !leading.isEmpty { text(leading) }

            // Open the marks that need opening, then the node.
            if let n = node {
                while active.count < len {
                    let add = marks[active.count]
                    active.append(add)
                    text(try markString(add, true, parent, index), false)
                    atBlockStart = false
                }
                if noEsc, n.isText, let inner {
                    text(try markString(inner, true, parent, index) + (n.text ?? "") + markString(inner, false, parent, index + 1), false)
                } else {
                    try render(n, parent, index)
                }
                atBlockStart = false
                if n.isText && n.nodeSize > 0 { atBlockStart = false }
            }
        }
        for i in 0..<parent.childCount { try progress(parent.child(i), i) }
        try progress(nil, parent.childCount)
        atBlockStart = false
    }

    /// Render a list: `delim` indents the item's later lines, `firstDelim(i)` starts item i.
    public func renderList(_ node: Node, _ delim: String, _ firstDelim: (Int) -> String) throws {
        if let closed, closed.type === node.type { flushClose(3) } else if inTightList { flushClose(1) }
        let isTight = node.attrs["tight"]?.boolValue ?? options.tightLists
        let prevTight = inTightList
        inTightList = isTight
        for i in 0..<node.childCount {
            if i > 0 && isTight { flushClose(1) }
            try wrapBlock(delim, firstDelim(i), node) { try render(node.child(i), node, i) }
        }
        inTightList = prevTight
    }

    /// Escape `str` for Markdown; at the start of a line, also line-start syntax.
    public func esc(_ str: String, _ startOfLine: Bool = false) -> String {
        let units = Array(str.utf16)
        func isWord(_ u: UInt16) -> Bool { (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        let special: Set<UInt16> = Set("`*\\~[]_".utf16)
        for (i, u) in units.enumerated() {
            if special.contains(u) {
                let intraword = u == 95 && i > 0 && i + 1 < units.count && isWord(units[i - 1]) && isWord(units[i + 1])
                if !intraword { out.append(92) }
            }
            out.append(u)
        }
        var s = String(utf16CodeUnits: out, count: out.count)
        if startOfLine {
            s = Regex.replace(s, #"^(\+[ ]|[\-*>])"#, "\\\\$0", once: true)
            s = Regex.replace(s, #"^(\s*)(#{1,6})(\s|$)"#, "$1\\\\$2$3", once: true)
            s = Regex.replace(s, #"^(\s*[0-9]+)\.\s"#, "$1\\\\. ", once: true)
        }
        if let extra = options.escapeExtraCharacters {
            s = extra.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "\\\\$0")
        }
        return s
    }

    public func quote(_ str: String) -> String {
        let wrap = !str.contains("\"") ? "\"\"" : !str.contains("'") ? "''" : "()"
        return String(wrap.first!) + str + String(wrap.last!)
    }

    public func repeatString(_ str: String, _ n: Int) -> String { String(repeating: str, count: max(0, n)) }

    /// The Markdown for opening or closing `mark`.
    open func markString(_ mark: Mark, _ open: Bool, _ parent: Node, _ index: Int) throws -> String {
        let info = try getMark(mark.type.name)
        switch open ? info.open : info.close {
        case .text(let s): return s
        case .function(let f): return f(self, mark, parent, index)
        }
    }

    func isMarkAhead(_ parent: Node, _ start: Int, _ marks: [Mark]) -> Bool {
        var index = start
        while true {
            if index >= parent.childCount { return false }
            let next = parent.child(index)
            if next.type.name != options.hardBreakNodeName {
                return next.marks.count >= marks.count && Mark.sameSet(Array(next.marks[0..<marks.count]), marks)
            }
            index += 2  // As in JS: the loop's own index++ follows the body's.
        }
    }
}

/// JS `Array.prototype.slice`: out-of-range bounds clamp instead of trapping.
func slice<T>(_ array: [T], _ from: Int, _ to: Int) -> [T] {
    let lo = max(0, min(from, array.count)), hi = max(lo, min(to, array.count))
    return Array(array[lo..<hi])
}

/// JS-style regular expression helpers on UTF-16 strings.
enum Regex {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func make(_ pattern: String, multiline: Bool = false) -> NSRegularExpression {
        let key = (multiline ? "m:" : "") + pattern
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = try! NSRegularExpression(pattern: pattern, options: multiline ? [.anchorsMatchLines] : [])
        cache[key] = r
        return r
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        make(pattern).firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Capture groups of the first match (empty strings for groups that didn't take part).
    static func groups(_ s: String, _ pattern: String, multiline: Bool = false) -> [String] {
        let ns = s as NSString
        let r = make(pattern, multiline: multiline)
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return Array(repeating: "", count: r.numberOfCaptureGroups + 1)
        }
        return (0...r.numberOfCaptureGroups).map { i in
            let range = m.range(at: i)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    static func replace(_ s: String, _ pattern: String, _ template: String, once: Bool = false) -> String {
        let r = make(pattern)
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        if once {
            guard let m = r.firstMatch(in: s, range: full) else { return s }
            let replacement = r.replacementString(for: m, in: s, offset: 0, template: template)
            return ns.replacingCharacters(in: m.range, with: replacement)
        }
        return r.stringByReplacingMatches(in: s, range: full, withTemplate: template)
    }
}
