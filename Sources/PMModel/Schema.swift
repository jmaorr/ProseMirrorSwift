// Port of prosemirror-model/src/schema.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

// MARK: - Specs

public struct AttributeSpec {
    /// `nil` means "no default" (attribute is required). Use `.null` for a null default.
    public var `default`: JSONValue?
    /// Type validation like the JS string form: "number", "string|null", ...
    public var validateType: String?
    /// Custom validation function.
    public var validate: ((JSONValue?) throws -> Void)?

    public init(default: JSONValue? = nil, validateType: String? = nil, validate: ((JSONValue?) throws -> Void)? = nil) {
        self.default = `default`
        self.validateType = validateType
        self.validate = validate
    }
}

public struct NodeSpec {
    public var content: String?
    public var marks: String?
    public var group: String?
    public var inline: Bool = false
    public var atom: Bool = false
    public var attrs: [(String, AttributeSpec)] = []
    public var selectable: Bool?
    public var draggable: Bool = false
    public var code: Bool = false
    public var whitespace: String?
    public var definingAsContext: Bool?
    public var definingForContent: Bool?
    public var defining: Bool = false
    public var isolating: Bool = false
    public var linebreakReplacement: Bool = false
    public var leafText: ((Node) -> String)?
    public var toDebugString: ((Node) -> String)?
    /// Every property from the JSON spec, including custom ones.
    public var extra: JSONObject = JSONObject()

    public init(content: String? = nil, marks: String? = nil, group: String? = nil, inline: Bool = false,
                atom: Bool = false, attrs: [(String, AttributeSpec)] = [], selectable: Bool? = nil,
                draggable: Bool = false, code: Bool = false, whitespace: String? = nil, defining: Bool = false,
                isolating: Bool = false) {
        self.content = content; self.marks = marks; self.group = group; self.inline = inline; self.atom = atom
        self.attrs = attrs; self.selectable = selectable; self.draggable = draggable; self.code = code
        self.whitespace = whitespace; self.defining = defining; self.isolating = isolating
    }
}

public struct MarkSpec {
    public var attrs: [(String, AttributeSpec)] = []
    /// `nil` means unspecified (which behaves as inclusive).
    public var inclusive: Bool?
    public var excludes: String?
    public var group: String?
    public var spanning: Bool?
    public var code: Bool = false
    public var extra: JSONObject = JSONObject()

    public init(attrs: [(String, AttributeSpec)] = [], inclusive: Bool? = nil, excludes: String? = nil,
                group: String? = nil, spanning: Bool? = nil, code: Bool = false) {
        self.attrs = attrs; self.inclusive = inclusive; self.excludes = excludes; self.group = group
        self.spanning = spanning; self.code = code
    }
}

public struct SchemaSpec {
    public var nodes: [(String, NodeSpec)]
    public var marks: [(String, MarkSpec)]
    public var topNode: String?

    public init(nodes: [(String, NodeSpec)], marks: [(String, MarkSpec)] = [], topNode: String? = nil) {
        self.nodes = nodes; self.marks = marks; self.topNode = topNode
    }
}

// MARK: - JSON spec form

extension AttributeSpec {
    init(json: JSONValue) {
        let o = json.objectValue ?? JSONObject()
        self.default = o["default"]
        self.validateType = o["validate"]?.stringValue
    }
}

private func attrSpecs(_ json: JSONValue?) -> [(String, AttributeSpec)] {
    guard let o = json?.objectValue else { return [] }
    return o.map { ($0.key, AttributeSpec(json: $0.value)) }
}

extension NodeSpec {
    public init(json: JSONValue) {
        let o = json.objectValue ?? JSONObject()
        content = o["content"]?.stringValue
        marks = o["marks"]?.stringValue
        group = o["group"]?.stringValue
        inline = o["inline"]?.truthy ?? false
        atom = o["atom"]?.truthy ?? false
        attrs = attrSpecs(o["attrs"])
        selectable = o["selectable"].map(\.truthy)
        draggable = o["draggable"]?.truthy ?? false
        code = o["code"]?.truthy ?? false
        whitespace = o["whitespace"]?.stringValue
        definingAsContext = o["definingAsContext"].map(\.truthy)
        definingForContent = o["definingForContent"].map(\.truthy)
        defining = o["defining"]?.truthy ?? false
        isolating = o["isolating"]?.truthy ?? false
        linebreakReplacement = o["linebreakReplacement"]?.truthy ?? false
        extra = o
    }
}

