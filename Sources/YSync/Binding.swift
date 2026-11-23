import Foundation
import CYrs
import PMModel
import PMTransform
import PMState

/// Keeps an editor's document and a Yjs XML fragment in step, the way
/// y-prosemirror's `ySyncPlugin` does, and in the same shape: block nodes are
/// `Y.XmlElement`s named after the node type with the attrs as XML attributes;
/// each run of text is one `Y.XmlText` whose formatting attributes are the marks
/// (mark name -> mark attrs). Ported from y-prosemirror 1.3.7 `sync-plugin.js`
/// (MIT, Kevin Jahns), minus snapshots, version rendering and XmlHooks.
///
/// Wiring:
/// - after every transaction the editor applies, call `localStateChanged`
///   (this writes local edits into Yjs and remembers the selection);
/// - after applying remote updates (or `undo`/`redo`), dispatch
///   `remoteTransaction(state)` if it returns one.
public final class YSyncBinding {
    /// Origin of transactions this binding writes; the undo manager tracks only these.
    public static let origin = "y-sync"
    /// Meta set on transactions produced by `remoteTransaction`.
    public static let remoteMeta = "y-sync$remote"
    /// Deepest nesting followed when reading Yjs content (and comparing it, and turning
    /// attribute values into JSON). A remote peer controls how deep the shared tree goes, and
    /// all of these recurse, so without a cap a deeply nested document would overflow the
    /// stack. Elements deeper than this are dropped from the editor's document (like content
    /// the schema rejects); comparisons treat them as unequal; deeper JSON reads as null.
    public static let maxDepth = 512

    public let doc: YDocument
    public let fragment: YBranch
    public let schema: Schema

    /// Y type -> the ProseMirror content it was last synced with.
    private var mapping: [YID: Mapped] = [:]
    /// Types changed by other origins since the last `remoteTransaction`.
    private var stale: Set<YID> = []
    private var remoteDirty = false
    private var writing = false
    /// The selection as sticky indices, captured after every local change.
    private var savedSelection: (anchor: UnsafeMutablePointer<YStickyIndex>, head: UnsafeMutablePointer<YStickyIndex>, kind: SelectionKind)?
    private var undoManager: UnsafeMutablePointer<YUndoManager>?
    /// Unique per binding, so several bindings (or a replaced one) can observe one document.
    private let observerKey = "y-sync-" + UUID().uuidString

    enum SelectionKind { case text, node, all }

    public init(doc: YDocument, fragmentName: String = "content", schema: Schema) {
        self.doc = doc
        self.fragment = doc.xmlFragment(fragmentName)
        self.schema = schema
        let state = Unmanaged.passUnretained(self).toOpaque()
        observerKey.withCString { key in
            yobserve_deep(fragment.raw, UInt32(strlen(key)), key, state) { state, count, events in
                guard let state, let events else { return }
                let binding = Unmanaged<YSyncBinding>.fromOpaque(state).takeUnretainedValue()
                binding.typesChanged(count, events)
            }
        }
    }

    deinit {
        // The observer holds an unretained pointer to this binding; the document may outlive it.
        observerKey.withCString { _ = yunobserve_deep(fragment.raw, UInt32(strlen($0)), $0) }
        clearSavedSelection()
        if let undoManager { yundo_manager_destroy(undoManager) }
    }

    // MARK: Undo (Y.UndoManager, so each user undoes only their own changes)

    /// Track this binding's own changes for undo. Undo/redo then go through Yjs
    /// rather than ProseMirror's history.
    public func enableUndo(captureTimeout: Int32 = 500) {
        guard undoManager == nil else { return }
        var options = YUndoManagerOptions(capture_timeout_millis: captureTimeout)
        guard let manager = yundo_manager(&options) else { return }
        yundo_manager_add_scope(manager, doc.raw, fragment.raw)
        Self.origin.withCString { yundo_manager_add_origin(manager, UInt32(Self.origin.utf8.count), $0) }
        undoManager = manager
    }

    public var canUndo: Bool { undoManager.map { yundo_manager_undo_stack_len($0) > 0 } ?? false }
    public var canRedo: Bool { undoManager.map { yundo_manager_redo_stack_len($0) > 0 } ?? false }

    /// Undo the last local change in Yjs. Follow with `remoteTransaction`.
    @discardableResult public func undo() -> Bool { undoManager.map { yundo_manager_undo($0) == UInt8(Y_TRUE) } ?? false }
    @discardableResult public func redo() -> Bool { undoManager.map { yundo_manager_redo($0) == UInt8(Y_TRUE) } ?? false }

    /// Start a new undo step, so the next change isn't merged with the previous one.
    public func stopCapturing() { if let undoManager { yundo_manager_stop(undoManager) } }

