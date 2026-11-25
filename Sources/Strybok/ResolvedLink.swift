import Foundation

/// A link resolved by the Strybok API.
///
/// `routePath`, `payload` and `campaign` are plain data chosen by whoever created or
/// shared the link. Treat them like any other untrusted input: map them onto routes
/// your app already knows, never execute them.
public struct ResolvedLink: Sendable, Hashable {
    /// The full URL that opened the app, as received (including query and fragment).
    public let url: URL
    public let linkId: String
    public let appId: String

    /// In-app route, always starting with a single `/` (for example `/invite/abc123`).
    public let routePath: String

    /// Decoded JSON object attached to the link; empty when none was set.
    public let payload: [String: JSONValue]

    /// Campaign values of this open: the link's defaults with the `utm_*` parameters of
    /// `url` on top. Never optional; empty when there are none.
    public let campaign: LinkCampaign

    /// `true` when the link did not open the app but was restored after installation:
    /// the person pasted it (``Strybok/redeemPastedLink(_:)``) or it was guessed by
    /// probabilistic matching. `false` for every link that arrived the normal way.
    public let isDeferred: Bool

    /// `true` only for a link the service **guessed** from the network address (opt-in
    /// probabilistic matching). Check it before acting on the link: on a shared network
    /// (Wi-Fi, office, mobile carrier) the guess can be **another person's link**, so
    /// such a link must never by itself sign anyone in, accept an invitation, apply a
    /// personal discount or show personal content. Use it for harmless navigation only.
    public let isProbabilisticMatch: Bool

    public init(
        url: URL,
        linkId: String,
        appId: String,
        routePath: String,
        payload: [String: JSONValue] = [:],
        campaign: LinkCampaign = LinkCampaign(),
        isDeferred: Bool = false,
        isProbabilisticMatch: Bool = false
    ) {
        self.url = url
        self.linkId = linkId
        self.appId = appId
        self.routePath = routePath
        self.payload = payload
        self.campaign = campaign
        self.isDeferred = isDeferred
        self.isProbabilisticMatch = isProbabilisticMatch
    }
}

extension ResolvedLink: CustomStringConvertible {
    public var description: String { "ResolvedLink(\(routePath), linkId: \(linkId))" }
}
