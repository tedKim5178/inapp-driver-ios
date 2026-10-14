// Sources/InAppDriver/MainHop.swift
#if DEBUG
import Foundation

/// Runs work on the main thread on behalf of a background thread that waits for the result — the
/// control server's bridge to UIKit, which is main-thread only.
///
/// The wait is bounded, and `cancelAll()` releases every waiter at once, so stopping the server never
/// has to wait for a request that is itself waiting for a busy main thread. Work that was cancelled
/// (or timed out) before it started is skipped — nothing is tapped after the fact.
final class MainHop: @unchecked Sendable {
    private final class Entry<T> {
        let done = DispatchSemaphore(value: 0)
        var started = false
        var cancelled = false
        var value: T?
    }

    private let lock = NSLock()
    private var closed = false
    private var cancellers: [ObjectIdentifier: () -> Void] = [:]

    /// Runs `work` on the main thread and returns its result, or `nil` if it did not start in time,
    /// was cancelled, or the hop is closed. Must not be called from the main thread.
    func run<T>(timeout: TimeInterval = 10, _ work: @escaping @MainActor () -> T) -> T? {
        let entry = Entry<T>()
        let id = ObjectIdentifier(entry)

        lock.lock()
        if closed {
            lock.unlock()
            return nil
        }
        // Cancelling only affects work that has not started; work already running finishes normally.
        // (The closure is always called with `lock` held.)
        cancellers[id] = {
            if !entry.started {
                entry.cancelled = true
                entry.done.signal()
            }
        }
        lock.unlock()

        Task { @MainActor in
            let shouldRun = self.locked { () -> Bool in
                if entry.cancelled { return false }
                entry.started = true
                return true
            }
            guard shouldRun else { return } // waiter already gave up — do not act late

            let value = work()

            self.locked { entry.value = value }
            entry.done.signal()
        }

        _ = entry.done.wait(timeout: .now() + timeout)

        lock.lock()
        defer { lock.unlock() }
        cancellers[id] = nil
        if entry.value == nil { entry.cancelled = true } // timed out before starting: skip it when main frees up
        return entry.value
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Releases every waiter whose work has not started and refuses new work until `reopen()`.
    func cancelAll() {
        lock.lock()
        closed = true
        let pending = cancellers.values
        cancellers.removeAll()
        for cancel in pending { cancel() }
        lock.unlock()
    }

    /// Accepts work again after `cancelAll()`.
    func reopen() {
        lock.lock()
        closed = false
        lock.unlock()
    }
}
#endif