extension MarkSpec {
    public init(json: JSONValue) {
        let o = json.objectValue ?? JSONObject()
        attrs = attrSpecs(o["attrs"])
        inclusive = o["inclusive"].map(\.truthy)
        excludes = o["excludes"]?.stringValue
        group = o["group"]?.stringValue
        spanning = o["spanning"].map(\.truthy)
        code = o["code"]?.truthy ?? false
        extra = o
    }
}

extension SchemaSpec {
    /// `{nodes: [[name, spec]...], marks: [[name, spec]...], topNode?}` (see oracle/src/specjson.js).
    public init(json: JSONValue) throws {
        func pairs(_ v: JSONValue?) throws -> [(String, JSONValue)] {
            guard let v else { return [] }
            if let arr = v.arrayValue {
                return try arr.map {
                    guard let name = $0[0]?.stringValue, let spec = $0[1] else { throw PMError.range("Bad schema spec entry") }
                    return (name, spec)
                }
            }
            if let o = v.objectValue { return o.map { ($0.key, $0.value) } }
            throw PMError.range("Bad schema spec")
        }
        nodes = try pairs(json["nodes"]).map { ($0.0, NodeSpec(json: $0.1)) }
        marks = try pairs(json["marks"]).map { ($0.0, MarkSpec(json: $0.1)) }
        topNode = json["topNode"]?.stringValue
    }
}

// MARK: - Attributes

final class Attribute {
    let hasDefault: Bool
    let defaultValue: JSONValue
    let validate: ((JSONValue?) throws -> Void)?

    init(typeName: String, attrName: String, spec: AttributeSpec) {
        hasDefault = spec.default != nil
        defaultValue = spec.default ?? .null
        if let custom = spec.validate {
            validate = custom
        } else if let t = spec.validateType {
            let types = t.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            validate = { value in
                let name: String
                switch value {
                case nil: name = "undefined"
                case .null?: name = "null"
                case let v?: name = v.jsTypeName
                }
                if !types.contains(name) {
                    throw PMError.range("Expected value of type \(types.joined(separator: ",")) for attribute \(attrName) on type \(typeName), got \(name)")
                }
            }
        } else {
            validate = nil
        }
    }

    var isRequired: Bool { !hasDefault }
}

private func initAttrs(_ typeName: String, _ specs: [(String, AttributeSpec)]) -> [(String, Attribute)] {
    var result: [(String, Attribute)] = []
    for (name, spec) in specs {
        let attr = Attribute(typeName: typeName, attrName: name, spec: spec)
        if let i = result.firstIndex(where: { $0.0 == name }) { result[i] = (name, attr) } else { result.append((name, attr)) }
    }
    return result
}

private func defaultAttrs(_ attrs: [(String, Attribute)]) -> Attrs? {
    var defaults = Attrs()
    for (name, attr) in attrs {
        if !attr.hasDefault { return nil }
        defaults[name] = attr.defaultValue
    }
    return defaults
}

private func computeAttrs(_ attrs: [(String, Attribute)], _ value: Attrs?) throws -> Attrs {
    var built = Attrs()
    for (name, attr) in attrs {
        // JS quirk: `given = value && value[name]` is null (not undefined)
        // when no attrs object was passed, so required attrs become null.
        guard let value else {
            built[name] = attr.hasDefault ? attr.defaultValue : .null
            continue
        }
        if let given = value[name] {
            built[name] = given
        } else if attr.hasDefault {
            built[name] = attr.defaultValue
        } else {
            throw PMError.range("No value supplied for attribute \(name)")
        }
    }
    return built
}

private func checkAttrs(_ attrs: [(String, Attribute)], _ values: Attrs, _ type: String, _ name: String) throws {
    for key in values.keys where !attrs.contains(where: { $0.0 == key }) {
        throw PMError.range("Unsupported attribute \(key) for \(type) of type \(name)")
    }
    for (attrName, attr) in attrs {
        if let validate = attr.validate { try validate(values[attrName]) }
    }
}

