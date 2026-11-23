import XCTest
import PMModel
import PMOracle

/// Returns a description of the first difference between two JSON values, or nil.
func jsonDiff(_ a: JSONValue, _ b: JSONValue, path: String = "$") -> String? {
    switch (a, b) {
    case (.object(let x), .object(let y)):
        for k in Set(x.keys).union(y.keys).sorted() {
            guard let xv = x[k] else { return "\(path).\(k): missing in Swift, JS has \(y[k]!)" }
            guard let yv = y[k] else { return "\(path).\(k): Swift has \(xv), missing in JS" }
            if let d = jsonDiff(xv, yv, path: "\(path).\(k)") { return d }
        }
        return nil
    case (.array(let x), .array(let y)):
        for i in 0..<min(x.count, y.count) {
            if let d = jsonDiff(x[i], y[i], path: "\(path)[\(i)]") { return d }
        }
        return x.count == y.count ? nil : "\(path): Swift count \(x.count) vs JS \(y.count)"
    default:
        return a == b ? nil : "\(path): Swift \(a) vs JS \(b)"
    }
}

/// Asserts Swift result `swift` equals JS result `js`.
func assertParity(_ swift: JSONValue, _ js: JSONValue, _ context: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    if let d = jsonDiff(swift, js) {
        XCTFail("\(context()) parity mismatch: \(d)", file: file, line: line)
    }
}

extension JSONValue {
    static func int(_ i: Int) -> JSONValue { .number(Double(i)) }
    static func opt(_ v: JSONValue?) -> JSONValue { v ?? .null }
}

/// Count of random cases; override with env PM_FUZZ_SCALE (multiplier).
func fuzzCount(_ base: Int) -> Int {
    let scale = ProcessInfo.processInfo.environment["PM_FUZZ_SCALE"].flatMap(Double.init) ?? 1
    return Swift.max(1, Int(Double(base) * scale))
}

enum Schemas {
    static let basicJSON: JSONValue = try! Fixtures.json("schemas/basic.json")
    static let basic: Schema = try! Schema(json: basicJSON)
    static let tiptapJSON: JSONValue = try! Fixtures.json("schemas/tiptap.json")
    static let tiptap: Schema = try! Schema(json: tiptapJSON)
}
