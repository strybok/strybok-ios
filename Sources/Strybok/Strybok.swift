import Foundation

/// Entry point of the SDK.
///
/// Create one instance for the lifetime of the app, forward incoming URLs to it and
/// read the resolved links:
///
/// ```swift
/// let strybok = Strybok(configuration: StrybokConfiguration(
///     apiBaseURL: URL(string: "https://api.strybok.com")!,
///     allowedHosts: ["my-app.strybok.link"]
/// ))
///
/// // SceneDelegate / AppDelegate / SwiftUI `.onOpenURL`:
/// strybok.handle(url)
///
/// await strybok.start()
/// for await link in strybok.links() {
///     router.open(link.routePath, payload: link.payload)
/// }
/// ```
///
/// All methods are safe to call from any thread.
public final class Strybok: Sendable {
    /// Version reported with analytics events.
    public static let sdkVersion = "0.5.0"

    /// Platform reported with analytics events.
    static var platform: String {
        #if os(iOS)
            return "ios"
        #else
            return "unknown"
        #endif
    }

    public let configuration: StrybokConfiguration

    /// `configuration.allowedHosts`, lower-cased.
    private let allowedHosts: Set<String>
    let state = Locked(State())
    /// Seams and storage of deferred links. Creating it does no work.
    let deferred: DeferredLinkContext
    /// Only with `attestation` switched on. Creating it does no work: nothing is read,
    /// generated or sent until `createLink` asks it for a token.
    private let attestation: AttestationSession?

    public init(configuration: StrybokConfiguration) {
        self.configuration = configuration
        self.allowedHosts = Set(configuration.allowedHosts.map { $0.lowercased() })
        self.deferred = DeferredLinkContext(configuration)
        if configuration.attestation, let key = Self.usableClientKey(configuration) {
            let base = configuration.apiBaseURL
            self.attestation = AttestationSession(
                clientKey: key, configuration: configuration,
                endpoint: { Self.endpoint(base, $0) })
        } else {
            self.attestation = nil
        }
        if configuration.deferredLinks { state.withLock { $0.deferredEnabled = true } }
    }

    deinit {
        tearDown()
    }

    // MARK: - Receiving URLs