// MARK: - NodeType

public final class NodeType: Hashable, CustomStringConvertible {
    public let name: String
    public let schema: Schema
    public let spec: NodeSpec
    public let groups: [String]
    let attrs: [(String, Attribute)]
    public let defaultAttrs: Attrs?
    public let isBlock: Bool
    public let isText: Bool
    public internal(set) var inlineContent: Bool = false
    public internal(set) var contentMatch: ContentMatch = ContentMatch.empty
    /// `nil` means all marks are allowed.
    public internal(set) var markSet: [MarkType]?

    init(name: String, schema: Schema, spec: NodeSpec) {
        self.name = name
        self.schema = schema
        self.spec = spec
        groups = spec.group.map { $0.split(separator: " ", omittingEmptySubsequences: false).map(String.init) } ?? []
        attrs = initAttrs(name, spec.attrs)
        defaultAttrs = PMModel.defaultAttrs(attrs)
        isBlock = !(spec.inline || name == "text")
        isText = name == "text"
    }

    public var attributeNames: [String] { attrs.map(\.0) }
    public var isInline: Bool { !isBlock }
    public var isTextblock: Bool { isBlock && inlineContent }
    public var isLeaf: Bool { contentMatch === ContentMatch.empty }
    public var isAtom: Bool { isLeaf || spec.atom }
    public func isInGroup(_ group: String) -> Bool { groups.contains(group) }
    public var whitespace: String { spec.whitespace ?? (spec.code ? "pre" : "normal") }

    public func hasRequiredAttrs() -> Bool { attrs.contains { $0.1.isRequired } }

    public func compatibleContent(_ other: NodeType) -> Bool {
        self === other || contentMatch.compatible(other.contentMatch)
    }

    public func computeAttrs(_ attrs: Attrs?) throws -> Attrs {
        if attrs == nil, let d = defaultAttrs { return d }
        return try PMModel.computeAttrs(self.attrs, attrs)
    }

    public func create(_ attrs: Attrs? = nil, _ content: Fragment? = nil, _ marks: [Mark]? = nil) throws -> Node {
        if isText { throw PMError.generic("NodeType.create can't construct text nodes") }
        return Node(type: self, attrs: try computeAttrs(attrs), content: content ?? .empty, marks: Mark.setFrom(marks))
    }

    public func create(_ attrs: Attrs? = nil, _ content: [Node], _ marks: [Mark]? = nil) throws -> Node {
        try create(attrs, Fragment.from(content), marks)
    }

    public func create(_ attrs: Attrs? = nil, _ content: Node, _ marks: [Mark]? = nil) throws -> Node {
        try create(attrs, Fragment.from(content), marks)
    }

    public func createChecked(_ attrs: Attrs? = nil, _ content: Fragment? = nil, _ marks: [Mark]? = nil) throws -> Node {
        let content = content ?? .empty
        try checkContent(content)
        return Node(type: self, attrs: try computeAttrs(attrs), content: content, marks: Mark.setFrom(marks))
    }

    public func createAndFill(_ attrs: Attrs? = nil, _ content: Fragment? = nil, _ marks: [Mark]? = nil) -> Node? {
        guard let attrs = try? computeAttrs(attrs) else { return nil }
        var content = content ?? .empty
        if content.size > 0 {
            guard let before = contentMatch.fillBefore(content) else { return nil }
            content = before.append(content)
        }
        guard let matched = contentMatch.matchFragment(content),
              let after = matched.fillBefore(.empty, toEnd: true) else { return nil }
        return Node(type: self, attrs: attrs, content: content.append(after), marks: Mark.setFrom(marks))
    }

    public func validContent(_ content: Fragment) -> Bool {
        guard let result = contentMatch.matchFragment(content), result.validEnd else { return false }
        for i in 0..<content.childCount where !allowsMarks(content.child(i).marks) { return false }
        return true
    }

    public func checkContent(_ content: Fragment) throws {
        if !validContent(content) {
            throw PMError.range("Invalid content for node \(name): \(String(content.description.prefix(50)))")
        }
    }

