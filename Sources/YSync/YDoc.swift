import Foundation
import CYrs
import PMModel

/// A Yjs document, backed by yrs through its C API. Not thread-safe: use it from
/// one thread (the main thread, in the editor).
///
/// Text offsets are UTF-16 code units, as in Yjs and ProseMirror.
public final class YDocument {
    let raw: UnsafeMutablePointer<CYrs.YDoc>
    private var updateObservers: [Int: (Data, String?) -> Void] = [:]
    private var nextObserver = 0
    private var observingUpdates = false
    /// Origin of the transaction currently being committed, for update observers.
    private var committingOrigin: String?

    public init(clientID: UInt64? = nil) {
        var options = yoptions()
        if let clientID { options.id = clientID }
        options.flags |= UInt8(Y_OFFSET_UTF16)
        raw = ydoc_new_with_options(options)
    }

    deinit { ydoc_destroy(raw) }

    public var clientID: UInt64 { ydoc_id(raw) }

    /// The root XML fragment with this name (y-prosemirror binds one of these).
    public func xmlFragment(_ name: String) -> YBranch {
        YBranch(raw: name.withCString { yxmlfragment(raw, $0) })
    }

    /// The root map with this name (an app can keep document metadata in one).
    public func map(_ name: String) -> YBranch {
        YBranch(raw: name.withCString { ymap(raw, $0) })
    }

    /// Run `body` in a read-write transaction, committed when it returns. `origin`
    /// tags the transaction for undo tracking and for update observers.
    @discardableResult
    public func transact<T>(origin: String? = nil, _ body: (YTransaction) throws -> T) rethrows -> T {
        let txn: OpaquePointer? = if let origin {
            origin.withCString { ydoc_write_transaction(raw, UInt32(strlen($0)), $0) }
        } else {
            ydoc_write_transaction(raw, 0, nil)
        }
        guard let txn else { preconditionFailure("YDocument: a transaction is already open") }
        let t = YTransaction(raw: txn)
        defer {
            committingOrigin = origin
            ytransaction_commit(txn)
            committingOrigin = nil
            t.raw = nil
        }
        return try body(t)
    }

    /// Read-only access, for code that only inspects the document.
    public func read<T>(_ body: (YTransaction) throws -> T) rethrows -> T {
        guard let txn = ydoc_read_transaction(raw) else { preconditionFailure("YDocument: a write transaction is open") }
        let t = YTransaction(raw: txn)
        defer { ytransaction_commit(txn); t.raw = nil }
        return try body(t)
    }

    // MARK: Updates (lib0 v1 encoding, as on the wire)

    public func encodeStateVector() -> Data {
        read { txn in
            var len: UInt32 = 0
            // yffi never returns null here; an empty vector (as for an empty document) if it did.
            guard let bytes = ytransaction_state_vector_v1(txn.ptr, &len) else { return Data([0]) }
            defer { ybinary_destroy(bytes, len) }
            return Data(bytes: bytes, count: Int(len))
        }
    }

    /// Everything the holder of `stateVector` is missing (the whole document when nil or
    /// empty). Empty data if `stateVector` can't be decoded; `encodeDiff` tells that apart.
    public func encodeStateAsUpdate(_ stateVector: Data? = nil) -> Data {
        encodeDiff(stateVector ?? Data()) ?? Data()
    }

    /// Everything the holder of `stateVector` is missing (the whole document when it's
    /// empty), or nil when yrs can't decode `stateVector` (a malformed or hostile message).
    public func encodeDiff(_ stateVector: Data) -> Data? {
        guard stateVector.count <= Int(UInt32.max) else { return nil }
        return read { txn -> Data? in
            var len: UInt32 = 0
            let bytes: UnsafeMutablePointer<CChar>? = stateVector.withUnsafeBytes { sv in
                guard let base = sv.baseAddress, sv.count > 0 else {
                    return ytransaction_state_diff_v1(txn.ptr, nil, 0, &len)
                }
                return ytransaction_state_diff_v1(txn.ptr, base.assumingMemoryBound(to: CChar.self), UInt32(sv.count), &len)
            }
            guard let bytes else { return nil }
            defer { ybinary_destroy(bytes, len) }
            return Data(bytes: bytes, count: Int(len))
        }
    }

