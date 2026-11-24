import Foundation

/// The part of an HTTP response the SDK needs.
public struct StrybokHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Performs the SDK's HTTP requests. Replace it to test without a network.
///
/// Throw for transport failures (they are reported as ``StrybokError/network(url:underlying:)``
/// and retried). The SDK enforces its own timeout and cancels the calling task when it
/// expires, so implementations should honour task cancellation.
public protocol StrybokTransport: Sendable {
    func send(_ request: URLRequest) async throws -> StrybokHTTPResponse
}

/// ``StrybokTransport`` backed by `URLSession`.
public struct URLSessionTransport: StrybokTransport {
    private let session: URLSession

    /// Uses the given session, or a private ephemeral one (no cookies, no disk cache).
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func send(_ request: URLRequest) async throws -> StrybokHTTPResponse {
        let task = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = session.dataTask(with: request) { data, response, error in
                    if let response = response as? HTTPURLResponse {
                        continuation.resume(
                            returning: StrybokHTTPResponse(
                                statusCode: response.statusCode, body: data ?? Data()))
                    } else {
                        continuation.resume(throwing: error ?? URLError(.badServerResponse))
                    }
                }
                task.set(dataTask)
                dataTask.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Holds the running data task so a cancelled Swift task can cancel it.
private final class TaskBox: Sendable {
    private let state = Locked<(task: URLSessionTask?, cancelled: Bool)>((nil, false))

    func set(_ task: URLSessionTask) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
