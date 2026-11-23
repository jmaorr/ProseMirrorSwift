// Port of prosemirror-transform/src/map.ts
// Copyright (C) 2015-2017 by Marijn Haverbeke and others. MIT license (see LICENSE-PROSEMIRROR).

/// There are several things that positions can be mapped through.
public protocol Mappable {
    func map(_ pos: Int, assoc: Int) -> Int
    func mapResult(_ pos: Int, assoc: Int) -> MapResult
}

extension Mappable {
    public func map(_ pos: Int) -> Int { map(pos, assoc: 1) }
    public func mapResult(_ pos: Int) -> MapResult { mapResult(pos, assoc: 1) }
}

// Recovery values encode a range index (lower 16 bits) and an offset.
private let lower16 = 0xffff
private let factor16 = 1 << 16
private func makeRecover(_ index: Int, _ offset: Int) -> Int { index + offset * factor16 }
private func recoverIndex(_ value: Int) -> Int { value & lower16 }
private func recoverOffset(_ value: Int) -> Int { (value - (value & lower16)) / factor16 }

private let DEL_BEFORE = 1, DEL_AFTER = 2, DEL_ACROSS = 4, DEL_SIDE = 8

/// An object representing a mapped position with extra information.
public struct MapResult {
    public let pos: Int
    let delInfo: Int
    let recover: Int?

    public var deleted: Bool { (delInfo & DEL_SIDE) > 0 }
    public var deletedBefore: Bool { (delInfo & (DEL_BEFORE | DEL_ACROSS)) > 0 }
    public var deletedAfter: Bool { (delInfo & (DEL_AFTER | DEL_ACROSS)) > 0 }
    public var deletedAcross: Bool { (delInfo & DEL_ACROSS) > 0 }
}

/// A map describing the deletions and insertions made by a step.
public final class StepMap: Mappable, CustomStringConvertible {
    public let ranges: [Int]
    public let inverted: Bool

    public init(_ ranges: [Int], inverted: Bool = false) {
        self.ranges = ranges
        self.inverted = inverted
    }

    public static let empty = StepMap([])

    func recover(_ value: Int) -> Int {
        var diff = 0
        let index = recoverIndex(value)
        if !inverted { for i in 0..<index { diff += ranges[i * 3 + 2] - ranges[i * 3 + 1] } }
        return ranges[index * 3] + diff + recoverOffset(value)
    }

    public func mapResult(_ pos: Int, assoc: Int = 1) -> MapResult { _map(pos, assoc, simple: false).1! }
    public func map(_ pos: Int, assoc: Int = 1) -> Int { _map(pos, assoc, simple: true).0 }

    private func _map(_ pos: Int, _ assoc: Int, simple: Bool) -> (Int, MapResult?) {
        var diff = 0
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var i = 0
        while i < ranges.count {
            let start = ranges[i] - (inverted ? diff : 0)
            if start > pos { break }
            let oldSize = ranges[i + oldIndex], newSize = ranges[i + newIndex], end = start + oldSize
            if pos <= end {
                let side = oldSize == 0 ? assoc : pos == start ? -1 : pos == end ? 1 : assoc
                let result = start + diff + (side < 0 ? 0 : newSize)
                if simple { return (result, nil) }
                let recover: Int? = pos == (assoc < 0 ? start : end) ? nil : makeRecover(i / 3, pos - start)
                var del = pos == start ? DEL_AFTER : pos == end ? DEL_BEFORE : DEL_ACROSS
                if assoc < 0 ? pos != start : pos != end { del |= DEL_SIDE }
                return (result, MapResult(pos: result, delInfo: del, recover: recover))
            }
            diff += newSize - oldSize
            i += 3
        }
        return simple ? (pos + diff, nil) : (pos + diff, MapResult(pos: pos + diff, delInfo: 0, recover: nil))
    }

    func touches(_ pos: Int, _ recover: Int) -> Bool {
        var diff = 0
        let index = recoverIndex(recover)
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var i = 0
        while i < ranges.count {
            let start = ranges[i] - (inverted ? diff : 0)
            if start > pos { break }
            let oldSize = ranges[i + oldIndex], end = start + oldSize
            if pos <= end && i == index * 3 { return true }
            diff += ranges[i + newIndex] - oldSize
            i += 3
        }
        return false
    }