    /// Apply a remote update. Returns false if yrs rejected it, or it's empty (no valid
    /// update is) or too large to pass to yrs.
    @discardableResult
    public func applyUpdate(_ update: Data, origin: String? = nil) -> Bool {
        guard !update.isEmpty, update.count <= Int(UInt32.max) else { return false }
        return transact(origin: origin) { txn in
            update.withUnsafeBytes { u in
                guard let base = u.baseAddress else { return false }
                return ytransaction_apply(txn.ptr, base.assumingMemoryBound(to: CChar.self), UInt32(u.count)) == 0
            }
        }
    }

    /// Called with the encoded update and the transaction's origin after every
    /// transaction that changed the document.
    @discardableResult
    public func onUpdate(_ handler: @escaping (Data, String?) -> Void) -> Int {
        if !observingUpdates {
            observingUpdates = true
            let state = Unmanaged.passUnretained(self).toOpaque()
            transact { txn in
                "ysync".withCString { key in
                    ytransaction_observe_updates_v1(txn.ptr, 5, key, state) { state, len, bytes in
                        guard let state, let bytes else { return }
                        let doc = Unmanaged<YDocument>.fromOpaque(state).takeUnretainedValue()
                        let data = Data(bytes: bytes, count: Int(len))
                        for handler in doc.updateObservers.sorted(by: { $0.key < $1.key }).map(\.value) {
                            handler(data, doc.committingOrigin)
                        }
                    }
                }
            }
        }
        nextObserver += 1
        updateObservers[nextObserver] = handler
        return nextObserver
    }

    public func removeUpdateObserver(_ id: Int) { updateObservers[id] = nil }
}

/// An open transaction. Only valid inside the `transact`/`read` closure.
public final class YTransaction {
    fileprivate(set) var raw: OpaquePointer?
    init(raw: OpaquePointer) { self.raw = raw }
    var ptr: OpaquePointer {
        guard let raw else { preconditionFailure("YTransaction used after commit") }
        return raw
    }
}

/// Stable identity of a shared type: (client, clock) of the item that created it,
/// or the root name. Unlike a branch pointer it is never reused.
public struct YID: Hashable {
    /// The creator's client ID (nil for a root type). Unsigned: client IDs are u64 in yrs.
    let client: UInt64?
    let clock: UInt32
    let root: String?
}

/// Kinds of shared type the binding deals with.
public enum YKind {
    case element, text, fragment, other
}

/// A pointer to a shared type (yrs `Branch`). Valid while the type is alive.
public struct YBranch {
    let raw: UnsafeMutablePointer<Branch>

    public var kind: YKind {
        switch Int32(ytype_kind(raw)) {
        case Y_XML_ELEM: return .element
        case Y_XML_TEXT: return .text
        case Y_XML_FRAG: return .fragment
        default: return .other
        }
    }

    /// Longest root name read back from `ybranch_id` (roots are named by this app, e.g. "content").
    static let maxRootNameLength = 1 << 16

    public var id: YID {
        let b = ybranch_id(raw)
        // libyrs.h: client_or_len >= 0 is a nested type's creator client ID, < 0 a negated
        // root-name length. The sign is unambiguous: yffi 0.28 (yrs without `small-client`)
        // stores client IDs as 53-bit values (`ClientID::get` masks off the top 11 bits, even
        // for IDs decoded from a remote update), so a nested ID is never negative. yffi gives
        // no other way to tell roots apart, so only trust the root branch when the length is
        // sane and the name pointer is set; anything else is treated as a nested ID, carried as
        // its unsigned bit pattern, rather than read out of bounds.
        if b.client_or_len < 0, b.client_or_len != .min, -b.client_or_len <= Self.maxRootNameLength,
           let name = b.variant.name {
            let len = Int(-b.client_or_len)
            return YID(client: nil, clock: 0, root: String(decoding: UnsafeBufferPointer(start: name, count: len), as: UTF8.self))
        }
        return YID(client: UInt64(bitPattern: b.client_or_len), clock: b.variant.clock, root: nil)
    }

