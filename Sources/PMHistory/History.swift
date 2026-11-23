// Port of prosemirror-history/src/history.ts (with rope-sequence replaced by an array)
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

import PMModel
import PMTransform
import PMState

private let maxEmptyItems = 500
private let DEPTH_OVERFLOW = 20

/// Minimal stand-in for rope-sequence: same API, backed by an array.
struct ItemSeq {
    var items: [Item]
    static let empty = ItemSeq(items: [])
    var count: Int { items.count }
    func get(_ i: Int) -> Item { items[i] }
    func slice(_ from: Int = 0, _ to: Int? = nil) -> ItemSeq { ItemSeq(items: Array(items[from..<(to ?? items.count)])) }
    func append(_ other: [Item]) -> ItemSeq { ItemSeq(items: items + other) }
    /// rope-sequence forEach: forward over [from, to) when from <= to, else backward from from-1 down to `to`.
    /// Returning false stops the iteration.
    func forEach(_ from: Int = 0, _ to: Int? = nil, _ f: (Item, Int) -> Bool) {
        let to = to ?? items.count
        if from <= to {
            var i = from
            while i < to { if !f(items[i], i) { return }; i += 1 }
        } else {
            var i = from - 1
            while i >= to { if !f(items[i], i) { return }; i -= 1 }
        }
    }
}

final class Item {
    let map: StepMap
    let step: Step?
    let selection: SelectionBookmark?
    let mirrorOffset: Int?

    init(_ map: StepMap, _ step: Step? = nil, _ selection: SelectionBookmark? = nil, _ mirrorOffset: Int? = nil) {
        self.map = map
        self.step = step
        self.selection = selection
        self.mirrorOffset = mirrorOffset
    }

    func merge(_ other: Item) -> Item? {
        if let step, let otherStep = other.step, other.selection == nil, let merged = otherStep.merge(step) {
            return Item(merged.getMap().invert(), merged, selection)
        }
        return nil
    }
}

struct Branch {
    let items: ItemSeq
    let eventCount: Int

    static let empty = Branch(items: .empty, eventCount: 0)

    func popEvent(_ state: EditorState, _ preserveItems: Bool) -> (remaining: Branch, transform: Transaction, selection: SelectionBookmark)? {
        if eventCount == 0 { return nil }
        var end = items.count
        while true {
            let next = items.get(end - 1)
            if next.selection != nil { end -= 1; break }
            end -= 1
        }
        var remap: Mapping? = nil
        var mapFrom = 0
        if preserveItems {
            remap = remapping(end, items.count)
            mapFrom = remap!.maps.count
        }
        let transform = state.tr
        var selection: SelectionBookmark? = nil
        var remaining: Branch? = nil
        var addAfter: [Item] = [], addBefore: [Item] = []

        items.forEach(items.count, 0) { item, i in
            guard let itemStep = item.step else {
                if remap == nil {
                    remap = remapping(end, i + 1)
                    mapFrom = remap!.maps.count
                }
                mapFrom -= 1
                addBefore.append(item)
                return true
            }
            if let r = remap {
                addBefore.append(Item(item.map))
                let step = itemStep.map(r.slice(mapFrom))
                var map: StepMap? = nil
                if let step, transform.maybeStep(step).doc != nil {
                    map = transform.mapping.maps[transform.mapping.maps.count - 1]
                    addAfter.append(Item(map!, nil, nil, addAfter.count + addBefore.count))
                }
                mapFrom -= 1
                if let map { r.appendMap(map, mirrors: mapFrom) }
            } else {
                transform.maybeStep(itemStep)
            }
            if let sel = item.selection {
                selection = remap != nil ? sel.map(remap!.slice(mapFrom)) : sel
                remaining = Branch(items: items.slice(0, end).append(addBefore.reversed() + addAfter), eventCount: eventCount - 1)
                return false
            }
            return true
        }
        return (remaining!, transform, selection!)
    }

