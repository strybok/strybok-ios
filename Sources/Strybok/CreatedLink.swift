import Foundation

/// A link made by ``Strybok/createLink(routePath:payload:title:description:imageURL:)``.
public struct CreatedLink: Sendable, Hashable {
    /// The HTTPS link to share.
    public let url: URL

    /// Last part of `url`; identifies the link on its host.
    public let slug: String

    /// The in-app route the link opens.
    public let routePath: String
    public let linkId: String

    public init(url: URL, slug: String, routePath: String, linkId: String) {
        self.url = url
        self.slug = slug
        self.routePath = routePath
        self.linkId = linkId
    }
}

extension CreatedLink: CustomStringConvertible {
    public var description: String { "CreatedLink(\(url.absoluteString), linkId: \(linkId))" }
}