    /// Element tag (node type name). Nil for fragments and text.
    public var tag: String? {
        guard kind == .element, let c = yxmlelem_tag(raw) else { return nil }
        defer { ystring_destroy(c) }
        return String(cString: c)
    }

    public var parent: YBranch? { yxmlelem_parent(raw).map(YBranch.init(raw:)) }

    // MARK: Children (elements and fragments)

    public func childCount(_ txn: YTransaction) -> Int { Int(yxmlelem_child_len(raw, txn.ptr)) }

    public func child(_ txn: YTransaction, _ index: Int) -> YBranch? {
        guard let out = yxmlelem_get(raw, txn.ptr, UInt32(index)) else { return nil }
        defer { youtput_destroy(UnsafeMutablePointer(mutating: out)) }
        return Self.branch(of: out.pointee)
    }

    public func children(_ txn: YTransaction) -> [YBranch] {
        var result: [YBranch] = []
        var next = yxmlelem_first_child(raw)
        while let out = next {
            // Each YOutput is ours to free (it only references the branch, which the document
            // owns). yffi only returns XML children here; if one weren't a branch there'd be
            // no sibling to walk to from it, so stop there.
            let b = Self.branch(of: out.pointee)
            youtput_destroy(out)
            guard let b else { break }
            result.append(b)
            next = yxml_next_sibling(b.raw, txn.ptr)
        }
        return result
    }

    static func branch(of out: YOutput) -> YBranch? {
        switch Int32(out.tag) {
        case Y_XML_ELEM, Y_XML_TEXT, Y_XML_FRAG: return out.value.y_type.map(YBranch.init(raw:))
        default: return nil
        }
    }

    @discardableResult
    public func insertElement(_ txn: YTransaction, _ index: Int, _ tag: String) -> YBranch {
        YBranch(raw: tag.withCString { yxmlelem_insert_elem(raw, txn.ptr, UInt32(index), $0) })
    }

    @discardableResult
    public func insertText(_ txn: YTransaction, _ index: Int) -> YBranch {
        YBranch(raw: yxmlelem_insert_text(raw, txn.ptr, UInt32(index)))
    }

    public func removeChildren(_ txn: YTransaction, _ index: Int, _ count: Int) {
        guard count > 0 else { return }
        yxmlelem_remove_range(raw, txn.ptr, UInt32(index), UInt32(count))
    }

    // MARK: Attributes (elements)