    // MARK: Editor -> Yjs

    /// The document currently in Yjs (nil if the fragment is empty).
    public func documentFromY() -> Node? {
        guard fragment.read(doc, { $0.childCount($1) }) > 0 else { return nil }
        return writeLocal { txn in buildDoc(txn) }
    }

    /// Write `node`'s content into an empty fragment (seeding a new shared document).
    /// Not undoable: undo shouldn't empty the note.
    public func seed(_ node: Node) {
        writeLocal(origin: Self.origin + "$seed") { txn in updateFragment(txn, fragment, node) }
    }

    /// Call after each transaction the editor applied. Writes the new document
    /// into Yjs unless the change came from Yjs, then saves the selection.
    ///
    /// Writing makes Yjs match the editor's whole document, so it must not happen while
    /// Yjs holds changes the editor hasn't pulled (`hasRemoteChanges`): they would be
    /// written over. Callers pull first (a deferred pull, e.g. during an IME composition,
    /// goes before the local change). If one doesn't, the local change isn't written
    /// (returns false) and the next `remoteTransaction` replaces it: losing the caller's
    /// own edit, never someone else's.
    ///
    /// `undoable: false` writes outside the undo manager's reach (repairs on open).
    @discardableResult
    public func localStateChanged(_ state: EditorState, _ tr: PMState.Transaction? = nil, undoable: Bool = true) -> Bool {
        let fromRemote = (tr?.getMeta(Self.remoteMeta) as? Bool) == true
        let write = !fromRemote && (tr?.docChanged ?? true)
        let safe = !(write && remoteDirty)
        writeLocal(origin: undoable ? Self.origin : Self.origin + "$untracked") { txn in
            if write, safe { updateFragment(txn, fragment, state.doc) }
            saveSelection(txn, state)
        }
        return safe
    }

    private func writeLocal<T>(origin: String = YSyncBinding.origin, _ body: (YTransaction) -> T) -> T {
        writing = true
        defer { writing = false }
        return doc.transact(origin: origin, body)
    }

    // MARK: Yjs -> editor

    private func typesChanged(_ count: UInt32, _ events: UnsafePointer<YEvent>) {
        guard !writing else { return }
        remoteDirty = true
        for i in 0..<Int(count) {
            var event = events[i]
            let target: UnsafeMutablePointer<Branch>? = switch Int32(event.tag) {
            case Y_XML_ELEM: yxmlelem_event_target(&event.content.xml_elem)
            case Y_XML_TEXT: yxmltext_event_target(&event.content.xml_text)
            default: nil
            }
            var branch = target.map(YBranch.init(raw:))
            while let b = branch {
                stale.insert(b.id)
                branch = b.kind == .fragment ? nil : b.parent
            }
        }
    }

    /// Whether Yjs changed (remote update, undo, redo) since the editor last caught up.
    public var hasRemoteChanges: Bool { remoteDirty }

    /// A transaction replacing the editor's document with what's in Yjs, keeping
    /// unchanged nodes (so the view can reuse their rendering) and restoring the
    /// selection from where it was anchored in Yjs. Nil if nothing changed.
    public func remoteTransaction(_ state: EditorState) -> PMState.Transaction? {
        guard remoteDirty else { return nil }
        remoteDirty = false
        for id in stale { mapping[id] = nil }
        stale = []
        return writeLocal { txn -> PMState.Transaction? in
            let content = Fragment.from(buildContent(txn, fragment))
            var tr = state.tr
            guard let start = state.doc.content.findDiffStart(content), var end = state.doc.content.findDiffEnd(content) else {
                // Same content (only attributes or selection changed).
                restoreSelection(txn, tr)
                _ = tr.setMeta(Self.remoteMeta, true)
                _ = tr.setMeta("addToHistory", false)
                return tr
            }
            // Replace only the range that changed, so positions outside it (a table's, a scoped
            // view's) map through untouched. When that can't be done (the slice doesn't fit, which
            // ProseMirror's replace can throw on), replace the whole doc as y-prosemirror does.
            // Giving up instead would leave the editor behind Yjs for good: the changes are
            // already marked as seen.
            let overlap = start - min(end.a, end.b)
            if overlap > 0 { end = (end.a + overlap, end.b + overlap) }
            var partial = false
            if let target = try? schema.topNodeType.create(state.doc.attrs, content) {
                partial = (try? tr.replace(start, end.a, target.slice(start, end.b))) != nil && tr.doc.eq(target)
            }
            if !partial {
                tr = state.tr
                do {
                    _ = try tr.replace(0, state.doc.content.size, Slice(content, 0, 0))
                } catch {
                    return nil
                }
            }
            restoreSelection(txn, tr)
            _ = tr.setMeta(Self.remoteMeta, true)
            _ = tr.setMeta("addToHistory", false)
            return tr
        }
    }

