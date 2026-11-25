import Foundation

/// Deferred links on iOS (optional, off by default): restoring a link that was tapped
/// before the app was installed. The App Store passes nothing from a link to a newly
/// installed app, so there are two flows, each with a cost:
///
/// - **Pasted link** (`deferredLinks`): the person copied the link on a page before the
///   App Store and pastes it in the app; the app hands the string to
///   ``redeemPastedLink(_:)``. Exact, but it needs two deliberate actions.
/// - **Probabilistic matching** (`deferredLinks` and `allowProbabilisticMatching`): the
///   service guesses from the network address. Forbidden by Apple's rules and sometimes
///   wrong; see ``StrybokConfiguration/allowProbabilisticMatching``.
///
/// Nothing here is on the path of ``start()``, nothing is reported to `onError`, and
/// ``initialLink()`` never returns a deferred link.
extension Strybok {
    // MARK: - Public API

    /// Switches `deferredLinks` on after the instance was created, for example after a
    /// consent screen. Calling it again, or with the option already on, does nothing.
    ///
    /// If `allowProbabilisticMatching` is set, the matching check then runs once (after
    /// ``start()`` has finished).
    public func enableDeferredLinks() {
        let switchedOn = state.withLock { state -> Bool in
            if state.stopped || state.deferredEnabled { return false }
            state.deferredEnabled = true
            return true
        }
        guard switchedOn else { return }
        let status = deferredLinkStatus
        state.withLock { state in
            for listener in state.statusListeners.values {
                listener.yield(state.deferredStatus ?? status)
            }
        }
        startMatchingIfDue()
    }

    /// Where the deferred-link check stands. For developers and QA; do not build app
    /// behaviour on it.
    public var deferredLinkStatus: DeferredLinkStatus {
        let (enabled, known) = state.withLock { ($0.deferredEnabled, $0.deferredStatus) }
        guard enabled else { return .disabled }
        if let known { return known }
        let initial: DeferredLinkStatus
        if deferred.isDone {
            initial = .notFirstLaunch
        } else {
            initial = configuration.allowProbabilisticMatching ? .checking : .awaitingPaste
        }
        return state.withLock { state -> DeferredLinkStatus in
            if let known = state.deferredStatus { return known }
            state.deferredStatus = initial
            return initial
        }
    }

