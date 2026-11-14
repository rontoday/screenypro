import Foundation

/// FIFO async mutex. Unlike a plain actor it is not reentrant across `await`:
/// the whole body of `withLock` runs before the next caller starts.
/// Never call `withLock` on the same gate from inside a body (deadlock).
actor AsyncSerialGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Ownership was handed over by `release()`; `isLocked` stays true.
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    nonisolated func withLock<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    nonisolated func withLock(_ body: () async -> Void) async {
        await acquire()
        await body()
        await release()
    }
}

extension NSLock {
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