    private func buildDoc(_ txn: YTransaction) -> Node? {
        let content = buildContent(txn, fragment)
        return try? schema.topNodeType.createChecked(nil, Fragment.from(content))
    }

    // Reading Yjs into the editor. Content the schema rejects (an unknown node type, bad
    // attrs or marks, invalid content, or nesting past `maxDepth`) is left out of the
    // editor's document but NOT deleted from Yjs. y-prosemirror 1.3.7 deletes it on read
    // (`createNodeFromYElement` / `createTextNodesFromYText` delete the item in a transaction),
    // which broadcasts a deletion from every client that merely opens the document: a hostile
    // or newer-schema peer's content gets erased by readers, and readers write without any
    // user action. Skipping instead yields the same editor document, so peers (including
    // y-prosemirror ones, which still delete) converge on the same content; the YSyncTests
    // convergence tests check this against the JS peer. The skipped content stays in Yjs until
    // a local edit rewrites its parent (`updateFragment` makes the parent match the editor, as
    // y-prosemirror's `updateYFragment` does). The one write left on this path is the
    // y-prosemirror #160 fold of our own adjacent text, kept for parity.

    private func buildContent(_ txn: YTransaction, _ parent: YBranch, depth: Int = 0) -> [Node] {
        parent.children(txn).compactMap { child in
            child.kind == .element ? nodeIfNotExists(txn, child, depth: depth + 1) : nil
        }
    }

    private func nodeIfNotExists(_ txn: YTransaction, _ el: YBranch, depth: Int) -> Node? {
        if case .node(let node)? = mapping[el.id] { return node }
        return nodeFromElement(txn, el, depth: depth)
    }

    private func nodeFromElement(_ txn: YTransaction, _ el: YBranch, depth: Int) -> Node? {
        guard depth <= Self.maxDepth else {
            mapping[el.id] = nil
            return nil
        }
        var children: [Node] = []
        let kids = el.children(txn)
        var i = 0
        while i < kids.count {
            let child = kids[i]
            if child.kind == .element {
                if let n = nodeIfNotExists(txn, child, depth: depth + 1) { children.append(n) }
            } else if child.kind == .text {
                // y-prosemirror #160: two adjacent texts, the second ours, would
                // duplicate characters; fold the second into the first.
                if i + 1 < kids.count, kids[i + 1].kind == .text, kids[i + 1].id.client == doc.clientID {
                    let next = kids[i + 1]
                    var at = child.textLength(txn)
                    for run in next.textDelta(txn) {
                        child.insertString(txn, at, run.text, attributes: run.attributes)
                        at += run.text.utf16.count
                    }
                    // By its index now, in case the children changed since the snapshot
                    // (deleting past the end panics in yrs).
                    if let index = el.children(txn).firstIndex(where: { $0.id == next.id }) {
                        el.removeChildren(txn, index, 1)
                    }
                    mapping[next.id] = nil
                }
                if let texts = textNodes(txn, child) { children.append(contentsOf: texts) }
            }
            i += 1
        }
        guard let name = el.tag, let type = schema.nodes[name],
              let node = try? type.createChecked(JSONObject(el.attributes(txn)), Fragment.from(children)) else {
            // Most likely the result of a concurrent change: leave it out of the editor's
            // document, but don't delete it from Yjs (see above).
            mapping[el.id] = nil
            return nil
        }
        mapping[el.id] = .node(node)
        return node
    }

    private func textNodes(_ txn: YTransaction, _ text: YBranch) -> [Node]? {
        var nodes: [Node] = []
        do {
            for run in text.textDelta(txn) where !run.text.isEmpty {
                nodes.append(schema.text(run.text, try attributesToMarks(run.attributes)))
            }
        } catch {
            // Marks the schema doesn't know: leave the text out, without deleting it (see above).
            return nil
        }
        return nodes
    }

    private func attributesToMarks(_ attrs: [String: JSONValue]) throws -> [Mark] {
        try attrs.keys.sorted().map { key in
            try schema.mark(yattrToMarkName(key), attrs[key]?.objectValue)
        }
    }

    // MARK: updateYFragment