    /// ``deferredLinkStatus`` now and every later change. The stream finishes on
    /// ``stop()``; cancel the iterating task to unsubscribe.
    public func deferredLinkStatuses() -> AsyncStream<DeferredLinkStatus> {
        let current = deferredLinkStatus
        let (stream, continuation) = AsyncStream<DeferredLinkStatus>.makeStream()
        let id = state.withLock { state -> UInt64? in
            continuation.yield(state.deferredEnabled ? (state.deferredStatus ?? current) : .disabled)
            if state.stopped { return nil }
            state.nextID += 1
            state.statusListeners[state.nextID] = continuation
            return state.nextID
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.statusListeners[id] = nil }
        }
        return stream
    }

    /// Exchanges a link the person pasted for the link they tapped before installing
    /// the app, and delivers it through ``links()`` and the listeners with
    /// ``ResolvedLink/isDeferred`` set — even if a normal link was delivered earlier:
    /// pasting was the person's own action.
    ///
    /// **The SDK never reads the clipboard.** Get the string from Apple's paste button
    /// (`UIPasteControl`, SwiftUI `PasteButton`; iOS 16 or later) or a paste action of
    /// your own, and pass it in as it is. Do not paste automatically.
    ///
    /// The string must be a link of this app carrying a valid single-use code
    /// (`…?strybok_click=dc_…`). Anything else is ``PastedLinkResult/notOurs``: no
    /// request is made and the string is dropped — not stored, not logged, not sent.
    /// Otherwise only the code, the bundle identifier and the SDK version are sent.
    ///
    /// Never throws and reports nothing to `onError`. Needs `deferredLinks`.
    public func redeemPastedLink(_ string: String) async -> PastedLinkResult {
        let (stopped, enabled) = state.withLock { ($0.stopped, $0.deferredEnabled) }
        if stopped { return .failed }
        guard enabled else { return .disabled }
        if isDeferredDone { return .alreadyHandled }

        guard let clickId = clickId(inPasted: string) else {
            // Nothing of ours to paste: matching, if it was waiting, may go ahead.
            resumeMatchingAfterPaste()
            return .notOurs
        }
        // From here on only the click id is held, and only in memory. Redemptions run
        // one after another, so a double tap cannot deliver the link twice.
        let task = state.withLock { state -> Task<PastedLinkResult, Never>? in
            if state.stopped { return nil }
            let previous = state.pasteTask
            state.pastesInFlight += 1
            let task = Task { [self] () -> PastedLinkResult in
                _ = await previous?.value
                let result = await redeem(clickId: clickId)
                self.state.withLock { $0.pastesInFlight -= 1 }
                return result
            }
            state.pasteTask = task
            return task
        }
        return await task?.value ?? .failed
    }

    /// Tells the SDK that the person moved on without pasting (they left the screen
    /// with the paste button). Only matters with `allowProbabilisticMatching`: matching
    /// that was waiting for a paste (``DeferredLinkStatus/awaitingPaste``) starts now.
    /// Otherwise it does nothing.
    public func skipPastedLink() {
        guard state.withLock({ $0.deferredEnabled && !$0.stopped }) else { return }
        resumeMatchingAfterPaste()
    }

    /// Whether the clipboard **probably** holds a web address, so the app can decide
    /// whether to show its paste button.
    ///
    /// Uses the system's pattern detection (iOS 14 or later), which reads no content and
    /// shows no banner or alert. It cannot know whether the address is a link of this
    /// app. `false` when `deferredLinks` is off, when a deferred link was already handled
    /// in this installation, below iOS 14 and on other platforms.
    public func pasteboardMayContainLink() async -> Bool {
        guard state.withLock({ $0.deferredEnabled && !$0.stopped }), !isDeferredDone else {
            return false
        }
        return await probePasteboard()
    }

    // MARK: - State

    /// `done` is stored, by this process or an earlier launch.
    private var isDeferredDone: Bool {
        state.withLock { $0.deferredDone } || deferred.isDone
    }

    private func setDeferredStatus(_ status: DeferredLinkStatus) {
        state.withLock { Self.setDeferredStatus(status, in: &$0) }
    }

    private static func setDeferredStatus(_ status: DeferredLinkStatus, in state: inout State) {
        guard state.deferredStatus != status else { return }
        state.deferredStatus = status
        guard state.deferredEnabled else { return }
        for listener in state.statusListeners.values { listener.yield(status) }
    }

    /// Stores `done` with a final status, unless the other flow already did.
    /// - Returns: `false` when `done` was already stored by this process.
    @discardableResult
    private func finishDeferred(_ status: DeferredLinkStatus) -> Bool {
        let context = deferred
        return state.withLock { state -> Bool in
            if state.deferredDone { return false }
            state.deferredDone = true
            context.setDone()
            Self.setDeferredStatus(status, in: &state)
            return true
        }
    }

    private func probePasteboard() async -> Bool {
        let probe = deferred.probe
        // Bounded, so a probe that never answers cannot keep matching waiting for ever.
        if case .success(true) = await withDeadline(configuration.timeout, {
            await probe.mayContainWebURL()
        }) {
            return true
        }
        return false
    }

    // MARK: - Flow A: pasted link

    /// The click id of a pasted string, when the string is a link of this app that
    /// carries a valid one.
    private func clickId(inPasted string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= DeferredLinkFormat.maxPastedLength,
            let url = URL(string: trimmed), isStrybokLink(url),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return DeferredLinkFormat.clickId(inQuery: components.percentEncodedQuery)
    }

    private func redeem(clickId: String) async -> PastedLinkResult {
        if isStopped { return .failed }
        // An earlier redemption (a double tap) or matching may have finished meanwhile.
        if isDeferredDone { return .alreadyHandled }
        guard let bundleId = deferred.environment.bundleId else { return .failed }

        let body = RedeemRequest(
            clickId: clickId, bundleId: bundleId, sdkVersion: String(Self.sdkVersion.prefix(32)))
        let response: StrybokHTTPResponse
        do {
            response = try await send(deferredRequest("redeem", body), for: nil)
        } catch {
            // Network, timeout or 5xx after the retries: `done` is not stored, so the
            // person can tap Paste again.
            return .failed
        }

        switch response.statusCode {
        case 200:
            guard let link = deferredLink(from: response.body, probabilistic: false) else {
                return finishDeferred(.failed) ? .failed : .alreadyHandled
            }
            let context = deferred
            return state.withLock { state -> PastedLinkResult in
                if state.deferredDone { return .alreadyHandled }
                // `done` first, so a crash after delivery cannot deliver again.
                state.deferredDone = true
                context.setDone()
                if state.stopped { return .failed }
                Self.setDeferredStatus(.delivered, in: &state)
                Self.enqueue(link, isLaunch: false, in: &state)
                return .delivered
            }
        case 429:
            return .failed
        case 400..<500:
            return finishDeferred(.notFound) ? .notFound : .alreadyHandled
        default:
            return .failed
        }
    }

    // MARK: - Flow B: probabilistic matching

    /// Begins the matching check when everything it needs holds: both options on,
    /// `start()` finished, not stopped, not begun before in this process.
    func startMatchingIfDue() {
        guard configuration.allowProbabilisticMatching else { return }
        state.withLock { state in
            guard state.deferredEnabled, state.startFinished, !state.stopped, !state.matchClaimed
            else { return }
            state.matchClaimed = true
            state.matchTask = Task { [self] in await beginMatching() }
        }
    }

    private func beginMatching() async {
        // The pasted-link flow already decided in this launch: its status stands.
        if state.withLock({ $0.deferredDone }) { return }
        if deferred.isDone {
            setDeferredStatus(.notFirstLaunch)
            return
        }
        setDeferredStatus(.checking)

        // Clipboard first: a pasted link is exact, a match is a guess.
        let skipped = state.withLock { $0.pasteSkipped }
        let mayPaste = skipped ? false : await probePasteboard()
        let wait = state.withLock { state -> Bool in
            if state.stopped || state.deferredDone { return true }
            // Also wait while a pasted link is being redeemed.
            guard (mayPaste && !state.pasteSkipped) || state.pastesInFlight > 0 else {
                return false
            }
            state.awaitingPaste = true
            Self.setDeferredStatus(.awaitingPaste, in: &state)
            return true
        }
        if wait { return }
        await match()
    }

    /// `redeemPastedLink` answered `notOurs`, or the app called `skipPastedLink`.
    private func resumeMatchingAfterPaste() {
        state.withLock { state in
            state.pasteSkipped = true
            guard state.awaitingPaste, !state.stopped, !state.deferredDone else { return }
            state.awaitingPaste = false
            Self.setDeferredStatus(.checking, in: &state)
            state.matchTask = Task { [self] in await match() }
        }
    }

    private func match() async {
        if state.withLock({ $0.stopped || $0.deferredDone }) { return }
        let context = deferred

        let attempts = context.attempts
        if attempts >= DeferredLinkContext.maxAttempts {
            finishDeferred(.failed)
            return
        }
        // Counted before anything else happens, so a launch that crashes or is killed
        // during the check has used up one of the three attempts.
        context.setAttempts(attempts + 1)

        // A normal link wins: one launch, one navigation.
        if state.withLock({ $0.normalLinkAccepted }) {
            finishDeferred(.superseded)
            return
        }

        let environment = context.environment
        guard let bundleId = environment.bundleId,
            let locale = environment.preferredLanguage, DeferredLinkFormat.isLocale(locale),
            let deviceFamily = await environment.deviceFamily()
        else {
            finishDeferred(.unavailable)
            return
        }

        // Exactly these fields. The service takes the network address from the connection.
        let body = MatchRequest(
            bundleId: bundleId, deviceFamily: deviceFamily, locale: locale,
            sdkVersion: String(Self.sdkVersion.prefix(32)))
        let response: StrybokHTTPResponse
        do {
            response = try await send(deferredRequest("match", body), for: nil)
        } catch {
            // `done` is not stored: a later launch tries again, three at most.
            if !isStopped { setDeferredStatus(.pending) }
            return
        }

        switch response.statusCode {
        case 200:
            guard let link = deferredLink(from: response.body, probabilistic: true) else {
                finishDeferred(.failed)
                return
            }
            state.withLock { state in
                if state.deferredDone { return }  // A pasted link was handled meanwhile.
                state.deferredDone = true
                context.setDone()
                if state.normalLinkAccepted {
                    Self.setDeferredStatus(.superseded, in: &state)
                    return
                }
                if state.stopped { return }
                Self.setDeferredStatus(.delivered, in: &state)
                Self.enqueue(link, isLaunch: false, in: &state)
            }
        case 429:
            setDeferredStatus(.pending)
        case 400..<500:
            finishDeferred(.notFound)
        default:
            setDeferredStatus(.pending)
        }
    }

    // MARK: - Requests and answers

    private struct RedeemRequest: Encodable {
        var platform = "ios"
        var clickId: String
        var bundleId: String
        var sdkVersion: String
    }

    private struct MatchRequest: Encodable {
        var platform = "ios"
        var bundleId: String
        var deviceFamily: String
        var locale: String
        var sdkVersion: String
    }

    private struct DeferredResponse: Decodable {
        var linkId: String
        var appId: String
        var routePath: String
        var payload: JSONValue?
        var campaign: JSONValue?
        var url: String
        var deferred: Bool
        var matched: JSONValue?
    }

    /// `POST /v1/public/deferred-links/{name}`. The body is encoded once, so every retry
    /// sends exactly the same bytes.
    private func deferredRequest(_ name: String, _ body: some Encodable) -> URLRequest {
        var request = URLRequest(url: endpoint("/v1/public/deferred-links/\(name)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try? encoder.encode(body)
        return request
    }

    /// The link of a 200 answer, or `nil` when the answer is unusable: not JSON, missing
    /// fields, a bad `routePath`, `deferred` not `true`, `url` not a link of this app,
    /// or — for matching — not marked as a probabilistic match.
    private func deferredLink(from body: Data, probabilistic: Bool) -> ResolvedLink? {
        guard let answer = try? JSONDecoder().decode(DeferredResponse.self, from: body),
            answer.routePath.hasPrefix("/"), !answer.routePath.hasPrefix("//"),
            answer.deferred,
            let url = URL(string: answer.url), isStrybokLink(url)
        else { return nil }
        if probabilistic, answer.matched?.stringValue != "probabilistic" { return nil }
        return ResolvedLink(
            url: url,
            linkId: answer.linkId,
            appId: answer.appId,
            routePath: answer.routePath,
            payload: answer.payload?.objectValue ?? [:],
            campaign: LinkCampaign(json: answer.campaign),
            isDeferred: true,
            isProbabilisticMatch: probabilistic
        )
    }
}