    func addTransform(_ transform: Transform, _ selection: SelectionBookmark?, _ options: HistoryOptions, _ preserveItems: Bool) -> Branch {
        var newItems: [Item] = []
        var eventCount = self.eventCount
        var selection = selection
        var oldItems = items
        var lastItem: Item? = !preserveItems && oldItems.count > 0 ? oldItems.get(oldItems.count - 1) : nil

        for i in 0..<transform.steps.count {
            let step = transform.steps[i].invert(transform.docs[i])
            var item = Item(transform.mapping.maps[i], step, selection)
            if let merged = lastItem?.merge(item) {
                item = merged
                if i > 0 { newItems.removeLast() } else { oldItems = oldItems.slice(0, oldItems.count - 1) }
            }
            newItems.append(item)
            if selection != nil {
                eventCount += 1
                selection = nil
            }
            if !preserveItems { lastItem = item }
        }
        let overflow = eventCount - options.depth
        if overflow > DEPTH_OVERFLOW {
            oldItems = cutOffEvents(oldItems, overflow)
            eventCount -= overflow
        }
        return Branch(items: oldItems.append(newItems), eventCount: eventCount)
    }

    func remapping(_ from: Int, _ to: Int) -> Mapping {
        let maps = Mapping()
        items.forEach(from, to) { item, i in
            let mirrorPos: Int? = item.mirrorOffset != nil && i - item.mirrorOffset! >= from ? maps.maps.count - item.mirrorOffset! : nil
            maps.appendMap(item.map, mirrors: mirrorPos)
            return true
        }
        return maps
    }

    func addMaps(_ array: [StepMap]) -> Branch {
        if eventCount == 0 { return self }
        return Branch(items: items.append(array.map { Item($0) }), eventCount: eventCount)
    }

    func rebased(_ rebasedTransform: Transform, _ rebasedCount: Int) -> Branch {
        if eventCount == 0 { return self }
        var rebasedItems: [Item] = []
        let start = max(0, items.count - rebasedCount)
        let mapping = rebasedTransform.mapping
        var newUntil = rebasedTransform.steps.count
        var eventCount = self.eventCount
        items.forEach(start) { item, _ in
            if item.selection != nil { eventCount -= 1 }
            return true
        }
        var iRebased = rebasedCount
        items.forEach(start) { item, _ in
            iRebased -= 1
            guard let pos = mapping.getMirror(iRebased) else { return true }
            newUntil = min(newUntil, pos)
            let map = mapping.maps[pos]
            if item.step != nil {
                let step = rebasedTransform.steps[pos].invert(rebasedTransform.docs[pos])
                let selection = item.selection?.map(mapping.slice(iRebased + 1, pos))
                if selection != nil { eventCount += 1 }
                rebasedItems.append(Item(map, step, selection))
            } else {
                rebasedItems.append(Item(map))
            }
            return true
        }
        var newMaps: [Item] = []
        var i = rebasedCount
        while i < newUntil { newMaps.append(Item(mapping.maps[i])); i += 1 }
        let newItems = items.slice(0, start).append(newMaps).append(rebasedItems)
        var branch = Branch(items: newItems, eventCount: eventCount)
        if branch.emptyItemCount() > maxEmptyItems {
            branch = branch.compress(items.count - rebasedItems.count)
        }
        return branch
    }

    func emptyItemCount() -> Int {
        items.items.filter { $0.step == nil }.count
    }

    func compress(_ upto: Int? = nil) -> Branch {
        let upto = upto ?? items.count
        let remap = remapping(0, upto)
        var mapFrom = remap.maps.count
        var newItems: [Item] = []
        var events = 0
        items.forEach(items.count, 0) { item, i in
            if i >= upto {
                newItems.append(item)
                if item.selection != nil { events += 1 }
            } else if let itemStep = item.step {
                let step = itemStep.map(remap.slice(mapFrom)), map = step?.getMap()
                mapFrom -= 1
                if let map { remap.appendMap(map, mirrors: mapFrom) }
                if let step {
                    let selection = item.selection?.map(remap.slice(mapFrom))
                    if selection != nil { events += 1 }
                    let newItem = Item(map!.invert(), step, selection)
                    let last = newItems.count - 1
                    if !newItems.isEmpty, let merged = newItems[last].merge(newItem) {
                        newItems[last] = merged
                    } else {
                        newItems.append(newItem)
                    }
                }
            } else {
                mapFrom -= 1
            }
            return true
        }
        return Branch(items: ItemSeq(items: newItems.reversed()), eventCount: events)
    }
}

