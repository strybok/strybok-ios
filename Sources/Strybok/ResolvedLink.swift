import Foundation

/// A link resolved by the Strybok API.
///
/// `routePath` and `payload` are plain data chosen by whoever created the link.
/// Treat them like any other untrusted input: map them onto routes your app
/// already knows, never execute them.
public struct ResolvedLink: Sendable, Hashable {
    /// The full URL that opened the app, as received (including query and fragment).
    public let url: URL
    public let linkId: String
    public let appId: String

    /// In-app route, always starting with a single `/` (for example `/invite/abc123`).
    public let routePath: String

    /// Decoded JSON object attached to the link; empty when none was set.
    public let payload: [String: JSONValue]

    public init(
        url: URL,
        linkId: String,
        appId: String,
        routePath: String,
        payload: [String: JSONValue] = [:]
    ) {
        self.url = url
        self.linkId = linkId
        self.appId = appId
        self.routePath = routePath
        self.payload = payload
    }
}

extension ResolvedLink: CustomStringConvertible {
    public var description: String { "ResolvedLink(\(routePath), linkId: \(linkId))" }
}
