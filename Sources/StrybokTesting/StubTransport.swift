import Foundation
import Strybok

/// `StrybokTransport` that answers from a closure and records every request.
///
/// ```swift
/// let transport = StubTransport { _ in
///     .json(#"{"linkId":"l1","appId":"a1","routePath":"/invite/abc"}"#)
/// }
/// ```
public final class StubTransport: StrybokTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> StrybokHTTPResponse

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Every request received so far, in order.
    public var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public func send(_ request: URLRequest) async throws -> StrybokHTTPResponse {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }
}

extension StrybokHTTPResponse {
    /// A response with a UTF-8 JSON body.
    public static func json(
        _ body: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> StrybokHTTPResponse {
        StrybokHTTPResponse(statusCode: statusCode, body: Data(body.utf8), headers: headers)
    }
}
