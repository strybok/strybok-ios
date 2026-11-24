import Foundation

/// Every error reported by the SDK. Each case carries the URL that was being handled.
public enum StrybokError: Error, Sendable {
    /// The URL is not a Strybok link of this app: wrong scheme, a host outside
    /// `allowedHosts`, credentials, a custom port, or a path that is not a single slug.
    /// Thrown by ``Strybok/resolve(_:)`` before any network call.
    case unsupportedLink(url: URL)

    /// The service does not know this link, or it is disabled or expired (HTTP 404).
    case linkNotFound(url: URL)

    /// The request could not be completed (offline, DNS, connection reset) after all retries.
    case network(url: URL, underlying: (any Error)?)

    /// The service did not answer in time, after all retries.
    case timeout(url: URL)

    /// The service answered with an unexpected status code or a malformed body.
    /// `statusCode` is 200 for a malformed success response.
    case server(url: URL, statusCode: Int)

    /// The work was abandoned: ``Strybok/stop()`` was called or the calling task was
    /// cancelled. Never passed to `onError`.
    case cancelled(url: URL)

    /// The link that was being handled.
    public var url: URL {
        switch self {
        case .unsupportedLink(let url), .linkNotFound(let url), .timeout(let url),
            .cancelled(let url):
            return url
        case .network(let url, _), .server(let url, _):
            return url
        }
    }
}

extension StrybokError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedLink: return "Not a link for this app"
        case .linkNotFound: return "No active link matches this URL"
        case .network: return "Network error"
        case .timeout: return "The resolve request timed out"
        case .server(_, let statusCode): return "Unexpected response (status \(statusCode))"
        case .cancelled: return "Resolving was cancelled"
        }
    }
}