private func cutOffEvents(_ items: ItemSeq, _ n: Int) -> ItemSeq {
    var n = n
    var cutPoint: Int? = nil
    items.forEach { item, i in
        if item.selection != nil {
            if n == 0 { cutPoint = i; return false }
            n -= 1
        }
        return true
    }
    return items.slice(cutPoint!)
}

/// The value of the history plugin's state field.
public final class HistoryState {
    let done: Branch
    let undone: Branch
    let prevRanges: [Int]?
    let prevTime: Double
    let prevComposition: Int

    init(_ done: Branch, _ undone: Branch, _ prevRanges: [Int]?, _ prevTime: Double, _ prevComposition: Int) {
        self.done = done
        self.undone = undone
        self.prevRanges = prevRanges
        self.prevTime = prevTime
        self.prevComposition = prevComposition
    }
}

public struct HistoryOptions {
    public var depth: Int
    public var newGroupDelay: Double
    public init(depth: Int = 100, newGroupDelay: Double = 500) {
        self.depth = depth
        self.newGroupDelay = newGroupDelay
    }
}

private struct HistoryMeta {
    let redo: Bool
    let historyState: HistoryState
}

private func applyTransaction(_ history: HistoryState, _ state: EditorState, _ tr: Transaction, _ options: HistoryOptions) -> HistoryState {
    var history = history
    if let historyTr = tr.getMeta(historyKey) as? HistoryMeta { return historyTr.historyState }
    if tr.getMeta(closeHistoryKey) != nil { history = HistoryState(history.done, history.undone, nil, 0, -1) }
    let appended = tr.getMeta("appendedTransaction") as? Transaction

    if tr.steps.isEmpty {
        return history
    } else if let appended, let meta = appended.getMeta(historyKey) as? HistoryMeta {
        if meta.redo {
            return HistoryState(history.done.addTransform(tr, nil, options, mustPreserveItems(state)),
                                history.undone, rangesFor(tr.mapping.maps), history.prevTime, history.prevComposition)
        } else {
            return HistoryState(history.done, history.undone.addTransform(tr, nil, options, mustPreserveItems(state)),
                                nil, history.prevTime, history.prevComposition)
        }
    } else if (tr.getMeta("addToHistory") as? Bool) != false && !((appended?.getMeta("addToHistory") as? Bool) == false) {
        let composition = tr.getMeta("composition") as? Int
        let newGroup = history.prevTime == 0 ||
            (appended == nil && history.prevComposition != (composition ?? Int.min) &&
             (history.prevTime < tr.time - options.newGroupDelay || !isAdjacentTo(tr, history.prevRanges)))
        let prevRanges = appended != nil ? mapRanges(history.prevRanges, tr.mapping) : rangesFor(tr.mapping.maps)
        return HistoryState(history.done.addTransform(tr, newGroup ? state.selection.getBookmark() : nil, options, mustPreserveItems(state)),
                            .empty, prevRanges, tr.time, composition ?? history.prevComposition)
    } else if let rebased = tr.getMeta("rebased") as? Int, rebased != 0 {
        return HistoryState(history.done.rebased(tr, rebased), history.undone.rebased(tr, rebased),
                            mapRanges(history.prevRanges, tr.mapping), history.prevTime, history.prevComposition)
    } else {
        return HistoryState(history.done.addMaps(tr.mapping.maps), history.undone.addMaps(tr.mapping.maps),
                            mapRanges(history.prevRanges, tr.mapping), history.prevTime, history.prevComposition)
    }
}