    public func checkAttrs(_ attrs: Attrs) throws {
        try PMModel.checkAttrs(self.attrs, attrs, "node", name)
    }

    public func allowsMarkType(_ markType: MarkType) -> Bool {
        markSet == nil || markSet!.contains { $0 === markType }
    }

    public func allowsMarks(_ marks: [Mark]) -> Bool {
        if markSet == nil { return true }
        return marks.allSatisfy { allowsMarkType($0.type) }
    }

    public func allowedMarks(_ marks: [Mark]) -> [Mark] {
        if markSet == nil { return marks }
        var copy: [Mark]? = nil
        for i in 0..<marks.count {
            if !allowsMarkType(marks[i].type) {
                if copy == nil { copy = Array(marks[0..<i]) }
            } else if copy != nil {
                copy!.append(marks[i])
            }
        }
        guard let copy else { return marks }
        return copy.isEmpty ? Mark.none : copy
    }

    public static func == (a: NodeType, b: NodeType) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    public var description: String { name }
}

// MARK: - MarkType

public final class MarkType: Hashable, CustomStringConvertible {
    public let name: String
    public let rank: Int
    public let schema: Schema
    public let spec: MarkSpec
    let attrs: [(String, Attribute)]
    public internal(set) var excluded: [MarkType] = []
    var instance: Mark?

    init(name: String, rank: Int, schema: Schema, spec: MarkSpec) {
        self.name = name
        self.rank = rank
        self.schema = schema
        self.spec = spec
        attrs = initAttrs(name, spec.attrs)
        if let defaults = defaultAttrs(attrs) { instance = Mark(type: self, attrs: defaults) }
    }

    public var attributeNames: [String] { attrs.map(\.0) }

    public func create(_ attrs: Attrs? = nil) throws -> Mark {
        if attrs == nil, let instance { return instance }
        return Mark(type: self, attrs: try computeAttrs(self.attrs, attrs))
    }

    public func removeFromSet(_ set: [Mark]) -> [Mark] {
        set.filter { $0.type !== self }
    }

    public func isInSet(_ set: [Mark]) -> Mark? {
        set.first { $0.type === self }
    }

    public func checkAttrs(_ attrs: Attrs) throws {
        try PMModel.checkAttrs(self.attrs, attrs, "mark", name)
    }

    public func excludes(_ other: MarkType) -> Bool {
        excluded.contains { $0 === other }
    }

    public static func == (a: MarkType, b: MarkType) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    public var description: String { name }
}

// MARK: - Schema

/// A document schema. Holds node and mark type objects for the nodes and
/// marks that may occur in conforming documents.
///
/// Note: node and mark types hold a strong reference back to their schema, so
/// a schema lives as long as any node or type created from it (schemas are
/// expected to be long-lived).
public final class Schema {
    public let spec: SchemaSpec
    public private(set) var nodes: [String: NodeType] = [:]
    public private(set) var marks: [String: MarkType] = [:]
    /// Node and mark types in spec order.
    public private(set) var nodeTypes: [NodeType] = []
    public private(set) var markTypes: [MarkType] = []
    public private(set) var linebreakReplacement: NodeType?
    public private(set) var topNodeType: NodeType!
    /// Cache for use by other modules (e.g. transform's wrapping cache).
    public var cached: [String: Any] = [:]

    public convenience init(json: JSONValue) throws {
        try self.init(try SchemaSpec(json: json))
    }

