// Port of prosemirror-model/src/content.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

public struct MatchEdge {
    public let type: NodeType
    public let next: ContentMatch
}

/// Instances of this class represent a match state of a node type's content
/// expression, and can be used to find out whether further content matches
/// here, and whether a given position is a valid end of the node.
public final class ContentMatch: CustomStringConvertible {
    public let validEnd: Bool
    public internal(set) var next: [MatchEdge] = []
    private var wrapCache: [(NodeType, [NodeType]?)] = []

    init(validEnd: Bool) { self.validEnd = validEnd }

    public static let empty = ContentMatch(validEnd: true)

    static func parse(_ string: String, nodeTypes: [NodeType], byName: [String: NodeType]) throws -> ContentMatch {
        let stream = TokenStream(string: string, nodeTypes: nodeTypes, byName: byName)
        if stream.next == nil { return .empty }
        let expr = try parseExpr(stream)
        if stream.next != nil { try stream.err("Unexpected trailing text") }
        let match = dfa(nfa(expr))
        try checkForDeadEnds(match, stream)
        return match
    }

    public func matchType(_ type: NodeType) -> ContentMatch? {
        for edge in next where edge.type === type { return edge.next }
        return nil
    }

    public func matchFragment(_ frag: Fragment, start: Int = 0, end: Int? = nil) -> ContentMatch? {
        let end = end ?? frag.childCount
        var cur: ContentMatch? = self
        var i = start
        while let c = cur, i < end {
            cur = c.matchType(frag.child(i).type)
            i += 1
        }
        return cur
    }

    public var inlineContent: Bool { !next.isEmpty && next[0].type.isInline }

    public var defaultType: NodeType? {
        for edge in next where !(edge.type.isText || edge.type.hasRequiredAttrs()) { return edge.type }
        return nil
    }

    public func compatible(_ other: ContentMatch) -> Bool {
        for a in next { for b in other.next where a.type === b.type { return true } }
        return false
    }

    /// Try to match the given fragment, and if that fails, see if it can be
    /// made to match by inserting nodes in front of it.
    public func fillBefore(_ after: Fragment, toEnd: Bool = false, startIndex: Int = 0) -> Fragment? {
        var seen: [ContentMatch] = [self]
        func search(_ match: ContentMatch, _ types: [NodeType]) -> Fragment? {
            if let finished = match.matchFragment(after, start: startIndex), !toEnd || finished.validEnd {
                return Fragment.from(types.map { $0.createAndFill()! })
            }
            for edge in match.next {
                if !(edge.type.isText || edge.type.hasRequiredAttrs()) && !seen.contains(where: { $0 === edge.next }) {
                    seen.append(edge.next)
                    if let found = search(edge.next, types + [edge.type]) { return found }
                }
            }
            return nil
        }
        return search(self, [])
    }

    /// Find a set of wrapping node types that would allow a node of the given
    /// type to appear at this position.
    public func findWrapping(_ target: NodeType) -> [NodeType]? {
        for (type, result) in wrapCache where type === target { return result }
        let computed = computeWrapping(target)
        wrapCache.append((target, computed))
        return computed
    }

    private final class Active {
        let match: ContentMatch
        let type: NodeType?
        let via: Active?
        init(_ match: ContentMatch, _ type: NodeType?, _ via: Active?) { self.match = match; self.type = type; self.via = via }
    }

    private func computeWrapping(_ target: NodeType) -> [NodeType]? {
        var seen = Set<String>()
        var active: [Active] = [Active(self, nil, nil)]
        var head = 0
        while head < active.count {
            let current = active[head]
            head += 1
            let match = current.match
            if match.matchType(target) != nil {
                var result: [NodeType] = []
                var obj: Active? = current
                while let o = obj, let t = o.type {
                    result.append(t)
                    obj = o.via
                }
                return result.reversed()
            }
            for edge in match.next {
                let type = edge.type
                if !type.isLeaf && !type.hasRequiredAttrs() && !seen.contains(type.name) && (current.type == nil || edge.next.validEnd) {
                    active.append(Active(type.contentMatch, type, current))
                    seen.insert(type.name)
                }
            }
        }
        return nil
    }

    public var edgeCount: Int { next.count }

    public func edge(_ n: Int) -> MatchEdge {
        precondition(n < next.count, "There's no \(n)th edge in this content match")
        return next[n]
    }