    private func updateFragment(_ txn: YTransaction, _ y: YBranch, _ pNode: Node) {
        mapping[y.id] = .node(pNode)
        if y.kind == .element {
            precondition(y.tag == pNode.type.name, "node name mismatch!")
            let yAttrs = y.attributes(txn)
            for (key, value) in pNode.attrs where key != "ychange" {
                if !value.isNull {
                    if yAttrs[key] != value { y.setAttribute(txn, key, value) }
                } else if yAttrs[key] != nil {
                    y.removeAttribute(txn, key)
                }
            }
            for key in yAttrs.keys where pNode.attrs[key] == nil {
                y.removeAttribute(txn, key)
            }
        }
        let pChildren = normalize(pNode)
        let pCount = pChildren.count
        let yChildren = y.children(txn)
        let yCount = yChildren.count
        let minCount = min(pCount, yCount)
        var left = 0, right = 0
        while left < minCount {
            let leftY = yChildren[left], leftP = pChildren[left]
            if !mappedIdentity(mapping[leftY.id], leftP) {
                guard equal(txn, leftY, leftP) else { break }
                mapping[leftY.id] = leftP.mapped
            }
            left += 1
        }
        while right + left < minCount {
            let rightY = yChildren[yCount - right - 1], rightP = pChildren[pCount - right - 1]
            if !mappedIdentity(mapping[rightY.id], rightP) {
                guard equal(txn, rightY, rightP) else { break }
                mapping[rightY.id] = rightP.mapped
            }
            right += 1
        }
        while yCount - left - right > 0 && pCount - left - right > 0 {
            let leftY = yChildren[left], leftP = pChildren[left]
            let rightY = yChildren[yCount - right - 1], rightP = pChildren[pCount - right - 1]
            if leftY.kind == .text, case .texts(let texts) = leftP {
                if !equalText(txn, leftY, texts) { updateText(txn, leftY, texts) }
                left += 1
            } else {
                var updateLeft = leftY.kind == .element && matchName(leftY, leftP)
                var updateRight = rightY.kind == .element && matchName(rightY, rightP)
                if updateLeft && updateRight, case .node(let lp) = leftP, case .node(let rp) = rightP {
                    let equalityLeft = childEqualityFactor(txn, leftY, lp)
                    let equalityRight = childEqualityFactor(txn, rightY, rp)
                    if equalityLeft.foundMappedChild && !equalityRight.foundMappedChild {
                        updateRight = false
                    } else if !equalityLeft.foundMappedChild && equalityRight.foundMappedChild {
                        updateLeft = false
                    } else if equalityLeft.factor < equalityRight.factor {
                        updateLeft = false
                    } else {
                        updateRight = false
                    }
                }
                if updateLeft, case .node(let lp) = leftP {
                    updateFragment(txn, leftY, lp)
                    left += 1
                } else if updateRight, case .node(let rp) = rightP {
                    updateFragment(txn, rightY, rp)
                    right += 1
                } else {
                    mapping[leftY.id] = nil
                    y.removeChildren(txn, left, 1)
                    create(txn, in: y, at: left, leftP)
                    left += 1
                }
            }
        }
        let yDelLen = yCount - left - right
        if yCount == 1 && pCount == 0 && yChildren[0].kind == .text {
            // y-prosemirror #108: empty the text rather than delete it, keeping concurrent edits to it.
            mapping[yChildren[0].id] = nil
            yChildren[0].removeText(txn, 0, yChildren[0].textLength(txn))
        } else if yDelLen > 0 {
            for child in yChildren[left..<(left + yDelLen)] { mapping[child.id] = nil }
            y.removeChildren(txn, left, yDelLen)
        }
        if left + right < pCount {
            for (offset, child) in pChildren[left..<(pCount - right)].enumerated() {
                create(txn, in: y, at: left + offset, child)
            }
        }
    }

    private func create(_ txn: YTransaction, in parent: YBranch, at index: Int, _ content: PChild) {
        switch content {
        case .texts(let texts):
            let type = parent.insertText(txn, index)
            var at = 0
            for t in texts {
                let s = t.text!
                type.insertString(txn, at, s, attributes: marksToAttributes(t.marks))
                at += s.utf16.count
            }
            mapping[type.id] = .texts(texts)
        case .node(let node):
            let type = parent.insertElement(txn, index, node.type.name)
            for (key, value) in node.attrs where !value.isNull && key != "ychange" {
                type.setAttribute(txn, key, value)
            }
            for (i, child) in normalize(node).enumerated() { create(txn, in: type, at: i, child) }
            mapping[type.id] = .node(node)
        }
    }

