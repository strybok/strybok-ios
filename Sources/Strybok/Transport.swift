import Foundation

/// The part of an HTTP response the SDK needs.
public struct StrybokHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    /// Response headers. The SDK reads only `Retry-After`; a custom transport that
    /// leaves them out loses nothing else.
    public var headers: [String: String]

    public init(statusCode: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    /// Value of a header, whatever the capitalisation of its name.
    public func value(forHeader name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
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
                        var headers: [String: String] = [:]
                        for (name, value) in response.allHeaderFields {
                            if let name = name as? String, let value = value as? String {
                                headers[name] = value
                            }
                        }
                        continuation.resume(
                            returning: StrybokHTTPResponse(
                                statusCode: response.statusCode, body: data ?? Data(),
                                headers: headers))
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
