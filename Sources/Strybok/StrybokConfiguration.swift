import Foundation

/// Settings of a ``Strybok`` instance.
public struct StrybokConfiguration: Sendable {
    /// Base URL of the Strybok API, e.g. `https://api.strybok.com`. A path prefix is preserved.
    public var apiBaseURL: URL

    /// Link hostnames of this app, compared lower-case. Links on any other host are ignored.
    public var allowedHosts: Set<String>

    /// Seconds allowed for a single resolve attempt.
    public var timeout: TimeInterval

    /// Extra attempts after a timeout, network error or 5xx. Resolving is an idempotent
    /// GET, so retrying is safe. `404` is never retried.
    public var maxRetries: Int

    /// Seconds to pause before the first retry; doubles for each further retry.
    public var retryDelay: TimeInterval

    /// An identical URL received again within this many seconds is treated as a
    /// duplicate delivery of the same tap and dropped.
    public var dedupeWindow: TimeInterval

    /// Whether to send a best-effort `app_open` event after a link was resolved.
    public var reportAppOpens: Bool

    /// Receives errors for links of this app that arrived from the OS but could not be
    /// resolved. URLs that are simply not ours are ignored without an error.
    /// Called on an arbitrary thread.
    public var onError: (@Sendable (StrybokError) -> Void)?

    /// Optional extra source of URLs, mainly for tests. Apps forward URLs with
    /// ``Strybok/handle(_:)`` instead.
    public var linkSource: (any LinkSource)?

    /// HTTP transport; `URLSession` by default.
    public var transport: any StrybokTransport

    /// Clock used for duplicate detection; replaceable in the SDK's own tests.
    var now: @Sendable () -> Date = { Date() }

    public init(
        apiBaseURL: URL,
        allowedHosts: Set<String>,
        timeout: TimeInterval = 5,
        maxRetries: Int = 2,
        retryDelay: TimeInterval = 0.4,
        dedupeWindow: TimeInterval = 2,
        reportAppOpens: Bool = true,
        onError: (@Sendable (StrybokError) -> Void)? = nil,
        linkSource: (any LinkSource)? = nil,
        transport: (any StrybokTransport)? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.allowedHosts = allowedHosts
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.dedupeWindow = dedupeWindow
        self.reportAppOpens = reportAppOpens
        self.onError = onError
        self.linkSource = linkSource
        self.transport = transport ?? URLSessionTransport()
    }
}