    private func updateText(_ txn: YTransaction, _ ytext: YBranch, _ ptexts: [Node]) {
        mapping[ytext.id] = .texts(ptexts)
        let delta = ytext.textDelta(txn)
        let str = delta.map(\.text).joined()
        var nullAttrs: [String: JSONValue] = [:]
        for run in delta { for key in run.attributes.keys { nullAttrs[key] = .null } }
        let content = ptexts.map { p -> (text: String, attrs: [String: JSONValue]) in
            (p.text!, nullAttrs.merging(marksToAttributes(p.marks)) { $1 })
        }
        let diff = simpleDiff(Array(str.utf16), Array(content.map(\.text).joined().utf16))
        ytext.removeText(txn, diff.index, diff.remove)
        ytext.insertString(txn, diff.index, String(decoding: diff.insert, as: UTF16.self))
        var at = 0
        for c in content {
            let length = c.text.utf16.count
            ytext.format(txn, at, length, c.attrs)
            at += length
        }
    }

    // MARK: Equality

    /// Past `maxDepth` levels the content counts as unequal (so it gets rewritten, never
    /// assumed to match).
    private func equal(_ txn: YTransaction, _ ytype: YBranch, _ pnode: PChild, depth: Int = 0) -> Bool {
        guard depth < Self.maxDepth else { return false }
        switch pnode {
        case .node(let node):
            guard ytype.kind == .element, ytype.tag == node.type.name else { return false }
            let normalized = normalize(node)
            let yChildren = ytype.children(txn)
            return yChildren.count == normalized.count
                && equalAttrs(ytype.attributes(txn), Self.dict(node.attrs))
                && zip(yChildren, normalized).allSatisfy { equal(txn, $0, $1, depth: depth + 1) }
        case .texts(let texts):
            return ytype.kind == .text && equalText(txn, ytype, texts)
        }
    }

    private func equalText(_ txn: YTransaction, _ ytext: YBranch, _ ptexts: [Node]) -> Bool {
        let delta = ytext.textDelta(txn)
        guard delta.count == ptexts.count else { return false }
        return zip(delta, ptexts).allSatisfy { d, p in
            d.text == p.text && d.attributes.count == p.marks.count && d.attributes.allSatisfy { name, value in
                let markName = yattrToMarkName(name)
                // The mark must be there: y-prosemirror compares against its attrs only, so an
                // attr-less mark (italic: {}) "equals" a missing one, and a text whose marks were
                // swapped for as many others is never written.
                guard let mark = p.marks.first(where: { $0.type.name == markName }) else { return false }
                return equalAttrs(value.objectValue.map(Self.dict) ?? [:], Self.dict(mark.attrs))
            }
        }
    }

    private func childEqualityFactor(_ txn: YTransaction, _ ytype: YBranch, _ pnode: Node) -> (factor: Int, foundMappedChild: Bool) {
        let yChildren = ytype.children(txn)
        let pChildren = normalize(pnode)
        let minCount = min(yChildren.count, pChildren.count)
        var left = 0, right = 0, found = false
        while left < minCount {
            if mappedIdentity(mapping[yChildren[left].id], pChildren[left]) {
                found = true
            } else if !equal(txn, yChildren[left], pChildren[left], depth: 1) {
                break
            }
            left += 1
        }
        while left + right < minCount {
            let y = yChildren[yChildren.count - right - 1], p = pChildren[pChildren.count - right - 1]
            if mappedIdentity(mapping[y.id], p) {
                found = true
            } else if !equal(txn, y, p, depth: 1) {
                break
            }
            right += 1
        }
        return (left + right, found)
    }

    private func matchName(_ y: YBranch, _ p: PChild) -> Bool {
        if case .node(let n) = p { return y.tag == n.type.name }
        return false
    }

    // MARK: Selection

    private func saveSelection(_ txn: YTransaction, _ state: EditorState) {
        clearSavedSelection()
        let sel = state.selection
        let kind: SelectionKind = sel is AllSelection ? .all : sel is NodeSelection ? .node : .text
        guard let anchor = sticky(txn, sel.anchor, state.doc), let head = sticky(txn, sel.head, state.doc) else { return }
        savedSelection = (anchor, head, kind)
    }

    private func clearSavedSelection() {
        if let s = savedSelection {
            ysticky_index_destroy(s.anchor)
            ysticky_index_destroy(s.head)
        }
        savedSelection = nil
    }

    private func restoreSelection(_ txn: YTransaction, _ tr: PMState.Transaction) {
        guard let saved = savedSelection else { return }
        if saved.kind == .all {
            _ = tr.setSelection(AllSelection(tr.doc))
            return
        }
        guard let anchor = absolute(txn, saved.anchor, tr.doc), let head = absolute(txn, saved.head, tr.doc) else { return }
        if saved.kind == .node, let node = tr.doc.nodeAt(anchor), NodeSelection.isSelectable(node) {
            _ = tr.setSelection(NodeSelection.create(tr.doc, anchor))
        } else {
            _ = tr.setSelection(TextSelection.between(tr.doc.resolve(anchor), tr.doc.resolve(head)))
        }
    }

