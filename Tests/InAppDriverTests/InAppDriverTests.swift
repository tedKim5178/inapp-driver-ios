// Tests/InAppDriverTests/InAppDriverTests.swift
#if DEBUG
import XCTest
@testable import InAppDriver

/// Drives the real loopback HTTP server end-to-end. On macOS there is no UIKit, so only the
/// transport, parsing and routing are covered here; the screen routes need a host app on iOS.
final class ControlServerTests: XCTestCase {
    private var server: ControlServer!
    private let port = 18081

    override func setUp() {
        super.setUp()
        server = ControlServer(port: port)
        try! server.start()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func test_status_reports_ok() throws {
        let (status, body) = try send("GET", "/status")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"ok\":true"))
    }

    func test_unknown_route_is_404() throws {
        let (status, body) = try send("GET", "/nope")
        XCTAssertEqual(status, 404)
        XCTAssertTrue(body.contains("no route"))
    }

    func test_server_can_restart_on_the_same_port() throws {
        server.stop()
        server = ControlServer(port: port)
        try server.start()
        let (status, _) = try send("GET", "/status")
        XCTAssertEqual(status, 200)
    }

    func test_request_parsing_waits_for_the_whole_body() {
        let head = "POST /ui/type?x=1.5&name=a%20b HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n"
        XCTAssertNil(Request(parsing: Data((head + "hel").utf8)), "body is incomplete")
        XCTAssertNil(Request(parsing: Data("POST /ui/type HTTP/1.1\r\nHost: l".utf8)), "headers are incomplete")

        let request = Request(parsing: Data((head + "hello").utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/ui/type")
        XCTAssertEqual(request?.query, ["x": "1.5", "name": "a b"])
        XCTAssertEqual(request.map { String(decoding: $0.body, as: UTF8.self) }, "hello")
    }

    private func send(_ method: String, _ path: String, body: String? = nil) throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body { request.httpBody = Data(body.utf8) }

        let done = DispatchSemaphore(value: 0)
        var status = 0
        var text = ""
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "request timed out")
        return (status, text)
    }
}

/// The main-thread bridge used by the screen routes. XCTest runs these on the main thread, so
/// "main is busy" is simply the test not yielding.
final class MainHopTests: XCTestCase {
    func test_run_returns_the_main_thread_result() {
        let hop = MainHop()
        let finished = expectation(description: "background caller returned")
        var result: Int?
        DispatchQueue.global().async {
            result = hop.run { 42 }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5) // spins the main run loop, so the work can run
        XCTAssertEqual(result, 42)
    }

    func test_cancelAll_releases_a_waiter_while_main_is_busy_and_skips_its_work() {
        let hop = MainHop()
        let returned = DispatchSemaphore(value: 0)
        var result: Int? = -1
        var workRan = false
        DispatchQueue.global().async {
            result = hop.run(timeout: 30) { workRan = true; return 1 }
            returned.signal()
        }
        Thread.sleep(forTimeInterval: 0.2) // main stays busy: the work cannot start

        let start = Date()
        hop.cancelAll()
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success, "waiter was not released")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(result)

        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // let the queued task reach main
        XCTAssertFalse(workRan, "cancelled work must not run late")
    }

    func test_closed_hop_refuses_work_until_reopened() {
        let hop = MainHop()
        hop.cancelAll()
        let refused = DispatchSemaphore(value: 0)
        var first: Int? = -1
        DispatchQueue.global().async {
            first = hop.run { 1 }
            refused.signal()
        }
        XCTAssertEqual(refused.wait(timeout: .now() + 2), .success)
        XCTAssertNil(first)

        hop.reopen()
        let finished = expectation(description: "ran after reopen")
        var second: Int?
        DispatchQueue.global().async {
            second = hop.run { 2 }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(second, 2)
    }
}

final class InAppDriverEntryTests: XCTestCase {
    func test_start_and_stop_toggle_isRunning() {
        InAppDriver.start(port: 18082)
        XCTAssertTrue(InAppDriver.isRunning)
        InAppDriver.start(port: 18082) // second call is a no-op
        XCTAssertTrue(InAppDriver.isRunning)
        InAppDriver.stop()
        XCTAssertFalse(InAppDriver.isRunning)
    }
}
#endif