    public func attributes(_ txn: YTransaction) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        guard let iter = yxmlelem_attr_iter(raw, txn.ptr) else { return result }
        defer { yxmlattr_iter_destroy(iter) }
        while let attr = yxmlattr_iter_next(iter) {
            result[String(cString: attr.pointee.name)] = JSONValue(yOutput: attr.pointee.value.pointee)
            yxmlattr_destroy(attr)
        }
        return result
    }

    // MARK: Map

    /// A map's entries as JSON (nested shared types come back as null).
    public func mapEntries(_ txn: YTransaction) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        guard let iter = ymap_iter(raw, txn.ptr) else { return result }
        defer { ymap_iter_destroy(iter) }
        while let entry = ymap_iter_next(iter) {
            result[String(cString: entry.pointee.key)] = JSONValue(yOutput: entry.pointee.value.pointee)
            ymap_entry_destroy(entry)
        }
        return result
    }

    public func mapSet(_ txn: YTransaction, _ key: String, _ value: JSONValue) {
        withYInput(value) { input in key.withCString { ymap_insert(raw, txn.ptr, $0, input) } }
    }

    public func setAttribute(_ txn: YTransaction, _ key: String, _ value: JSONValue) {
        withYInput(value) { input in key.withCString { yxmlelem_insert_attr(raw, txn.ptr, $0, input) } }
    }

    public func removeAttribute(_ txn: YTransaction, _ key: String) {
        key.withCString { yxmlelem_remove_attr(raw, txn.ptr, $0) }
    }

    // MARK: Text

    public func textLength(_ txn: YTransaction) -> Int { Int(yxmltext_len(raw, txn.ptr)) }

    /// Runs of text with their formatting attributes, like Yjs `toDelta()`.
    public func textDelta(_ txn: YTransaction) -> [(text: String, attributes: [String: JSONValue])] {
        var count: UInt32 = 0
        guard let chunks = ytext_chunks(raw, txn.ptr, &count) else { return [] }
        defer { ychunks_destroy(chunks, count) }
        var result: [(String, [String: JSONValue])] = []
        for i in 0..<Int(count) {
            let chunk = chunks[i]
            guard Int32(chunk.data.tag) == Y_JSON_STR, let s = chunk.data.value.str else { continue }
            var attrs: [String: JSONValue] = [:]
            for j in 0..<Int(chunk.fmt_len) {
                let entry = chunk.fmt[j]
                attrs[String(cString: entry.key)] = JSONValue(yOutput: entry.value.pointee)
            }
            result.append((String(cString: s), attrs))
        }
        return result
    }

    public func insertString(_ txn: YTransaction, _ index: Int, _ text: String, attributes: [String: JSONValue]? = nil) {
        guard !text.isEmpty else { return }
        text.withCString { str in
            if let attributes {
                withYInput(.object(JSONObject(attributes))) { yxmltext_insert(raw, txn.ptr, UInt32(index), str, $0) }
            } else {
                yxmltext_insert(raw, txn.ptr, UInt32(index), str, nil)
            }
        }
    }

    public func removeText(_ txn: YTransaction, _ index: Int, _ length: Int) {
        guard length > 0 else { return }
        yxmltext_remove_range(raw, txn.ptr, UInt32(index), UInt32(length))
    }

    /// Set formatting on a range; a `.null` value removes that attribute.
    public func format(_ txn: YTransaction, _ index: Int, _ length: Int, _ attributes: [String: JSONValue]) {
        guard length > 0, !attributes.isEmpty else { return }
        withYInput(.object(JSONObject(attributes))) { yxmltext_format(raw, txn.ptr, UInt32(index), UInt32(length), $0) }
    }
}

extension YBranch {
    /// The content as JSON with no incidental differences: attribute keys sorted,
    /// null values dropped, and adjacent text runs with equal formatting merged.
    /// Two branches with equal canonical JSON hold the same document.
    ///
    /// Nesting deeper than `YSyncBinding.maxDepth` isn't followed: such an element comes out
    /// as `{"name": ..., "truncated": true}` (so a comparison with it never passes).
    public func canonicalJSON(_ txn: YTransaction) -> JSONValue { canonicalJSON(txn, depth: 0) }

    func canonicalJSON(_ txn: YTransaction, depth: Int) -> JSONValue {
        guard depth < YSyncBinding.maxDepth else { return ["name": .string(tag ?? "fragment"), "truncated": true] }
        switch kind {
        case .text:
            var runs: [(text: String, attributes: JSONValue)] = []
            for run in textDelta(txn) {
                let attrs = Self.canonical(.object(JSONObject(run.attributes)))
                if let last = runs.last, last.attributes == attrs {
                    runs[runs.count - 1].text += run.text
                } else if !run.text.isEmpty {
                    runs.append((run.text, attrs))
                }
            }
            return ["text": .array(runs.map { ["insert": .string($0.text), "attributes": $0.attributes] })]
        default:
            return ["name": .string(tag ?? "fragment"),
                    "attrs": Self.canonical(.object(JSONObject(attributes(txn)))),
                    "children": .array(children(txn).map { $0.canonicalJSON(txn, depth: depth + 1) })]
        }
    }