    /// A ProseMirror position as a sticky index into the Y tree: inside a text run
    /// it sticks to the character, elsewhere to the child it comes before.
    private func sticky(_ txn: YTransaction, _ pos: Int, _ docNode: Node) -> UnsafeMutablePointer<YStickyIndex>? {
        var branch = fragment
        var node = docNode
        var offset = pos
        descend: while true {
            let yChildren = branch.children(txn)
            var cur = 0
            for (k, child) in normalize(node).enumerated() {
                guard k < yChildren.count else { break }
                switch child {
                case .texts(let texts):
                    let length = texts.reduce(0) { $0 + $1.nodeSize }
                    if offset <= cur + length {
                        return ysticky_index_from_index(yChildren[k].raw, txn.ptr, UInt32(max(0, offset - cur)), 0)
                    }
                    cur += length
                case .node(let n):
                    if offset == cur { return ysticky_index_from_index(branch.raw, txn.ptr, UInt32(k), 0) }
                    if offset < cur + n.nodeSize {
                        branch = yChildren[k]
                        node = n
                        offset -= cur + 1
                        continue descend
                    }
                    cur += n.nodeSize
                }
            }
            return ysticky_index_from_index(branch.raw, txn.ptr, UInt32(branch.childCount(txn)), -1)
        }
    }

    /// Resolve a sticky index against the current Y tree and the matching document.
    private func absolute(_ txn: YTransaction, _ sticky: UnsafeMutablePointer<YStickyIndex>, _ docNode: Node) -> Int? {
        var out: UnsafeMutablePointer<Branch>?
        var index: UInt32 = 0
        ysticky_index_read(sticky, txn.ptr, &out, &index)
        guard let out else { return nil }
        // Path of child indices from the fragment down to the target.
        var path: [Int] = []
        var b = YBranch(raw: out)
        while b.kind != .fragment {
            guard let parent = b.parent, let i = parent.children(txn).firstIndex(where: { $0.id == b.id }) else { return nil }
            path.insert(i, at: 0)
            b = parent
        }
        guard b.id == fragment.id else { return nil }
        var node = docNode
        var pos = 0
        let target = YBranch(raw: out)
        for (step, k) in path.enumerated() {
            let children = normalize(node)
            guard k < children.count else { return nil }
            let start = children[..<k].reduce(0) { $0 + $1.size }
            switch children[k] {
            case .texts(let texts):
                guard step == path.count - 1 else { return nil }
                return pos + start + min(Int(index), texts.reduce(0) { $0 + $1.nodeSize })
            case .node(let n):
                pos += start + 1
                node = n
            }
        }
        guard target.kind != .text else { return nil }
        let children = normalize(node)
        return pos + children[..<min(Int(index), children.count)].reduce(0) { $0 + $1.size }
    }
}

// MARK: Helpers

/// A node's content as Yjs sees it: elements, and runs of adjacent text nodes.
enum PChild {
    case node(Node)
    case texts([Node])

    var mapped: Mapped {
        switch self {
        case .node(let n): return .node(n)
        case .texts(let t): return .texts(t)
        }
    }

    var size: Int {
        switch self {
        case .node(let n): return n.nodeSize
        case .texts(let t): return t.reduce(0) { $0 + $1.nodeSize }
        }
    }
}

enum Mapped {
    case node(Node)
    case texts([Node])
}

func normalize(_ node: Node) -> [PChild] {
    var result: [PChild] = []
    var run: [Node] = []
    for child in node.content.content {
        if child.isText {
            run.append(child)
        } else {
            if !run.isEmpty { result.append(.texts(run)); run = [] }
            result.append(.node(child))
        }
    }
    if !run.isEmpty { result.append(.texts(run)) }
    return result
}

func mappedIdentity(_ mapped: Mapped?, _ content: PChild) -> Bool {
    switch (mapped, content) {
    case (.node(let a)?, .node(let b)): return a === b
    case (.texts(let a)?, .texts(let b)): return a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    default: return false
    }
}

/// y-prosemirror `equalAttrs(yattrs, pattrs)`: null values don't count; nested
/// objects compare deeply.
func equalAttrs(_ a: [String: JSONValue], _ b: [String: JSONValue]?) -> Bool {
    let keys = a.keys.filter { !a[$0]!.isNull }
    let bCount = b.map { $0.values.filter { !$0.isNull }.count } ?? 0
    guard keys.count == bCount else { return false }
    return keys.allSatisfy { key in
        guard key != "ychange" else { return true }
        let l = a[key]!, r = b?[key]
        if l == r { return true }
        if case .object(let lo) = l, case .object(let ro)? = r { return equalAttrs(YSyncBinding.dict(lo), YSyncBinding.dict(ro)) }
        return false
    }
}

