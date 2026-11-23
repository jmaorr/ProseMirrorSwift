// Ported from prosemirror-markdown 1.13.7 `defaultMarkdownSerializer` (MIT).

import Foundation
import PMModel

extension MarkdownSerializer {
    /// prosemirror-markdown's node serializers, by its basic schema's names. Others reuse them
    /// under their own names (tiptap: `paragraph`, `heading`, `blockquote`, ...).
    public enum Nodes {
        public static let blockquote: NodeSerializer = { state, node, _, _ in
            state.renderOrRecord { try state.wrapBlock("> ", nil, node) { try state.renderContent(node) } }
        }
        public static let codeBlock: NodeSerializer = { state, node, _, _ in
            // Fences longer than any backtick run inside.
            let runs = Regex.make("`{3,}", multiline: true)
            let text = node.textContent as NSString
            let found = runs.matches(in: node.textContent, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
            let fence = found.isEmpty ? "```" : (found.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }.last! + "`")
            state.write(fence + (node.attrs["params"]?.stringValue ?? "") + "\n")
            state.text(node.textContent, false)
            state.write("\n")
            state.write(fence)
            state.closeBlock(node)
        }
        public static let heading: NodeSerializer = { state, node, _, _ in
            // Markdown has six heading levels; attrs are untrusted, so clamp (JS repeats as-is).
            state.write(state.repeatString("#", min(max(node.attrs["level"]?.intValue ?? 1, 1), 6)) + " ")
            state.renderOrRecord { try state.renderInline(node, false) }
            state.closeBlock(node)
        }
        public static let horizontalRule: NodeSerializer = { state, node, _, _ in
            state.write(node.attrs["markup"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "---")
            state.closeBlock(node)
        }
        public static let bulletList: NodeSerializer = { state, node, _, _ in
            let bullet = node.attrs["bullet"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "*"
            state.renderOrRecord { try state.renderList(node, "  ") { _ in bullet + " " } }
        }
        public static let orderedList: NodeSerializer = { state, node, _, _ in
            // Clamped so `start + index` can't overflow (attrs are untrusted; JS uses doubles).
            let start = min(max(node.attrs["order"]?.intValue ?? 1, -maxListStart), maxListStart)
            let maxW = String(start + node.childCount - 1).count
            let space = state.repeatString(" ", maxW + 2)
            state.renderOrRecord {
                try state.renderList(node, space) { i in
                    let n = String(start + i)
                    return state.repeatString(" ", maxW - n.count) + n + ". "
                }
            }
        }
        public static let listItem: NodeSerializer = { state, node, _, _ in
            state.renderOrRecord { try state.renderContent(node) }
        }
        public static let paragraph: NodeSerializer = { state, node, _, _ in
            state.renderOrRecord { try state.renderInline(node) }
            state.closeBlock(node)
        }
        public static let image: NodeSerializer = { state, node, _, _ in
            let alt = singleLine(node.attrs["alt"]?.stringValue ?? "")
            let src = Regex.replace(encodeLineBreaks(node.attrs["src"]?.stringValue ?? ""), #"[\(\)]"#, "\\\\$0")
            let title = node.attrs["title"]?.stringValue.flatMap { $0.isEmpty ? nil : singleLine($0) }
            state.write("![" + state.esc(alt) + "](" + src +
                        (title.map { " \"" + Regex.replace($0, "\"", "\\\\\"") + "\"" } ?? "") + ")")
        }
        public static let hardBreak: NodeSerializer = { state, node, parent, index in
            for i in (index + 1)..<max(index + 1, parent.childCount) where parent.child(i).type !== node.type {
                state.write("\\\n")
                return
            }
        }
        public static let text: NodeSerializer = { state, node, _, _ in
            state.text(node.text ?? "", state.inAutolink != true)
        }
    }

    public enum Marks {
        public static let em = MarkSerializerSpec("*", "*", mixable: true, expelEnclosingWhitespace: true)
        public static let strong = MarkSerializerSpec("**", "**", mixable: true, expelEnclosingWhitespace: true)
        public static let link = MarkSerializerSpec(
            open: .function { state, mark, parent, index in
                state.inAutolink = isPlainURL(mark, parent, index)
                return state.inAutolink == true ? "<" : "["
            },
            close: .function { state, mark, _, _ in
                let inAutolink = state.inAutolink
                state.inAutolink = nil
                if inAutolink == true { return ">" }
                let href = Regex.replace(encodeLineBreaks(mark.attrs["href"]?.stringValue ?? ""), #"[\(\)"]"#, "\\\\$0")
                let title = mark.attrs["title"]?.stringValue.flatMap { $0.isEmpty ? nil : singleLine($0) }
                return "](" + href + (title.map { " \"" + Regex.replace($0, "\"", "\\\\\"") + "\"" } ?? "") + ")"
            },
            mixable: true)
        public static let code = MarkSerializerSpec(
            open: .function { _, _, parent, index in backticks(parent.child(index), -1) },
            close: .function { _, _, parent, index in backticks(parent.child(index - 1), 1) },
            escape: false)
    }

    /// prosemirror-markdown's `defaultMarkdownSerializer`, for its basic schema.
    public static let `default` = MarkdownSerializer(
        nodes: [
            "blockquote": Nodes.blockquote, "code_block": Nodes.codeBlock, "heading": Nodes.heading,
            "horizontal_rule": Nodes.horizontalRule, "bullet_list": Nodes.bulletList, "ordered_list": Nodes.orderedList,
            "list_item": Nodes.listItem, "paragraph": Nodes.paragraph, "image": Nodes.image,
            "hard_break": Nodes.hardBreak, "text": Nodes.text,
        ],
        marks: ["em": Marks.em, "strong": Marks.strong, "link": Marks.link, "code": Marks.code])

    /// The largest `order` an ordered list starts from (anything bigger is clamped).
    static let maxListStart = 1_000_000_000

    /// `url` with CR and LF percent-encoded. prosemirror-markdown writes URLs as they are, so a
    /// crafted `href` or `src` (from a collaborator or the pasteboard) with a line break could
    /// end the link and start new Markdown blocks; encoded, it stays one URL.
    static func encodeLineBreaks(_ url: String) -> String {
        guard url.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return url }
        return url.unicodeScalars.map { $0 == "\n" ? "%0A" : $0 == "\r" ? "%0D" : String($0) }.joined()
    }

    /// `text` with each line break (CR, LF or CRLF) replaced by a space: for alt text and
    /// titles, which can't hold a blank line without ending the link.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func backticks(_ node: Node, _ side: Int) -> String {
        var len = 0
        if node.isText, let text = node.text {
            let ns = text as NSString
            for m in Regex.make("`+").matches(in: text, range: NSRange(location: 0, length: ns.length)) { len = max(len, m.range.length) }
        }
        var result = len > 0 && side > 0 ? " `" : "`"
        result += String(repeating: "`", count: len)
        if len > 0 && side < 0 { result += " " }
        return result
    }

    static func isPlainURL(_ link: Mark, _ parent: Node, _ index: Int) -> Bool {
        let href = link.attrs["href"]?.stringValue ?? ""
        // An autolink can't hold a line break; such a link goes out as `[text](url)`, encoded.
        if href.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) { return false }
        if !(link.attrs["title"]?.stringValue ?? "").isEmpty || !Regex.matches(href, #"^[A-Za-z0-9_]+:"#) { return false }
        let content = parent.child(index)
        if !content.isText || content.text != href || !(content.marks.last.map { $0 === link || $0.eq(link) } ?? false) { return false }
        return index == parent.childCount - 1 || !link.isInSet(parent.child(index + 1).marks)
    }
}
