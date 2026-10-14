// Sources/InAppDriver/InAppDriver.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "InAppDriver", category: "setup")

/// Entry point for InAppDriver — a debug-only HTTP endpoint inside the app that lets a tool on the Mac
/// read the app's screen and drive it (tap, scroll, type, screenshot) on a **real device**, with no
/// UI-test runner to install or sign.
///
/// In a **debug** build, call `start()` once (e.g. from your AppDelegate):
///
/// ```swift
/// #if DEBUG
/// InAppDriver.start() // loopback 127.0.0.1:8081 — reach it with `iproxy 8081 8081`
/// #endif
/// ```
///
/// Everything here compiles to a no-op in release builds, so an unguarded call is harmless — but
/// keep the `#if DEBUG` so the intent is visible at the call site.
public enum InAppDriver {
    public static let defaultPort = 8081

    #if DEBUG
    private static let lock = NSLock()
    private static var server: ControlServer?
    #endif

    /// Starts the control server on loopback. Safe to call repeatedly; a second call while running
    /// does nothing.
    public static func start(port: Int = defaultPort) {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }
        let newServer = ControlServer(port: port)
        do {
            try newServer.start()
            server = newServer
            logger.info("control server on :\(port, privacy: .public)")
        } catch {
            logger.error("control server failed to start: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    /// Stops the control server and releases any request still waiting for the main thread.
    /// `start()` can be called again afterwards.
    public static func stop() {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        server?.stop()
        server = nil
        #endif
    }

    /// Whether the control server is running (always `false` in release builds).
    public static var isRunning: Bool {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        return server != nil
        #else
        return false
        #endif
    }
}