/// Marks as Y.Text formatting: mark name -> mark attrs.
func marksToAttributes(_ marks: [Mark]) -> [String: JSONValue] {
    var attrs: [String: JSONValue] = [:]
    for mark in marks where mark.type.name != "ychange" {
        // y-prosemirror suffixes a hash for marks that may overlap themselves
        // (`excludes` without their own type); the schemas tested here have none.
        attrs[mark.type.name] = .object(mark.attrs)
    }
    return attrs
}

func yattrToMarkName(_ name: String) -> String {
    // `name--xxxxxxxx`: an overlapping mark's hashed attribute name.
    if name.count > 10, let range = name.range(of: "--", options: .backwards),
       name.distance(from: range.upperBound, to: name.endIndex) == 8 {
        return String(name[..<range.lowerBound])
    }
    return name
}

/// lib0 `simpleDiffString`, on UTF-16 code units.
func simpleDiff(_ a: [UInt16], _ b: [UInt16]) -> (index: Int, remove: Int, insert: [UInt16]) {
    var left = 0, right = 0
    while left < a.count && left < b.count && a[left] == b[left] { left += 1 }
    if left > 0 && UTF16.isLeadSurrogate(a[left - 1]) { left -= 1 }
    while right + left < a.count && right + left < b.count && a[a.count - right - 1] == b[b.count - right - 1] { right += 1 }
    if right > 0 && UTF16.isTrailSurrogate(a[a.count - right]) { right -= 1 }
    return (left, a.count - left - right, Array(b[left..<(b.count - right)]))
}

extension YSyncBinding {
    static func dict(_ o: JSONObject) -> [String: JSONValue] {
        var d: [String: JSONValue] = [:]
        for (k, v) in o { d[k] = v }
        return d
    }
}

extension YBranch {
    func read<T>(_ doc: YDocument, _ body: (YBranch, YTransaction) -> T) -> T {
        doc.read { body(self, $0) }
    }
}

// MARK: Round-trip check

extension YSyncBinding {
    /// What a shared document looks like to an editor with `schema`.
    public struct RoundTrip {
        /// The document built from the fragment (nil when the fragment is empty).
        public let document: Node?
        /// Writing `document` back would reproduce the fragment exactly. When false,
        /// binding to the fragment would drop or rewrite content the schema can't
        /// represent (as y-prosemirror does), so the note should stay read-only.
        public let lossless: Bool
        /// Where the fragment and the written document first differ, described by
        /// structure only (node names, attr keys, value kinds, text lengths), so it can
        /// be logged without the note's text. Nil when lossless.
        public let difference: String?
    }

    /// Builds the document from a copy of `doc`, never touching `doc` itself, and
    /// checks that writing it back loses nothing.
    public static func roundTrip(_ doc: YDocument, fragmentName: String = "content", schema: Schema) -> RoundTrip {
        // Root types are looked up outside transactions: yrs takes a write lock to do it.
        let fragment = doc.xmlFragment(fragmentName)
        let original = doc.read { fragment.canonicalJSON($0) }
        let copy = YDocument()
        copy.applyUpdate(doc.encodeStateAsUpdate())
        guard let node = YSyncBinding(doc: copy, fragmentName: fragmentName, schema: schema).documentFromY() else {
            let empty = doc.read { fragment.childCount($0) } == 0
            return RoundTrip(document: nil, lossless: empty,
                             difference: empty ? nil : "fragment doesn't fit the schema: " + outline(original))
        }
        let fresh = YDocument()
        YSyncBinding(doc: fresh, fragmentName: fragmentName, schema: schema).seed(node)
        let freshFragment = fresh.xmlFragment(fragmentName)
        let written = normalized(fresh.read { freshFragment.canonicalJSON($0) }, schema)
        let expected = normalized(original, schema)
        let difference = written == expected ? nil : firstDifference(expected, written, "content") ?? "unknown"
        return RoundTrip(document: node, lossless: difference == nil, difference: difference)
    }