    /// Calls `f` with (oldStart, oldEnd, newStart, newEnd) for each changed range.
    public func forEach(_ f: (Int, Int, Int, Int) -> Void) {
        let oldIndex = inverted ? 2 : 1, newIndex = inverted ? 1 : 2
        var i = 0, diff = 0
        while i < ranges.count {
            let start = ranges[i], oldStart = start - (inverted ? diff : 0), newStart = start + (inverted ? 0 : diff)
            let oldSize = ranges[i + oldIndex], newSize = ranges[i + newIndex]
            f(oldStart, oldStart + oldSize, newStart, newStart + newSize)
            diff += newSize - oldSize
            i += 3
        }
    }

    public func invert() -> StepMap { StepMap(ranges, inverted: !inverted) }

    public var description: String {
        (inverted ? "-" : "") + "[" + ranges.map(String.init).joined(separator: ",") + "]"
    }

    public static func offset(_ n: Int) -> StepMap {
        n == 0 ? .empty : StepMap(n < 0 ? [0, -n, 0] : [0, 0, n])
    }
}

/// A mapping represents a pipeline of zero or more step maps.
public final class Mapping: Mappable {
    public private(set) var maps: [StepMap]
    public private(set) var mirror: [Int]?
    public var from: Int
    public var to: Int

    public init(_ maps: [StepMap] = [], mirror: [Int]? = nil, from: Int = 0, to: Int? = nil) {
        self.maps = maps
        self.mirror = mirror
        self.from = from
        self.to = to ?? maps.count
    }

    public func slice(_ from: Int = 0, _ to: Int? = nil) -> Mapping {
        Mapping(maps, mirror: mirror, from: from, to: to ?? maps.count)
    }

    public func appendMap(_ map: StepMap, mirrors: Int? = nil) {
        maps.append(map)
        to = maps.count
        if let mirrors { setMirror(maps.count - 1, mirrors) }
    }

    public func appendMapping(_ mapping: Mapping) {
        let startSize = maps.count
        for i in 0..<mapping.maps.count {
            let mirr = mapping.getMirror(i)
            appendMap(mapping.maps[i], mirrors: mirr != nil && mirr! < i ? startSize + mirr! : nil)
        }
    }

    public func getMirror(_ n: Int) -> Int? {
        guard let mirror else { return nil }
        for i in 0..<mirror.count where mirror[i] == n { return mirror[i + (i % 2 == 1 ? -1 : 1)] }
        return nil
    }

    public func setMirror(_ n: Int, _ m: Int) {
        if mirror == nil { mirror = [] }
        mirror!.append(contentsOf: [n, m])
    }

    public func appendMappingInverted(_ mapping: Mapping) {
        let totalSize = maps.count + mapping.maps.count
        var i = mapping.maps.count - 1
        while i >= 0 {
            let mirr = mapping.getMirror(i)
            appendMap(mapping.maps[i].invert(), mirrors: mirr != nil && mirr! > i ? totalSize - mirr! - 1 : nil)
            i -= 1
        }
    }

    public func invert() -> Mapping {
        let inverse = Mapping()
        inverse.appendMappingInverted(self)
        return inverse
    }

    public func map(_ pos: Int, assoc: Int = 1) -> Int {
        if mirror != nil { return _map(pos, assoc, simple: true).pos }
        var pos = pos
        for i in from..<Swift.max(from, to) { pos = maps[i].map(pos, assoc: assoc) }
        return pos
    }

    public func mapResult(_ pos: Int, assoc: Int = 1) -> MapResult { _map(pos, assoc, simple: false) }

    private func _map(_ pos: Int, _ assoc: Int, simple: Bool) -> MapResult {
        var delInfo = 0
        var pos = pos
        var i = from
        while i < to {
            let map = maps[i], result = map.mapResult(pos, assoc: assoc)
            if let recover = result.recover, let corr = getMirror(i), corr > i, corr < to {
                i = corr
                pos = maps[corr].recover(recover)
                i += 1
                continue
            }
            delInfo |= result.delInfo
            pos = result.pos
            i += 1
        }
        return MapResult(pos: pos, delInfo: delInfo, recover: nil)
    }
}
