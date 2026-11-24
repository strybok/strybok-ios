import Foundation

enum DeadlineOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error)
    case timedOut
    case cancelled
}

/// Runs `operation` and returns as soon as it finishes, `seconds` have passed, or the
/// calling task is cancelled, whichever comes first.
///
/// Unlike a task group this does not wait for `operation` to honour cancellation, so a
/// transport that never answers cannot hold the caller forever.
func withDeadline<Value: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> Value
) async -> DeadlineOutcome<Value> {
    let gate = Gate<DeadlineOutcome<Value>>()
    let work = Task {
        do {
            gate.resolve(.success(try await operation()))
        } catch {
            gate.resolve(.failure(error))
        }
    }
    let timer = Task {
        do {
            try await Task.sleep(nanoseconds: nanoseconds(seconds))
            gate.resolve(.timedOut)
        } catch {
            // Cancelled: the race is already decided.
        }
    }
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { gate.wait($0) }
    } onCancel: {
        gate.resolve(.cancelled)
    }
    work.cancel()
    timer.cancel()
    return outcome
}

func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }
    let value = seconds * 1_000_000_000
    return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
}

/// Hands the first resolved value to a single waiter; later values are ignored.
private final class Gate<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }

    private let state = Locked(State())

    func resolve(_ value: Value) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func wait(_ continuation: CheckedContinuation<Value, Never>) {
        let ready = state.withLock { state -> Value? in
            if state.value == nil { state.waiter = continuation }
            return state.value
        }
        if let ready { continuation.resume(returning: ready) }
    }
}
