import Foundation
import JavaScriptCore
import PMModel

/// Loads the bundled JS ProseMirror (oracle/dist/oracle.js) into JavaScriptCore
/// and exposes its harness handlers. Every call is JSON in, JSON out.
public final class Oracle {
    public struct JSError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let packageRoot: URL = {
        // Sources/PMOracle/Oracle.swift -> package root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()

    nonisolated(unsafe) public static let shared = Oracle()

    private let context: JSContext
    private let callFn: JSValue

    public init() {
        let url = Oracle.packageRoot.appendingPathComponent("oracle/dist/oracle.js")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing \(url.path). Run `npm install && npm run build` in oracle/.")
        }
        let ctx = JSContext()!
        var loadError: String?
        ctx.exceptionHandler = { _, exc in loadError = exc?.toString() }
        ctx.evaluateScript(source, withSourceURL: url)
        if let loadError { fatalError("Oracle failed to load: \(loadError)") }
        context = ctx
        callFn = ctx.objectForKeyedSubscript("PMOracle")!.objectForKeyedSubscript("call")!
    }

    /// Calls a harness handler. Returns `.success(result)` or `.failure` with the JS error message.
    public func call(_ name: String, _ args: JSONValue = .null) -> Result<JSONValue, JSError> {
        let out = callFn.call(withArguments: [name, args.serialized()])!.toString()!
        guard let parsed = try? JSONValue.parse(out) else { return .failure(JSError(description: "unparseable: \(out)")) }
        if let err = parsed["error"] { return .failure(JSError(description: err.stringValue ?? "\(err)")) }
        return .success(parsed["ok"] ?? .null)
    }

    /// Like `call`, but traps on JS errors. For handlers that are expected to succeed.
    public func value(_ name: String, _ args: JSONValue = .null) throws -> JSONValue {
        try call(name, args).get()
    }
}

/// Fixtures helper.
public enum Fixtures {
    public static func url(_ path: String) -> URL { Oracle.packageRoot.appendingPathComponent("fixtures/\(path)") }

    public static func json(_ path: String) throws -> JSONValue {
        try JSONValue.parse(String(contentsOf: url(path), encoding: .utf8))
    }
}
