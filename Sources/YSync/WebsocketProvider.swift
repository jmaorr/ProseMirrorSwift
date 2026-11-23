import Foundation

/// Syncs a `YDocument` with a y-websocket server (the protocol y-partyserver
/// also speaks): sync step 1/2 on connect, then
/// incremental updates both ways. Awareness (cursors, presence) is not sent;
/// incoming awareness messages are ignored. Callbacks arrive on the main queue.
public final class YWebsocketProvider: NSObject, URLSessionWebSocketDelegate {
    public enum Status: Equatable { case disconnected, connecting, connected, synced }

    /// Origin of updates applied from the server, so they aren't echoed back.
    public static let origin = "y-websocket"

    /// Used on the next (re)connect, so a short-lived auth token in the query can be refreshed.
    public var url: URL
    public let doc: YDocument
    public private(set) var status: Status = .disconnected { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?
    /// After updates from the server changed the document.
    public var onRemoteUpdate: (() -> Void)?
    /// The server closed the socket with this code (e.g. 4001 for an expired token).
    public var onClose: ((Int) -> Void)?

    /// Created on connect and invalidated on disconnect. URLSession retains its delegate until
    /// it is invalidated, so the session's delegate is a weak proxy: a provider the app drops
    /// is freed (and its session invalidated) even if `disconnect()` was never called.
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var observer: Int?
    private var shouldConnect = false
    /// Seconds before the next reconnect; doubles per failure up to 30, reset once synced.
    private var backoff: TimeInterval = 1
    /// Set while applying a server message if it changed the document.
    private var serverChangedDoc = false
    /// Whether `ws://` (unencrypted) URLs to hosts other than this machine are allowed.
    public let allowInsecure: Bool

    public enum ProviderError: Error, Equatable {
        /// The URL isn't `wss://` (or `https://`), and isn't `ws://` to a loopback host, and
        /// `allowInsecure` is false. An unencrypted socket would expose the document (and any
        /// auth token in the URL) to the network and let anyone on the path rewrite it.
        case insecureURL(URL)
    }

    /// - Parameter allowInsecure: allow `ws://` to any host. Without it, only `wss://` is
    ///   accepted, plus `ws://` to `localhost`, `127.0.0.1` or `::1` (a local dev server).
    public init(url: URL, doc: YDocument, allowInsecure: Bool = false) throws {
        guard Self.isPermitted(url, allowInsecure: allowInsecure) else { throw ProviderError.insecureURL(url) }
        self.url = url
        self.doc = doc
        self.allowInsecure = allowInsecure
        super.init()
        observer = doc.onUpdate { [weak self] update, origin in
            guard let self else { return }
            if origin == Self.origin { serverChangedDoc = true; return }
            guard status == .synced || status == .connected else { return }
            send(.update(update))
        }
    }

    deinit {
        if let observer { doc.removeUpdateObserver(observer) }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Whether the provider will connect to `url`: `wss`/`https` always; `ws`/`http` only to a
    /// loopback host unless `allowInsecure`; any other scheme never.
    public static func isPermitted(_ url: URL, allowInsecure: Bool) -> Bool {
        switch url.scheme?.lowercased() {
        case "wss", "https": return true
        case "ws", "http":
            if allowInsecure { return true }
            guard var host = url.host?.lowercased() else { return false }
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }

    /// Connects (or keeps reconnecting) to `url`. Does nothing if `url` was changed to one
    /// `isPermitted` refuses.
    public func connect() {
        guard Self.isPermitted(url, allowInsecure: allowInsecure) else {
            shouldConnect = false
            status = .disconnected
            return
        }
        shouldConnect = true
        guard task == nil else { return }
        status = .connecting
        let session = self.session ?? URLSession(configuration: .default, delegate: WeakSocketDelegate(self), delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(task)
    }

    public func disconnect() {
        shouldConnect = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        // Releases the session's (proxy) delegate and its resources; connect() makes a new one.
        session?.invalidateAndCancel()
        session = nil
        status = .disconnected
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        status = .connected
        send(.syncStep1(doc.encodeStateVector()))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        onClose?(closeCode.rawValue)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        dropped()
    }

    private func dropped() {
        task = nil
        status = .disconnected
        guard shouldConnect else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, shouldConnect else { return }
            connect()
        }
    }

    // MARK: Messages

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(.data(let data)):
                handle(data)
                receive(task)
            case .success:
                receive(task)  // y-partyserver also sends JSON text frames for custom messages
            case .failure:
                dropped()
            }
        }
    }

