// Sources/InAppDriver/ControlServer.swift
#if DEBUG
import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "InAppDriver", category: "control-server")

/// Debug-only HTTP endpoint for reading and driving the app's screen.
///
/// Binds to **loopback (127.0.0.1) only**, so it is reachable exclusively through a USB port-forward
/// (`iproxy 8081 8081`) on a real device, or directly on the Simulator. It is invisible on Wi-Fi and
/// never triggers the iOS Local Network permission prompt. Loopback is still shared with other apps
/// on the same device — keep this to debug builds on test devices.
///
/// Routes (coordinates are screen points):
/// - `GET  /status`                       → `{"ok":true,"ui":true|false}` (`ui` is false off UIKit)
/// - `GET  /ui`                           → on-screen elements with text and frames (JSON)
/// - `POST /ui/tap?x=&y=`                 → activate the element under the point
/// - `POST /ui/swipe?x1=&y1=&x2=&y2=`     → scroll by the drag distance
/// - `POST /ui/type`                      → insert the request body into the focused text input
/// - `GET  /ui/screenshot`                → PNG of the app's windows
///
/// A deliberately small HTTP/1.1 server: one request per connection, `Content-Length` bodies only.
final class ControlServer: @unchecked Sendable {
    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: Data

        static func json(_ status: Int, _ object: [String: Any]) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json", body: data)
        }
    }

    private let port: Int
    private var listener: NWListener?
    /// Network events and request parsing.
    private let networkQueue = DispatchQueue(label: "inappdriver.network")
    /// Routing — may block (bounded) waiting for the main thread, so it stays off the network queue.
    private let workQueue = DispatchQueue(label: "inappdriver.work")
    private let mainHop = MainHop()

    init(port: Int) {
        self.port = port
    }

    /// Binds and waits until the listener is ready, so a caller can use the port right after.
    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw StartError(description: "invalid port \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only — never bind a routable address.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = String(describing: error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: networkQueue)

        guard ready.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw StartError(description: "listener did not become ready on port \(port)")
        }
        if let failure {
            listener.cancel()
            throw StartError(description: failure)
        }
        listener.stateUpdateHandler = nil
        mainHop.reopen()
        self.listener = listener
    }

    func stop() {
        // Release requests waiting for the main thread first: stop() is usually called on it.
        mainHop.cancelAll()
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Request(parsing: buffer) {
                self.workQueue.async {
                    let response = self.route(request)
                    self.send(response, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > 1024 * 1024 {
                connection.cancel() // malformed, oversized, or closed before a full request arrived
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 422: reason = "Unprocessable Entity"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var message = Data("""
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.body.count)\r
        Connection: close\r
        \r

        """.utf8)
        message.append(response.body)
        connection.send(content: message, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    func route(_ request: Request) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            #if canImport(UIKit) && !os(watchOS)
            return .json(200, ["ok": true, "ui": true])
            #else
            return .json(200, ["ok": true, "ui": false])
            #endif
        default:
            #if canImport(UIKit) && !os(watchOS)
            if request.path == "/ui" || request.path.hasPrefix("/ui/") {
                return routeUI(request)
            }
            #endif
            return Response(
                status: 404, contentType: "text/plain",
                body: Data("no route: \(request.method) \(request.path)".utf8)
            )
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    private func routeUI(_ request: Request) -> Response {
        func number(_ name: String) -> Double? { request.query[name].flatMap(Double.init) }
        let busy = Response.json(503, ["error": "main thread did not respond (busy, or InAppDriver is stopping)"])

        /// Runs a UI action on the main thread and maps its outcome to a response.
        func act(_ work: @escaping @MainActor () throws -> String) -> Response {
            let outcome = mainHop.run { () -> Result<String, Error> in
                do { return .success(try work()) } catch { return .failure(error) }
            }
            switch outcome {
            case .none:
                return busy
            case .success(let done)?:
                return .json(200, ["done": done])
            case .failure(let error)?:
                let message = (error as? ScreenControl.Failure)?.message ?? String(describing: error)
                return .json(422, ["error": message])
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/ui"):
            guard let tree = mainHop.run({ ScreenControl.dump() }) else { return busy }
            return Response(status: 200, contentType: "application/json", body: Data(tree.utf8))

        case ("POST", "/ui/tap"):
            guard let x = number("x"), let y = number("y") else {
                return .json(400, ["error": "x and y are required"])
            }
            return act { try ScreenControl.tap(x: x, y: y) }

        case ("POST", "/ui/swipe"):
            guard let x1 = number("x1"), let y1 = number("y1"), let x2 = number("x2"), let y2 = number("y2") else {
                return .json(400, ["error": "x1, y1, x2 and y2 are required"])
            }
            return act { try ScreenControl.swipe(x1: x1, y1: y1, x2: x2, y2: y2) }

        case ("POST", "/ui/type"):
            let text = String(decoding: request.body, as: UTF8.self)
            return act { try ScreenControl.type(text) }

        case ("GET", "/ui/screenshot"):
            guard let png = mainHop.run({ ScreenControl.screenshotPNG() }) ?? nil else {
                return .json(503, ["error": "could not render the screen"])
            }
            return Response(status: 200, contentType: "image/png", body: png)

        default:
            return Response(
                status: 404, contentType: "text/plain",
                body: Data("no route: \(request.method) \(request.path)".utf8)
            )
        }
    }
    #endif
}

/// One parsed HTTP request. `init(parsing:)` returns nil until the buffer holds the complete
/// header block and `Content-Length` bytes of body.
struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        method = String(requestLine[0]).uppercased()
        path = components?.path ?? target
        query = Dictionary(
            (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, last in last }
        )
        body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
    }
}
#endif