    public var description: String {
        var seen: [ContentMatch] = []
        func scan(_ m: ContentMatch) {
            seen.append(m)
            for e in m.next where !seen.contains(where: { $0 === e.next }) { scan(e.next) }
        }
        scan(self)
        return seen.enumerated().map { i, m in
            var out = "\(i)\(m.validEnd ? "*" : " ") "
            for (j, e) in m.next.enumerated() {
                out += (j > 0 ? ", " : "") + e.type.name + "->" + String(seen.firstIndex { $0 === e.next }!)
            }
            return out
        }.joined(separator: "\n")
    }
}

// MARK: - Expression parser

private final class TokenStream {
    var inline: Bool?
    var pos = 0
    let tokens: [String]
    let string: String
    let nodeTypes: [NodeType]
    let byName: [String: NodeType]

    init(string: String, nodeTypes: [NodeType], byName: [String: NodeType]) {
        self.string = string
        self.nodeTypes = nodeTypes
        self.byName = byName
        tokens = TokenStream.tokenize(string)
    }

    /// Equivalent of `string.split(/\s*(?=\b|\W|$)/)` with empty first/last
    /// tokens dropped: runs of ASCII word characters, or single non-space
    /// non-word characters.
    static func tokenize(_ s: String) -> [String] {
        func isWord(_ c: Character) -> Bool {
            guard let a = c.asciiValue else { return false }
            return (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122) || a == 95
        }
        var tokens: [String] = []
        var cur = ""
        for c in s {
            if c.isWhitespace {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if isWord(c) {
                if let last = cur.last, !isWord(last) { tokens.append(cur); cur = "" }
                cur.append(c)
            } else {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(c))
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    var next: String? { pos < tokens.count ? tokens[pos] : nil }

    func eat(_ tok: String) -> Bool {
        if next == tok { pos += 1; return true }
        return false
    }

    func err(_ str: String) throws -> Never {
        throw PMError.syntax(str + " (in content expression '" + string + "')")
    }
}

private indirect enum Expr {
    case choice([Expr])
    case seq([Expr])
    case plus(Expr)
    case star(Expr)
    case opt(Expr)
    case range(min: Int, max: Int, Expr)
    case name(NodeType)
}

private func parseExpr(_ stream: TokenStream) throws -> Expr {
    var exprs: [Expr] = []
    repeat { exprs.append(try parseExprSeq(stream)) } while stream.eat("|")
    return exprs.count == 1 ? exprs[0] : .choice(exprs)
}

private func parseExprSeq(_ stream: TokenStream) throws -> Expr {
    var exprs: [Expr] = []
    repeat { exprs.append(try parseExprSubscript(stream)) } while stream.next != nil && stream.next != ")" && stream.next != "|"
    return exprs.count == 1 ? exprs[0] : .seq(exprs)
}

private func parseExprSubscript(_ stream: TokenStream) throws -> Expr {
    var expr = try parseExprAtom(stream)
    while true {
        if stream.eat("+") { expr = .plus(expr) }
        else if stream.eat("*") { expr = .star(expr) }
        else if stream.eat("?") { expr = .opt(expr) }
        else if stream.eat("{") { expr = try parseExprRange(stream, expr) }
        else { break }
    }
    return expr
}

private func parseNum(_ stream: TokenStream) throws -> Int {
    guard let next = stream.next, !next.isEmpty, next.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(next) else {
        try stream.err("Expected number, got '\(stream.next ?? "undefined")'")
    }
    stream.pos += 1
    return n
}

private func parseExprRange(_ stream: TokenStream, _ expr: Expr) throws -> Expr {
    let min = try parseNum(stream)
    var max = min
    if stream.eat(",") {
        if stream.next != "}" { max = try parseNum(stream) } else { max = -1 }
    }
    if !stream.eat("}") { try stream.err("Unclosed braced range") }
    return .range(min: min, max: max, expr)
}

private func resolveName(_ stream: TokenStream, _ name: String) throws -> [NodeType] {
    if let type = stream.byName[name] { return [type] }
    let result = stream.nodeTypes.filter { $0.isInGroup(name) }
    if result.isEmpty { try stream.err("No node type or group '\(name)' found") }
    return result
}

private func parseExprAtom(_ stream: TokenStream) throws -> Expr {
    if stream.eat("(") {
        let expr = try parseExpr(stream)
        if !stream.eat(")") { try stream.err("Missing closing paren") }
        return expr
    }
    guard let next = stream.next else { try stream.err("Unexpected token 'undefined'") }
    // JS: !/\W/.test(next) — a word token (tokens are either all-word or a single non-word char)
    if let c = next.first, c.isASCII, c.isLetter || c.isNumber || c == "_" {
        let exprs = try resolveName(stream, next).map { type -> Expr in
            if stream.inline == nil { stream.inline = type.isInline }
            else if stream.inline != type.isInline { try stream.err("Mixing inline and block content") }
            return .name(type)
        }
        stream.pos += 1
        return exprs.count == 1 ? exprs[0] : .choice(exprs)
    }
    try stream.err("Unexpected token '\(next)'")
}

// MARK: - NFA / DFA

private final class NFAEdge {
    let term: NodeType?
    var to: Int?
    init(term: NodeType?, to: Int?) { self.term = term; self.to = to }
}

private func nfa(_ expr: Expr) -> [[NFAEdge]] {
    var nfa: [[NFAEdge]] = [[]]

    func node() -> Int { nfa.append([]); return nfa.count - 1 }
    @discardableResult
    func edge(_ from: Int, _ to: Int? = nil, _ term: NodeType? = nil) -> NFAEdge {
        let e = NFAEdge(term: term, to: to)
        nfa[from].append(e)
        return e
    }
    func connect(_ edges: [NFAEdge], _ to: Int) { for e in edges { e.to = to } }

    func compile(_ expr: Expr, _ from: Int) -> [NFAEdge] {
        switch expr {
        case .choice(let exprs):
            return exprs.reduce([NFAEdge]()) { $0 + compile($1, from) }
        case .seq(let exprs):
            var from = from
            var i = 0
            while true {
                let next = compile(exprs[i], from)
                if i == exprs.count - 1 { return next }
                from = node()
                connect(next, from)
                i += 1
            }
        case .star(let inner):
            let loop = node()
            edge(from, loop)
            connect(compile(inner, loop), loop)
            return [edge(loop)]
        case .plus(let inner):
            let loop = node()
            connect(compile(inner, from), loop)
            connect(compile(inner, loop), loop)
            return [edge(loop)]
        case .opt(let inner):
            return [edge(from)] + compile(inner, from)
        case .range(let min, let max, let inner):
            var cur = from
            for _ in 0..<min {
                let next = node()
                connect(compile(inner, cur), next)
                cur = next
            }
            if max == -1 {
                connect(compile(inner, cur), cur)
            } else {
                var i = min
                while i < max {
                    let next = node()
                    edge(cur, next)
                    connect(compile(inner, cur), next)
                    cur = next
                    i += 1
                }
            }
            return [edge(cur)]
        case .name(let type):
            return [edge(from, nil, type)]
        }
    }

    connect(compile(expr, 0), node())
    return nfa
}

private func nullFrom(_ nfa: [[NFAEdge]], _ node: Int) -> [Int] {
    var result: [Int] = []
    func scan(_ node: Int) {
        let edges = nfa[node]
        if edges.count == 1 && edges[0].term == nil { return scan(edges[0].to!) }
        result.append(node)
        for e in edges where e.term == nil && !result.contains(e.to!) { scan(e.to!) }
    }
    scan(node)
    return result.sorted(by: >)
}

private func dfa(_ nfa: [[NFAEdge]]) -> ContentMatch {
    var labeled: [String: ContentMatch] = [:]

    func explore(_ states: [Int]) -> ContentMatch {
        var out: [(NodeType, [Int])] = []
        for node in states {
            for e in nfa[node] {
                guard let term = e.term else { continue }
                var setIndex: Int? = nil
                for i in 0..<out.count where out[i].0 === term { setIndex = i }
                for n in nullFrom(nfa, e.to!) {
                    if setIndex == nil { out.append((term, [])); setIndex = out.count - 1 }
                    if !out[setIndex!].1.contains(n) { out[setIndex!].1.append(n) }
                }
            }
        }
        let state = ContentMatch(validEnd: states.contains(nfa.count - 1))
        labeled[states.map(String.init).joined(separator: ",")] = state
        for (type, set) in out {
            let sorted = set.sorted(by: >)
            let next = labeled[sorted.map(String.init).joined(separator: ",")] ?? explore(sorted)
            state.next.append(MatchEdge(type: type, next: next))
        }
        return state
    }

    return explore(nullFrom(nfa, 0))
}

private func checkForDeadEnds(_ match: ContentMatch, _ stream: TokenStream) throws {
    var work = [match]
    var i = 0
    while i < work.count {
        let state = work[i]
        var dead = !state.validEnd
        var nodes: [String] = []
        for e in state.next {
            nodes.append(e.type.name)
            if dead && !(e.type.isText || e.type.hasRequiredAttrs()) { dead = false }
            if !work.contains(where: { $0 === e.next }) { work.append(e.next) }
        }
        if dead {
            try stream.err("Only non-generatable nodes (\(nodes.joined(separator: ", "))) in a required position (see https://prosemirror.net/docs/guide/#generatable)")
        }
        i += 1
    }
}