    public init(_ spec: SchemaSpec) throws {
        self.spec = spec
        for (name, nodeSpec) in spec.nodes {
            let type = NodeType(name: name, schema: self, spec: nodeSpec)
            if let i = nodeTypes.firstIndex(where: { $0.name == name }) { nodeTypes[i] = type } else { nodeTypes.append(type) }
            nodes[name] = type
        }
        let topType = spec.topNode ?? "doc"
        guard nodes[topType] != nil else { throw PMError.range("Schema is missing its top node type ('\(topType)')") }
        guard let text = nodes["text"] else { throw PMError.range("Every schema needs a 'text' type") }
        if !text.attrs.isEmpty { throw PMError.range("The text node type should not have attributes") }

        var rank = 0
        for (name, markSpec) in spec.marks {
            if let i = markTypes.firstIndex(where: { $0.name == name }) {
                let type = MarkType(name: name, rank: markTypes[i].rank, schema: self, spec: markSpec)
                markTypes[i] = type
                marks[name] = type
            } else {
                let type = MarkType(name: name, rank: rank, schema: self, spec: markSpec)
                rank += 1
                markTypes.append(type)
                marks[name] = type
            }
        }

        var contentExprCache: [String: ContentMatch] = [:]
        for type in nodeTypes {
            if marks[type.name] != nil { throw PMError.range("\(type.name) can not be both a node and a mark") }
            let contentExpr = type.spec.content ?? ""
            let markExpr = type.spec.marks
            if let cached = contentExprCache[contentExpr] {
                type.contentMatch = cached
            } else {
                let match = try ContentMatch.parse(contentExpr, nodeTypes: nodeTypes, byName: nodes)
                contentExprCache[contentExpr] = match
                type.contentMatch = match
            }
            type.inlineContent = type.contentMatch.inlineContent
            if type.spec.linebreakReplacement {
                if linebreakReplacement != nil { throw PMError.range("Multiple linebreak nodes defined") }
                if !type.isInline || !type.isLeaf { throw PMError.range("Linebreak replacement nodes must be inline leaf nodes") }
                linebreakReplacement = type
            }
            if markExpr == "_" {
                type.markSet = nil
            } else if let markExpr, !markExpr.isEmpty {
                type.markSet = try gatherMarks(markExpr.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
            } else if markExpr == "" || !type.inlineContent {
                type.markSet = []
            } else {
                type.markSet = nil
            }
        }
        for type in markTypes {
            let excl = type.spec.excludes
            if excl == nil {
                type.excluded = [type]
            } else if excl == "" {
                type.excluded = []
            } else {
                type.excluded = try gatherMarks(excl!.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
            }
        }
        topNodeType = nodes[topType]
    }

    private func gatherMarks(_ names: [String]) throws -> [MarkType] {
        var found: [MarkType] = []
        for name in names {
            if let mark = marks[name] {
                found.append(mark)
            } else {
                var ok = false
                for mark in markTypes {
                    if name == "_" || (mark.spec.group.map { $0.split(separator: " ").map(String.init).contains(name) } ?? false) {
                        found.append(mark)
                        ok = true
                    }
                }
                if !ok { throw PMError.syntax("Unknown mark type: '\(name)'") }
            }
        }
        return found
    }

    /// Create a node in this schema (checked).
    public func node(_ type: String, _ attrs: Attrs? = nil, _ content: [Node] = [], _ marks: [Mark]? = nil) throws -> Node {
        try nodeType(type).createChecked(attrs, Fragment.from(content), marks)
    }

    public func node(_ type: NodeType, _ attrs: Attrs? = nil, _ content: Fragment? = nil, _ marks: [Mark]? = nil) throws -> Node {
        if type.schema !== self { throw PMError.range("Node type from different schema used (\(type.name))") }
        return try type.createChecked(attrs, content, marks)
    }

    /// Create a text node. Text must be non-empty.
    public func text(_ text: String, _ marks: [Mark]? = nil) -> TextNode {
        let type = nodes["text"]!
        return TextNode(type: type, attrs: type.defaultAttrs ?? Attrs(), units: Array(text.utf16), marks: Mark.setFrom(marks))
    }

    public func text(units: [UInt16], _ marks: [Mark]? = nil) -> TextNode {
        let type = nodes["text"]!
        return TextNode(type: type, attrs: type.defaultAttrs ?? Attrs(), units: units, marks: Mark.setFrom(marks))
    }

    public func mark(_ name: String, _ attrs: Attrs? = nil) throws -> Mark {
        guard let type = marks[name] else { throw PMError.range("Unknown mark type: \(name)") }
        return try type.create(attrs)
    }

    public func nodeType(_ name: String) throws -> NodeType {
        guard let found = nodes[name] else { throw PMError.range("Unknown node type: \(name)") }
        return found
    }

    public func nodeFromJSON(_ json: JSONValue) throws -> Node { try Node.fromJSON(self, json) }
    public func markFromJSON(_ json: JSONValue) throws -> Mark { try Mark.fromJSON(self, json) }
}