    /// Canonical JSON without the differences that lose nothing: attrs missing from the
    /// fragment count as their schema default (notes written before the attr existed,
    /// such as `textAlign`, get it filled in when built), empty texts are dropped and
    /// adjacent texts merged (one text node in the editor either way).
    static func normalized(_ value: JSONValue, _ schema: Schema) -> JSONValue {
        guard case .object(let obj) = value else { return value }
        if case .array(let runs)? = obj["text"] {
            return ["text": .array(mergedRuns(runs.map { run in
                guard case .object(var r) = run, case .object(let marks)? = r["attributes"] else { return run }
                var filled = JSONObject()
                for (key, attrs) in marks {
                    if case .object(let given) = attrs, let type = schema.marks[yattrToMarkName(key)],
                       let mark = try? type.create(given) {
                        filled[key] = .object(withDefaults(given, mark.attrs))
                    } else {
                        filled[key] = attrs
                    }
                }
                r["attributes"] = .object(filled)
                return .object(r)
            }))]
        }
        var out = obj
        if case .string(let name)? = obj["name"], case .object(let attrs)? = obj["attrs"],
           let type = schema.nodes[name], let computed = try? type.computeAttrs(attrs) {
            out["attrs"] = .object(withDefaults(attrs, computed))
        }
        if case .array(let children)? = obj["children"] {
            var merged: [JSONValue] = []
            for child in children.map({ normalized($0, schema) }) {
                guard case .object(let c) = child, case .array(let runs)? = c["text"] else { merged.append(child); continue }
                if runs.isEmpty { continue }
                if case .object(let last)? = merged.last, case .array(let previous)? = last["text"] {
                    merged[merged.count - 1] = ["text": .array(mergedRuns(previous + runs))]
                } else {
                    merged.append(child)
                }
            }
            out["children"] = .array(merged)
        }
        return .object(out)
    }

    private static func withDefaults(_ given: JSONObject, _ computed: JSONObject) -> JSONObject {
        var out = given
        for (key, value) in computed where given[key] == nil && value != .null { out[key] = value }
        return out
    }

    private static func mergedRuns(_ runs: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        for run in runs {
            guard case .object(let r) = run, case .string(let text)? = r["insert"] else { out.append(run); continue }
            if case .object(var last)? = out.last, case .string(let previous)? = last["insert"], last["attributes"] == r["attributes"] {
                last["insert"] = .string(previous + text)
                out[out.count - 1] = .object(last)
            } else if !text.isEmpty {
                out.append(run)
            }
        }
        return out
    }

    /// The first place `a` (the fragment) and `b` (as written back) differ, without text or string values.
    static func firstDifference(_ a: JSONValue, _ b: JSONValue, _ path: String) -> String? {
        guard a != b else { return nil }
        guard case .object(let x) = a, case .object(let y) = b else { return "\(path): \(kind(a)) vs \(kind(b))" }
        if case .array(let ra)? = x["text"] {
            guard case .array(let rb)? = y["text"] else { return "\(path): text vs \(outline(b))" }
            let describe = { (runs: [JSONValue]) in runs.map { run -> String in
                guard case .object(let r) = run else { return kind(run) }
                return "\(kind(r["insert"] ?? .null))\(kind(r["attributes"] ?? .null))"
            }.joined(separator: " ") }
            return "\(path): text runs [\(describe(ra))] vs [\(describe(rb))]"
        }
        if x["name"] != y["name"] { return "\(path): \(outline(a)) vs \(outline(b))" }
        let name = { if case .string(let n)? = x["name"] { return n } else { return "?" } }()
        if x["attrs"] != y["attrs"] {
            let ax = { if case .object(let o)? = x["attrs"] { return o } else { return JSONObject() } }()
            let ay = { if case .object(let o)? = y["attrs"] { return o } else { return JSONObject() } }()
            let keys = Set(ax.keys).union(ay.keys).sorted().filter { ax[$0] != ay[$0] }
            return "\(path) (\(name)): attrs " + keys.map { "\($0): \(kind(ax[$0] ?? .null)) vs \(kind(ay[$0] ?? .null))" }.joined(separator: ", ")
        }
        guard case .array(let ca)? = x["children"], case .array(let cb)? = y["children"] else { return "\(path) (\(name))" }
        for i in 0..<min(ca.count, cb.count) {
            if let d = firstDifference(ca[i], cb[i], "\(path)>\(i)") { return d }
        }
        return "\(path) (\(name)): children [\(ca.map(outline).joined(separator: " "))] vs [\(cb.map(outline).joined(separator: " "))]"
    }

    private static func outline(_ value: JSONValue) -> String {
        guard case .object(let o) = value else { return kind(value) }
        if case .array(let runs)? = o["text"] { return "text(\(runs.count) runs)" }
        let name = { if case .string(let n)? = o["name"] { return n } else { return "?" } }()
        guard case .array(let children)? = o["children"], !children.isEmpty else { return name }
        return name == "fragment" ? children.map(outline).joined(separator: " ") : "\(name)(\(children.count))"
    }

    /// A value's shape: numbers, bools and null as they are, strings by length, objects by key.
    private static func kind(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .number(let n): return "\(n)"
        case .string(let s): return "string(\(s.count))"
        case .array(let items): return "[\(items.map(kind).joined(separator: ","))]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0):\(kind(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }
}