    /// Hands a URL received from the OS to the SDK. Call it from
    /// `scene(_:continue:)`, `application(_:continue:restorationHandler:)` or SwiftUI
    /// `onOpenURL`.
    ///
    /// URLs passed in before ``start()`` are kept; the first of them is treated as the
    /// link that launched the app. URLs that are not Strybok links of this app are
    /// ignored.
    ///
    /// - Returns: `true` when the URL is a Strybok link of this app, i.e. the SDK
    ///   takes care of it. It says nothing about whether resolving will succeed.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard isStrybokLink(url) else { return false }
        let running = state.withLock { state -> Bool in
            if state.stopped { return false }
            state.normalLinkAccepted = true
            if !state.started { state.preStart.append(url) }
            return state.started
        }
        if running { ingest(url) }
        return true
    }

    /// Same as ``handle(_:)`` for a browsing-web user activity (a Universal Link).
    /// Other activity types are ignored.
    @discardableResult
    public func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = userActivity.webpageURL
        else { return false }
        return handle(url)
    }

    /// Whether `url` looks like a Strybok link of this app: `https`, a host from
    /// `allowedHosts`, default port, no credentials and a single slug path — or, with
    /// ``StrybokConfiguration/parameterLinks``, a route path or a Firebase long link. Query
    /// and fragment do not matter (except the `link` parameter of a long link).
    public func isStrybokLink(_ url: URL) -> Bool {
        lookupURL(for: url) != nil
    }

    // MARK: - Lifecycle

    /// Starts handling links: subscribes to incoming URLs and resolves the one that
    /// launched the app.
    ///
    /// Returns once the launch link, if any, has been resolved (or has failed), so it
    /// is safe to `await` before showing the first screen. Calling it again waits for
    /// the same work; calling it after ``stop()`` does nothing.
    public func start() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            if state.stopped { return nil }
            if let task = state.startTask { return task }
            let buffered = state.preStart
            state.preStart = []
            state.started = true
            let task = Task { [self] in
                await runStart(buffered: buffered)
                // Everything `start()` does is done; the deferred check comes after it
                // and nothing waits for it.
                self.state.withLock { $0.startFinished = true }
                startMatchingIfDue()
            }
            state.startTask = task
            return task
        }
        await task?.value
    }

    /// Stops the SDK for good: nothing is delivered any more (including links that
    /// were still resolving), every stream returned by ``links()`` finishes, and
    /// ``resolve(_:)`` and ``createLink(routePath:payload:title:description:imageURL:)``
    /// throw ``StrybokError/cancelled(url:)``. Safe to call repeatedly.
    public func stop() {
        tearDown()
    }

    // MARK: - Delivery

    /// Resolved links, each delivered exactly once.
    ///
    /// Every call creates a new subscription that is live immediately. Links resolved
    /// while nobody was subscribed (typically the one that cold-started the app) are
    /// kept and handed to the first subscription. With several subscriptions each one
    /// sees every later link once.
    ///
    /// Iterate the stream you asked for: links handed to a stream that is never read
    /// are lost. Cancel the iterating task to unsubscribe.
    public func links() -> AsyncStream<ResolvedLink> {
        let (inner, continuation) = AsyncStream<ResolvedLink>.makeStream()
        let id = state.withLock { state -> UInt64? in
            if state.stopped { return nil }
            state.nextID += 1
            state.listeners[state.nextID] = continuation
            for entry in state.pending { continuation.yield(entry.link) }
            state.pending.removeAll()
            return state.nextID
        }
        guard let id else {
            continuation.finish()
            return inner
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.listeners[id] = nil }
        }
        // Re-check on every element so links still buffered in the stream are not
        // delivered after `stop()`.
        let iterator = IteratorBox(inner.makeAsyncIterator())
        return AsyncStream(
            unfolding: { [weak self] in
                guard let link = await iterator.next(), let self, !self.isStopped else {
                    return nil
                }
                return link
            },
            onCancel: { continuation.finish() }
        )
    }

    /// Callback flavour of ``links()``: `listener` is called once for every resolved
    /// link, in order, on an arbitrary thread (hop to the main actor before touching UI).
    ///
    /// - Returns: A token; call `cancel()` on it to stop listening. Dropping the token
    ///   keeps the listener alive until ``stop()``.
    @discardableResult
    public func addListener(
        _ listener: @escaping @Sendable (ResolvedLink) -> Void
    ) -> StrybokListenerToken {
        let stream = links()
        let token = StrybokListenerToken()
        let task = Task {
            for await link in stream {
                if token.isCancelled { break }
                listener(link)
            }
        }
        token.attach(task)
        return token
    }

    /// The link that launched the app, if it has not been delivered through
    /// ``links()`` or a listener yet. Returns it at most once and removes it from the
    /// queue, so using both APIs never navigates twice. Waits for ``start()``.
    public func initialLink() async -> ResolvedLink? {
        await start()
        return state.withLock { state -> ResolvedLink? in
            guard let id = state.launchLinkID else { return nil }
            state.launchLinkID = nil
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return nil }
            return state.pending.remove(at: index).link
        }
    }

    // MARK: - Resolving

    /// Resolves `url` through the API without delivering it to ``links()`` and
    /// without reporting an app open.
    ///
    /// Throws ``StrybokError/unsupportedLink(url:)`` before any network call when the
    /// URL is not ours, ``StrybokError/linkNotFound(url:)`` for unknown, disabled or
    /// expired links, and network/timeout/server errors otherwise.
    public func resolve(_ url: URL) async throws(StrybokError) -> ResolvedLink {
        if isStopped { throw .cancelled(url: url) }
        guard let lookup = lookupURL(for: url) else { throw .unsupportedLink(url: url) }

        var request = URLRequest(url: endpoint("/v1/public/resolve", lookup: lookup))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(request, for: url)
        switch response.statusCode {
        case 200:
            return try Self.parse(response.body, for: url)
        case 404:
            throw .linkNotFound(url: url)
        default:
            throw .server(url: url, statusCode: response.statusCode)
        }
    }

    // MARK: - Creating links

    /// Asks the service for a short link to `routePath`, a screen of this app — the
    /// "Share" button. Share the returned ``CreatedLink/url``.
    ///
    /// Needs `clientKey` in the configuration, and the route must be covered by the
    /// route patterns listed for the application in the dashboard. `payload` is a JSON
    /// object delivered with the link; `title`, `description` and `imageURL` are shown
    /// in link previews. Arguments left out are not sent. Do not put personal data in a
    /// route or payload: whoever receives the link can read them.
    ///
    /// It runs only when called: ``start()`` and incoming links never depend on it, and
    /// it works before or without ``start()``. Asking again with the same content
    /// returns the same link, so timeouts, network errors and 5xx are retried like in
    /// ``resolve(_:)``.
    ///
    /// Throws a ``StrybokError`` whose `url` is `nil`, never passed to `onError`:
    /// `.unauthorized`, `.routeNotAllowed`, `.validation`, `.attestationRequired` and
    /// `.attestationFailed` need a change in the app or the dashboard; `.rateLimited`,
    /// `.network`, `.timeout` and `.server` are temporary; `.cancelled` when the calling
    /// task was cancelled or after ``stop()``.
    ///
    /// With `attestation` switched on in the configuration, the first call (and one
    /// about every hour after that) also proves to the service that this is a genuine
    /// build of the app; see ``StrybokConfiguration/attestation``.
    public func createLink(
        routePath: String,
        payload: [String: JSONValue]? = nil,
        title: String? = nil,
        description: String? = nil,
        imageURL: URL? = nil
    ) async throws(StrybokError) -> CreatedLink {
        if isStopped { throw .cancelled(url: nil) }
        guard let key = Self.usableClientKey(configuration) else { throw .unauthorized }
        guard routePath.hasPrefix("/"), !routePath.hasPrefix("//") else {
            throw .validation(message: "routePath must start with a single \"/\"", issues: [])
        }
        // Counted like the service does (UTF-16 code units).
        guard routePath.utf16.count <= 512 else {
            throw .validation(message: "routePath must be at most 512 characters", issues: [])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoded once, so every retry sends exactly the same bytes.
        guard
            let body = try? encoder.encode(
                CreateLinkRequest(
                    routePath: routePath,
                    payload: payload,
                    title: title,
                    description: description,
                    imageUrl: imageURL?.absoluteString))
        else {
            throw .validation(message: "payload must contain only JSON values", issues: [])
        }

        var request = URLRequest(url: endpoint("/v1/public/links"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Strybok-Key")
        request.httpBody = body

        guard let attestation else {
            return try Self.createdLink(from: try await send(request, for: nil), routePath: routePath)
        }

        // Unavailable (simulator, iOS 13, no capability, service not set up): the request
        // goes out without a token and the service decides.
        let token = try await attestationToken(attestation)
        var response = try await send(request, attestedBy: token)
        if let token, response.statusCode == 401,
            let refusal = Self.attestationRefusal(response), refusal.code == "ATTESTATION_INVALID"
        {
            // The token expired, is used up or is no longer accepted: attest again and
            // send the same request once more. This is not one of the `maxRetries`.
            attestation.invalidate(token)
            guard let fresh = try await attestationToken(attestation) else {
                throw .attestationFailed(reason: refusal.reason)
            }
            response = try await send(request, attestedBy: fresh)
            if response.statusCode == 401,
                Self.attestationRefusal(response)?.code == "ATTESTATION_INVALID"
            {
                attestation.invalidate(fresh)
            }
        }
        return try Self.createdLink(from: response, routePath: routePath)
    }

    /// A session token, or `nil` when attestation is unavailable right now.
    private func attestationToken(
        _ attestation: AttestationSession
    ) async throws(StrybokError) -> String? {
        let outcome = await attestation.token()
        if isStopped || Task.isCancelled { throw .cancelled(url: nil) }
        switch outcome {
        case .token(let token): return token
        case .unavailable: return nil
        case .unauthorized: throw .unauthorized
        case .cancelled: throw .cancelled(url: nil)
        }
    }

    private func send(
        _ request: URLRequest, attestedBy token: String?
    ) async throws(StrybokError) -> StrybokHTTPResponse {
        var request = request
        if let token { request.setValue(token, forHTTPHeaderField: "X-Strybok-Attestation") }
        return try await send(request, for: nil)
    }

    /// The client key when it is configured and can be sent as a header. Anything else
    /// could not be sent, and no key the service issues looks like that.
    private static func usableClientKey(_ configuration: StrybokConfiguration) -> String? {
        guard let key = configuration.clientKey, !key.isEmpty,
            key.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return nil }
        return key
    }

    /// `error.code` and `error.details.reason` of a 401 that is about attestation.
    private static func attestationRefusal(_ response: StrybokHTTPResponse) -> ServiceError? {
        let error = ServiceError(response.body)
        guard error.code == "ATTESTATION_INVALID" || error.code == "ATTESTATION_REQUIRED" else {
            return nil
        }
        return error
    }

    /// Turns the answer of `POST /v1/public/links` into the created link or a typed error.
    private static func createdLink(
        from response: StrybokHTTPResponse, routePath: String
    ) throws(StrybokError) -> CreatedLink {
        let status = response.statusCode
        switch status {
        case 200, 201:
            guard let created = try? JSONDecoder().decode(CreateLinkResponse.self, from: response.body),
                created.url.hasPrefix("https://"),
                let url = URL(string: created.url), url.host?.isEmpty == false
            else { throw .server(url: nil, statusCode: status) }
            return CreatedLink(
                url: url, slug: created.slug, routePath: created.routePath, linkId: created.linkId)
        case 401:
            // The owner can ask for attestation; the service then says so in `error.code`.
            switch attestationRefusal(response) {
            case let refusal? where refusal.code == "ATTESTATION_REQUIRED":
                throw .attestationRequired
            case let refusal?:
                throw .attestationFailed(reason: refusal.reason)
            case nil:
                throw .unauthorized
            }
        case 403:
            throw .routeNotAllowed(routePath: routePath)
        case 429:
            let seconds = response.value(forHeader: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            throw .rateLimited(retryAfter: seconds.flatMap { $0 >= 0 ? TimeInterval($0) : nil })
        case 400, 413, 422:
            // Keep the service's explanation (`error.message`, `error.details.issues`).
            let error = (try? JSONDecoder().decode(ErrorResponse.self, from: response.body))?.error
            var message = "The request was rejected (status \(status))"
            if let text = error?.message?.stringValue, !text.isEmpty { message = text }
            let issues = (error?.details?["issues"]?.arrayValue ?? []).compactMap {
                issue -> StrybokValidationIssue? in
                guard let text = issue["message"]?.stringValue else { return nil }
                return StrybokValidationIssue(
                    path: issue["path"]?.stringValue ?? "", message: text)
            }
            throw .validation(message: message, issues: issues)
        default:
            throw .server(url: nil, statusCode: status)
        }
    }

    // MARK: - Internals

    struct State {
        var started = false
        var stopped = false
        /// URLs forwarded before `start()`.
        var preStart: [URL] = []
        var startTask: Task<Void, Never>?
        var sourceTask: Task<Void, Never>?
        /// Resolves in progress for links received while running.
        var inFlight: [UInt64: Task<Void, Never>] = [:]
        var listeners: [UInt64: AsyncStream<ResolvedLink>.Continuation] = [:]
        /// Links resolved while nobody was listening (typically the cold-start link).
        var pending: [(id: UInt64, link: ResolvedLink)] = []
        var launchLinkID: UInt64?
        var nextID: UInt64 = 0
        var lastURL: String?
        var lastURLAt: Date?

        // Deferred links (see `Strybok+Deferred.swift`).
        /// `deferredLinks` of the configuration, or switched on later.
        var deferredEnabled = false
        /// `runStart` has completed, so the matching check may begin.
        var startFinished = false
        /// A link of this app was accepted since the process started: it wins over a
        /// guessed link.
        var normalLinkAccepted = false
        /// `done` was stored by this process.
        var deferredDone = false
        /// The matching check was begun in this process (it runs at most once).
        var matchClaimed = false
        /// Matching waits for `redeemPastedLink` or `skipPastedLink`.
        var awaitingPaste = false
        /// The app said there is nothing (more) to paste.
        var pasteSkipped = false
        /// Redemptions of a pasted link that have not finished.
        var pastesInFlight = 0
        var pasteTask: Task<PastedLinkResult, Never>?
        var matchTask: Task<Void, Never>?
        /// `nil` until it is first asked for.
        var deferredStatus: DeferredLinkStatus?
        var statusListeners: [UInt64: AsyncStream<DeferredLinkStatus>.Continuation] = [:]
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    private func runStart(buffered: [URL]) async {
        var launchURLs: [URL] = []
        if let first = buffered.first, admit(first) { launchURLs.append(first) }
        for url in buffered.dropFirst() { ingest(url) }

        if let source = configuration.linkSource {
            // Subscribe first so a URL arriving during start-up is not missed. The
            // stream is drained only after the launch URL was registered, so a source
            // that replays the launch URL cannot overtake it.
            let stream = source.urls()
            if let url = await source.launchURL(), admit(url) { launchURLs.append(url) }
            let task = Task { [weak self] in
                for await url in stream { self?.ingest(url) }
            }
            let stopped = state.withLock { state -> Bool in
                if !state.stopped { state.sourceTask = task }
                return state.stopped
            }
            if stopped { task.cancel() }
        }

        for url in launchURLs { await process(url, isLaunch: true) }
    }

    /// Whether `url` should be resolved: ours, not stopped, not a duplicate delivery.
    private func admit(_ url: URL) -> Bool {
        guard isStrybokLink(url) else { return false }
        let now = configuration.now()
        let key = url.absoluteString
        return state.withLock { state -> Bool in
            if state.stopped { return false }
            state.normalLinkAccepted = true
            // The OS (or a link source) can hand over the same tap twice, e.g. as the
            // launch URL and again on the stream.
            var duplicate = false
            if state.lastURL == key, let last = state.lastURLAt {
                duplicate = now.timeIntervalSince(last) < configuration.dedupeWindow
            }
            state.lastURL = key
            state.lastURLAt = now
            return !duplicate
        }
    }

    private func ingest(_ url: URL) {
        guard admit(url) else { return }
        state.withLock { state in
            if state.stopped { return }
            state.nextID += 1
            let id = state.nextID
            state.inFlight[id] = Task { [self] in
                await process(url, isLaunch: false)
                self.state.withLock { $0.inFlight[id] = nil }
            }
        }
    }

    private func process(_ url: URL, isLaunch: Bool) async {
        do {
            let link = try await resolve(url)
            guard deliver(link, isLaunch: isLaunch) else { return }
            if configuration.reportAppOpens { reportAppOpen(for: link) }
        } catch {
            if case .cancelled = error { return }
            if !isStopped { configuration.onError?(error) }
        }
    }

    /// Hands the link to the listeners, or queues it when there are none.
    private func deliver(_ link: ResolvedLink, isLaunch: Bool) -> Bool {
        state.withLock { state -> Bool in
            if state.stopped { return false }  // Stopped while the request was in flight.
            Self.enqueue(link, isLaunch: isLaunch, in: &state)
            return true
        }
    }

    /// The exactly-once pipeline: to the listeners, or queued until one attaches.
    static func enqueue(_ link: ResolvedLink, isLaunch: Bool, in state: inout State) {
        if state.listeners.isEmpty {
            state.nextID += 1
            state.pending.append((state.nextID, link))
            if isLaunch, state.launchLinkID == nil { state.launchLinkID = state.nextID }
        } else {
            for continuation in state.listeners.values { continuation.yield(link) }
        }
    }

    private func tearDown() {
        let (tasks, listeners, pasteTask, statusListeners) = state.withLock {
            state -> (
                [Task<Void, Never>], [AsyncStream<ResolvedLink>.Continuation],
                Task<PastedLinkResult, Never>?, [AsyncStream<DeferredLinkStatus>.Continuation]
            ) in
            state.stopped = true
            let tasks =
                [state.startTask, state.sourceTask, state.matchTask].compactMap { $0 }
                + state.inFlight.values
            let listeners = Array(state.listeners.values)
            let pasteTask = state.pasteTask
            let statusListeners = Array(state.statusListeners.values)
            state.matchTask = nil
            state.pasteTask = nil
            state.statusListeners = [:]
            state.awaitingPaste = false
            state.startTask = nil
            state.sourceTask = nil
            state.inFlight = [:]
            state.listeners = [:]
            state.pending = []
            state.preStart = []
            state.launchLinkID = nil
            return (tasks, listeners, pasteTask, statusListeners)
        }
        for task in tasks { task.cancel() }
        pasteTask?.cancel()
        for listener in listeners { listener.finish() }
        for listener in statusListeners { listener.finish() }
    }

    /// What is sent to the API when `url` is a link of this app, else `nil`:
    /// `https://{lower-cased host}{path}`, followed by the campaign query
    /// (``CampaignQuery``) when the URL has one. The rest of the query and the fragment
    /// are left out: they are not needed for the lookup and may hold private data.
    ///
    /// With `parameterLinks` configured, route paths and Firebase long links are ours too, and
    /// the values of the configured payload keys are sent as well (``LinkLookup``).
    func lookupURL(for url: URL) -> String? {
        lookupURL(for: url, parameterLinks: configuration.parameterLinks)
    }

    /// Whether `url` is a link of this app by the slug rule alone, whatever the configuration
    /// says. Deferred links are always stored links, so pasted links and the URLs of
    /// deferred-link answers are checked with it.
    func isSlugLink(_ url: URL) -> Bool {
        lookupURL(for: url, parameterLinks: nil) != nil
    }

    /// ``lookupURL(for:)`` with the given option; `nil` is the slug rule of 0.4.0.
    private func lookupURL(for url: URL, parameterLinks: ParameterLinks?) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443
        else { return nil }
        // The path and the query as received: never decoded or normalised as a whole.
        return LinkLookup.make(
            host: host, path: components.percentEncodedPath, query: components.percentEncodedQuery,
            options: parameterLinks)
    }

    func endpoint(_ path: String, lookup: String? = nil) -> URL {
        Self.endpoint(configuration.apiBaseURL, path, lookup: lookup)
    }

    private static func endpoint(_ base: URL, _ path: String, lookup: String? = nil) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base.appendingPathComponent(path)
        }
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.fragment = nil
        components.percentEncodedQuery = lookup.map { lookup in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return "url=" + (lookup.addingPercentEncoding(withAllowedCharacters: allowed) ?? lookup)
        }
        return components.url ?? base.appendingPathComponent(path)
    }

    /// Sends a request with the configured timeout and retries. Returns the first answer
    /// below 500; throws the last error once the attempts are used up. `url` is the
    /// incoming link the request is about, if any.
    func send(
        _ request: URLRequest, for url: URL?
    ) async throws(StrybokError) -> StrybokHTTPResponse {
        var request = request
        request.timeoutInterval = max(configuration.timeout, 0.001)
        let transport = configuration.transport
        let attempt: @Sendable () async throws -> StrybokHTTPResponse = { [request] in
            try await transport.send(request)
        }

        var lastError = StrybokError.network(url: url, underlying: nil)
        for attemptIndex in 0...max(configuration.maxRetries, 0) {
            if attemptIndex > 0 {
                let delay = configuration.retryDelay * pow(2, Double(attemptIndex - 1))
                do {
                    try await Task.sleep(nanoseconds: nanoseconds(delay))
                } catch {
                    throw .cancelled(url: url)
                }
            }
            if isStopped { throw .cancelled(url: url) }

            switch await withDeadline(configuration.timeout, attempt) {
            case .success(let response):
                // Client errors will not improve.
                if response.statusCode < 500 { return response }
                lastError = .server(url: url, statusCode: response.statusCode)
            case .failure(let error):
                if (error as? URLError)?.code == .timedOut {
                    lastError = .timeout(url: url)
                } else {
                    lastError = .network(url: url, underlying: error)
                }
            case .timedOut:
                lastError = .timeout(url: url)
            case .cancelled:
                throw .cancelled(url: url)
            }
        }
        throw lastError
    }

    /// Body of a create-link request. Optional members that are `nil` are left out.
    private struct CreateLinkRequest: Encodable {
        var routePath: String
        var payload: [String: JSONValue]?
        var title: String?
        var description: String?
        var imageUrl: String?
    }

    private struct CreateLinkResponse: Decodable {
        var linkId: String
        var slug: String
        var routePath: String
        var url: String
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable {
            var message: JSONValue?
            var details: JSONValue?
        }
        var error: Body
    }

    private struct ResolveResponse: Decodable {
        var linkId: String
        var appId: String
        var routePath: String
        var payload: JSONValue?
        var campaign: JSONValue?
    }

    private struct AppOpenEvent: Encodable {
        var eventId: String
        var linkId: String
        var type = "app_open"
        var platform: String
        var sdkVersion: String
        /// Left out of the JSON when `nil`.
        var campaign: [String: String]?
    }

    private static func parse(_ body: Data, for url: URL) throws(StrybokError) -> ResolvedLink {
        guard let response = try? JSONDecoder().decode(ResolveResponse.self, from: body),
            response.routePath.hasPrefix("/"), !response.routePath.hasPrefix("//")
        else { throw .server(url: url, statusCode: 200) }
        return ResolvedLink(
            url: url,
            linkId: response.linkId,
            appId: response.appId,
            routePath: response.routePath,
            payload: response.payload?.objectValue ?? [:],
            campaign: LinkCampaign(json: response.campaign)
        )
    }

    /// Best effort and never awaited by delivery. This is a self-reported metric (an
    /// app can be modified), separate from server-side fallback visits.
    private func reportAppOpen(for link: ResolvedLink) {
        var request = URLRequest(url: endpoint("/v1/public/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(configuration.timeout, 0.001)
        request.httpBody = try? JSONEncoder().encode(
            AppOpenEvent(
                eventId: UUID().uuidString.lowercased(),  // UUID() is a random version 4 UUID.
                linkId: link.linkId,
                platform: Self.platform,
                sdkVersion: String(Self.sdkVersion.prefix(32)),
                // What resolve returned, never read from the URL here; left out when empty.
                campaign: link.campaign.isEmpty ? nil : link.campaign.fields))
        let transport = configuration.transport
        let timeout = configuration.timeout
        Task.detached { [request] in
            // Analytics must never affect the app: every outcome is ignored.
            _ = await withDeadline(timeout) { try await transport.send(request) }
        }
    }
}

/// Returned by ``Strybok/addListener(_:)``; cancels the listener.
public final class StrybokListenerToken: Sendable {
    private let state = Locked<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

    init() {}

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func attach(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.cancelled
        }
        if cancelNow { task.cancel() }
    }

    /// Stops the listener. A callback that is already running finishes; none starts
    /// afterwards.
    public func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// Lets the public stream pull from the internal one. Only the single consumer of the
/// public stream touches the iterator, one call at a time.
private final class IteratorBox: @unchecked Sendable {
    private var iterator: AsyncStream<ResolvedLink>.Iterator

    init(_ iterator: AsyncStream<ResolvedLink>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> ResolvedLink? {
        await iterator.next()
    }
}