private func isAdjacentTo(_ transform: Transform, _ prevRanges: [Int]?) -> Bool {
    guard let prevRanges else { return false }
    if !transform.docChanged { return true }
    var adjacent = false
    transform.mapping.maps[0].forEach { start, end, _, _ in
        var i = 0
        while i < prevRanges.count {
            if start <= prevRanges[i + 1] && end >= prevRanges[i] { adjacent = true }
            i += 2
        }
    }
    return adjacent
}

private func rangesFor(_ maps: [StepMap]) -> [Int] {
    var result: [Int] = []
    var i = maps.count - 1
    while i >= 0 && result.isEmpty {
        maps[i].forEach { _, _, from, to in result.append(from); result.append(to) }
        i -= 1
    }
    return result
}

private func mapRanges(_ ranges: [Int]?, _ mapping: Mapping) -> [Int]? {
    guard let ranges else { return nil }
    var result: [Int] = []
    var i = 0
    while i < ranges.count {
        let from = mapping.map(ranges[i], assoc: 1), to = mapping.map(ranges[i + 1], assoc: -1)
        if from <= to { result.append(from); result.append(to) }
        i += 2
    }
    return result
}

private func histTransaction(_ history: HistoryState, _ state: EditorState, _ redo: Bool) -> Transaction? {
    let preserveItems = mustPreserveItems(state)
    let options = (historyKey.get(state)!.spec.extra["config"] as? HistoryOptions) ?? HistoryOptions()
    guard let pop = (redo ? history.undone : history.done).popEvent(state, preserveItems) else { return nil }
    let selection = pop.selection.resolve(pop.transform.doc)
    let added = (redo ? history.done : history.undone).addTransform(pop.transform, state.selection.getBookmark(), options, preserveItems)
    let newHist = HistoryState(redo ? added : pop.remaining, redo ? pop.remaining : added, nil, 0, -1)
    return pop.transform.setSelection(selection).setMeta(historyKey, HistoryMeta(redo: redo, historyState: newHist))
}

private func mustPreserveItems(_ state: EditorState) -> Bool {
    state.plugins.contains { $0.spec.extra["historyPreserveItems"] as? Bool == true }
}

/// Set a flag on the given transaction that will prevent further steps from being appended to an existing history event.
@discardableResult
public func closeHistory(_ tr: Transaction) -> Transaction { tr.setMeta(closeHistoryKey, true) }

let historyKey = PluginKey("history")
let closeHistoryKey = PluginKey("closeHistory")

/// Returns a plugin that enables the undo history for an editor.
public func history(_ config: HistoryOptions = HistoryOptions()) -> Plugin {
    var config = config
    if config.depth == 0 { config.depth = 100 }
    if config.newGroupDelay == 0 { config.newGroupDelay = 500 }
    let options = config
    return Plugin(PluginSpec(
        state: StateField(init: { _, _ in HistoryState(.empty, .empty, nil, 0, -1) },
                          apply: { tr, hist, state, _ in applyTransaction(hist as! HistoryState, state, tr, options) }),
        key: historyKey,
        extra: ["config": options]))
}

private func buildCommand(_ redo: Bool, _ scroll: Bool) -> Command {
    return { state, dispatch, _ in
        guard let hist = historyKey.getState(state) as? HistoryState else { return false }
        if (redo ? hist.undone : hist.done).eventCount == 0 { return false }
        if let dispatch, let tr = histTransaction(hist, state, redo) {
            dispatch(scroll ? tr.scrollIntoView() : tr)
        }
        return true
    }
}

public let undo = buildCommand(false, true)
public let redo = buildCommand(true, true)
public let undoNoScroll = buildCommand(false, false)
public let redoNoScroll = buildCommand(true, false)

public func undoDepth(_ state: EditorState) -> Int {
    (historyKey.getState(state) as? HistoryState)?.done.eventCount ?? 0
}

public func redoDepth(_ state: EditorState) -> Int {
    (historyKey.getState(state) as? HistoryState)?.undone.eventCount ?? 0
}

public func isHistoryTransaction(_ tr: Transaction) -> Bool { tr.getMeta(historyKey) != nil }