    /// One binary message from the server. Malformed messages (bad lengths, undecodable
    /// state vectors or updates) are ignored. Internal for tests.
    func handle(_ data: Data) {
        var decoder = Lib0Decoder(data)
        guard let type = decoder.varUInt(), type == 0, let step = decoder.varUInt(), let payload = decoder.varBytes() else { return }
        switch step {
        case 0:
            // The server's state vector: answer with what it's missing (nothing, if it's garbage).
            guard let diff = doc.encodeDiff(payload) else { return }
            send(.syncStep2(diff))
        case 1, 2:
            serverChangedDoc = false
            // A rejected (or empty) update changes nothing; sync step 2 still means synced, as in y-websocket.
            doc.applyUpdate(payload, origin: Self.origin)
            if step == 1 { status = .synced; backoff = 1 }
            // y-partyserver sends each update back to its sender too; those change nothing.
            if serverChangedDoc { onRemoteUpdate?() }
        default:
            break
        }
    }

    enum Message {
        case syncStep1(Data), syncStep2(Data), update(Data)
    }

    private func send(_ message: Message) {
        var e = Lib0Encoder()
        e.varUInt(0)
        switch message {
        case .syncStep1(let sv): e.varUInt(0); e.varBytes(sv)
        case .syncStep2(let u): e.varUInt(1); e.varBytes(u)
        case .update(let u): e.varUInt(2); e.varBytes(u)
        }
        task?.send(.data(e.data)) { _ in }
    }
}

/// lib0 variable-length encoding, as used by the y-protocols wire format.
struct Lib0Encoder {
    var data = Data()
    mutating func varUInt(_ value: Int) {
        var v = UInt(value)
        while v > 0x7F {
            data.append(UInt8(0x80 | (v & 0x7F)))
            v >>= 7
        }
        data.append(UInt8(v))
    }
    mutating func varBytes(_ bytes: Data) {
        varUInt(bytes.count)
        data.append(bytes)
    }
}

struct Lib0Decoder {
    let data: Data
    var pos: Int
    init(_ data: Data) { self.data = data; pos = data.startIndex }

    /// lib0 `readVarUint` caps values at 2^53 - 1 (JS's safe integers); so does this, which
    /// also keeps every value well inside `Int`. Nil for larger values or a truncated number.
    static let maxSafeInteger: UInt64 = (1 << 53) - 1

    mutating func varUInt() -> Int? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while pos < data.endIndex {
            let byte = data[pos]
            pos += 1
            guard shift < 56 else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            guard result <= Self.maxSafeInteger else { return nil }
            if byte < 0x80 { return Int(result) }
            shift += 7
        }
        return nil
    }

    mutating func varBytes() -> Data? {
        // `count <= remaining`, not `pos + count <= end`: the sum could overflow.
        guard let count = varUInt(), count <= data.endIndex - pos else { return nil }
        defer { pos += count }
        return data.subdata(in: pos..<(pos + count))
    }
}

/// Forwards URLSession's delegate calls to a provider without retaining it (URLSession keeps a
/// strong reference to its delegate until invalidated).
private final class WeakSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var provider: YWebsocketProvider?
    init(_ provider: YWebsocketProvider) { self.provider = provider }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        provider?.urlSession(session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        provider?.urlSession(session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        provider?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