    private static func canonical(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let obj):
            var out = JSONObject()
            for (key, child) in obj.sorted(by: { $0.key < $1.key }) where child != .null { out[key] = canonical(child) }
            return .object(out)
        case .array(let items):
            return .array(items.map(canonical))
        default:
            return value
        }
    }
}

extension JSONObject {
    init(_ dict: [String: JSONValue]) {
        self.init()
        for key in dict.keys.sorted() { self[key] = dict[key] }
    }
}

// MARK: JSON <-> yffi values

extension JSONValue {
    /// Values nested deeper than `YSyncBinding.maxDepth` (arrays and maps in attributes, which
    /// a remote peer controls) read as null rather than recursing without bound.
    init(yOutput out: YOutput, depth: Int = 0) {
        guard depth < YSyncBinding.maxDepth else { self = .null; return }
        switch Int32(out.tag) {
        case Y_JSON_BOOL: self = .bool(out.value.flag != 0)
        case Y_JSON_NUM: self = .number(out.value.num)
        case Y_JSON_INT: self = .number(Double(out.value.integer))
        case Y_JSON_STR: self = out.value.str.map { .string(String(cString: $0)) } ?? .null
        case Y_JSON_ARR:
            var items: [JSONValue] = []
            for i in 0..<Int(out.len) { items.append(JSONValue(yOutput: out.value.array[i], depth: depth + 1)) }
            self = .array(items)
        case Y_JSON_MAP:
            var o = JSONObject()
            let entries = (0..<Int(out.len)).map { out.value.map[$0] }
            for entry in entries.sorted(by: { strcmp($0.key, $1.key) < 0 }) {
                o[String(cString: entry.key)] = JSONValue(yOutput: entry.value.pointee, depth: depth + 1)
            }
            self = .object(o)
        default: self = .null
        }
    }
}

/// Build a `YInput` tree for `value`, valid for the duration of `body`.
func withYInput<T>(_ value: JSONValue, _ body: (UnsafePointer<YInput>) -> T) -> T {
    var allocations: [UnsafeMutableRawPointer] = []
    defer { allocations.forEach { free($0) } }
    func alloc<E>(_: E.Type, _ count: Int) -> UnsafeMutablePointer<E> {
        let raw = malloc(MemoryLayout<E>.stride * max(1, count))!
        allocations.append(raw)
        return raw.bindMemory(to: E.self, capacity: max(1, count))
    }
    func make(_ value: JSONValue) -> YInput {
        switch value {
        case .null: return yinput_null()
        case .bool(let b): return yinput_bool(b ? UInt8(Y_TRUE) : UInt8(Y_FALSE))
        case .number(let n):
            // Integers go out as lib0 integers, as Yjs writes them; JS reads both as numbers.
            if n == n.rounded(), abs(n) <= 0x7FFF_FFFF { return yinput_long(Int64(n)) }
            return yinput_float(n)
        case .string(let s):
            let c = strdup(s)!
            allocations.append(UnsafeMutableRawPointer(c))
            return yinput_string(c)
        case .array(let items):
            let buf = alloc(YInput.self, items.count)
            for (i, item) in items.enumerated() { (buf + i).initialize(to: make(item)) }
            return yinput_json_array(buf, UInt32(items.count))
        case .object(let o):
            let entries = Array(o)
            let keys = alloc(UnsafeMutablePointer<CChar>?.self, entries.count)
            let values = alloc(YInput.self, entries.count)
            for (i, (key, item)) in entries.enumerated() {
                let c = strdup(key)!
                allocations.append(UnsafeMutableRawPointer(c))
                (keys + i).initialize(to: c)
                (values + i).initialize(to: make(item))
            }
            return yinput_json_map(keys, values, UInt32(entries.count))
        }
    }
    var input = make(value)
    return body(&input)
}
