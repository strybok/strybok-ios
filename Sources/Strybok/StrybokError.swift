import Foundation

/// Every error reported by the SDK.
///
/// Errors about an incoming link carry the URL that was being handled. Errors of
/// ``Strybok/createLink(routePath:payload:title:description:imageURL:)`` have no such
/// URL: their `url` is `nil`.
public enum StrybokError: Error, Sendable {
    /// The URL is not a Strybok link of this app: wrong scheme, a host outside
    /// `allowedHosts`, credentials, a custom port, or a path that is not a single slug.
    /// Thrown by ``Strybok/resolve(_:)`` before any network call.
    case unsupportedLink(url: URL)

    /// The service does not know this link, or it is disabled or expired (HTTP 404).
    case linkNotFound(url: URL)

    /// The request could not be completed (offline, DNS, connection reset) after all retries.
    case network(url: URL?, underlying: (any Error)?)

    /// The service did not answer in time, after all retries.
    case timeout(url: URL?)

    /// The service answered with an unexpected status code or a malformed body.
    /// `statusCode` is the success status (200 or 201) for a malformed success response.
    case server(url: URL?, statusCode: Int)

    /// The work was abandoned: ``Strybok/stop()`` was called or the calling task was
    /// cancelled. Never passed to `onError`.
    case cancelled(url: URL?)

    /// `createLink` only: no `clientKey` is configured (thrown before any network call),
    /// or the service refused the key (HTTP 401) because it is wrong, was replaced, or
    /// the owner switched link creation off. The service does not say which. Retrying
    /// does not help.
    case unauthorized

    /// `createLink` only: the route is not covered by the route patterns listed for the
    /// application in the dashboard (HTTP 403). Retrying does not help.
    case routeNotAllowed(routePath: String)

    /// `createLink` only: too many requests from this device's address or for this app,
    /// or the app's daily limit of new links is reached (HTTP 429). Never retried
    /// automatically. `retryAfter` is the number of seconds from the `Retry-After`
    /// header, `nil` when the service did not say.
    case rateLimited(retryAfter: TimeInterval?)

    /// `createLink` only: the arguments were rejected, either before sending or by the
    /// service (HTTP 400, 413 or 422). `issues` is what the service found wrong, field
    /// by field; empty when it did not say or when the call was rejected before sending.
    case validation(message: String, issues: [StrybokValidationIssue])

    /// `createLink` only: the owner of the application only accepts links from apps that
    /// passed attestation, and this request carried no proof (HTTP 401
    /// `ATTESTATION_REQUIRED`): `attestation` is switched off in the configuration, or
    /// this device or build cannot attest (simulator, iOS below 14, an extension, a
    /// build without the App Attest capability). Retrying does not help; on such a
    /// device tell the user that sharing is not available rather than show an error.
    case attestationRequired

    /// `createLink` only: the service refused the attestation token, and a fresh one as
    /// well (HTTP 401 `ATTESTATION_INVALID` twice in a row), or no fresh one could be
    /// obtained. `reason` is the service's reason (`expired`, `invalid` or `exhausted`),
    /// when it gave one. Retrying does not help.
    case attestationFailed(reason: String?)

    /// The link that was being handled; `nil` for errors of `createLink`.
    public var url: URL? {
        switch self {
        case .unsupportedLink(let url), .linkNotFound(let url):
            return url
        case .timeout(let url), .cancelled(let url):
            return url
        case .network(let url, _), .server(let url, _):
            return url
        case .unauthorized, .routeNotAllowed, .rateLimited, .validation:
            return nil
        case .attestationRequired, .attestationFailed:
            return nil
        }
    }
}

/// One problem reported by the service for a `createLink` call.
public struct StrybokValidationIssue: Sendable, Hashable {
    /// The field concerned, for example `title` or `payload`; empty when the problem is
    /// not about one field.
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

extension StrybokError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedLink: return "Not a link for this app"
        case .linkNotFound: return "No active link matches this URL"
        case .network: return "Network error"
        case .timeout: return "The request timed out"
        case .server(_, let statusCode): return "Unexpected response (status \(statusCode))"
        case .cancelled: return "The request was cancelled"
        case .unauthorized: return "The client key is missing or was not accepted"
        case .routeNotAllowed: return "This route is not allowed for links created from the app"
        case .rateLimited: return "Too many requests"
        case .validation(let message, _): return message
        case .attestationRequired: return "This application only accepts links from attested apps"
        case .attestationFailed: return "The attestation was not accepted"
        }
    }
}
