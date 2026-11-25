import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

let clickId = "dc_" + String(repeating: "aB3", count: 10) + "zZ"
let pastedLink = "https://\(host)/invite777?strybok_click=\(clickId)"
let testBundleId = "com.example.app"

/// A 200 answer of the redeem endpoint; `extra` is spliced in (e.g. `,"matched":"probabilistic"`).
func deferredAnswer(
    url: String = "https://\(host)/invite777",
    route: String = "/invite/abc123",
    deferred: String = #","deferred":true"#,
    extra: String = ""
) -> StrybokHTTPResponse {
    .json(
        #"{"linkId":"link_d","appId":"app_1","routePath":"\#(route)","payload":{"invitationId":"abc123"},"#
            + #""campaign":{"source":"instagram"},"url":"\#(url)"\#(deferred)\#(extra)}"#
    )
}

func matchAnswer() -> StrybokHTTPResponse {
    deferredAnswer(extra: #","matched":"probabilistic""#)
}

/// In-memory store that also records every write, so tests can assert what was stored
/// and when.
final class FakeDeferredStore: DeferredLinkStore {
    let inner = MemoryDeferredLinkStore()
    /// `"attempts=1"`, `"done"`, in order, with the scope they were written under.
    let writes = Box<[(scope: String, what: String)]>([])
    let reads = Box(0)

    func attempts(scope: String) -> Int {
        reads.mutate { $0 += 1 }
        return inner.attempts(scope: scope)
    }

    func setAttempts(_ attempts: Int, scope: String) {
        writes.append((scope, "attempts=\(attempts)"))
        inner.setAttempts(attempts, scope: scope)
    }

    func isDone(scope: String) -> Bool {
        reads.mutate { $0 += 1 }
        return inner.isDone(scope: scope)
    }

    func setDone(scope: String) {
        writes.append((scope, "done"))
        inner.setDone(scope: scope)
    }

    var log: [String] { writes.value.map(\.what) }
    var touched: Bool { reads.value > 0 || !writes.value.isEmpty }

    static let scope = DeferredLinkContext.scope(apiBaseURL: apiBase, bundleId: testBundleId)
    var attempts: Int { inner.attempts(scope: Self.scope) }
    var isDone: Bool { inner.isDone(scope: Self.scope) }
}

struct FakeEnvironment: DeferredLinkEnvironment {
    var bundleId: String? = testBundleId
    var preferredLanguage: String? = "en-GB"
    var family: String? = "iphone"

    func deviceFamily() async -> String? { family }
}

final class FakeProbe: PasteboardProbe {
    let answer: Box<Bool>
    let calls = Box(0)
    let hangs: Bool

    init(_ answer: Bool = false, hangs: Bool = false) {
        self.answer = Box(answer)
        self.hangs = hangs
    }

    func mayContainWebURL() async -> Bool {
        calls.mutate { $0 += 1 }
        if hangs { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        return answer.value
    }
}

/// Blocks a fake handler until the test opens it.
final class Latch: Sendable {
    private let opened = Box(false)

    func open() { opened.value = true }

    func wait() async throws {
        while !opened.value {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Answers the two deferred endpoints, resolve and events, and records each kind.
final class DeferredAPI: Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> StrybokHTTPResponse

    let onRedeem: Box<Handler>
    let onMatch: Box<Handler>
    let onResolve = Box<Handler>({ _ in ok() })
    let redeems = Box<[URLRequest]>([])
    let matches = Box<[URLRequest]>([])
    let resolves = Box<[URLRequest]>([])
    let events = Box<[URLRequest]>([])
    let all = Box<[URLRequest]>([])

    init(
        redeem: @escaping Handler = { _ in deferredAnswer() },
        match: @escaping Handler = { _ in matchAnswer() }
    ) {
        onRedeem = Box(redeem)
        onMatch = Box(match)
    }

    var transport: StubTransport {
        StubTransport { [self] request in
            all.append(request)
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/public/deferred-links/redeem") {
                redeems.append(request)
                return try await onRedeem.value(request)
            }
            if path.hasSuffix("/v1/public/deferred-links/match") {
                matches.append(request)
                return try await onMatch.value(request)
            }
            if path.hasSuffix("/v1/public/events") {
                events.append(request)
                return StrybokHTTPResponse(statusCode: 202)
            }
            resolves.append(request)
            return try await onResolve.value(request)
        }
    }
}

func jsonBody(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

struct DeferredFixture {
    let sdk: Strybok
    let api: DeferredAPI
    let store: FakeDeferredStore
    let probe: FakeProbe
    let errors: Box<[StrybokError]>
}

func makeDeferred(
    api: DeferredAPI = DeferredAPI(),
    store: FakeDeferredStore = FakeDeferredStore(),
    deferredLinks: Bool = true,
    matching: Bool = false,
    environment: FakeEnvironment = FakeEnvironment(),
    probe: FakeProbe = FakeProbe(),
    source: FakeLinkSource? = nil,
    maxRetries: Int = 0,
    timeout: TimeInterval = 5,
    apiBaseURL: URL = apiBase
) -> DeferredFixture {
    let errors = Box<[StrybokError]>([])
    var configuration = StrybokConfiguration(
        apiBaseURL: apiBaseURL,
        allowedHosts: [host],
        timeout: timeout,
        maxRetries: maxRetries,
        retryDelay: 0.001,
        onError: { errors.append($0) },
        deferredLinks: deferredLinks,
        allowProbabilisticMatching: matching,
        linkSource: source,
        transport: api.transport
    )
    configuration.deferredLinkStore = store
    configuration.deferredLinkEnvironment = environment
    configuration.pasteboardProbe = probe
    return DeferredFixture(
        sdk: Strybok(configuration: configuration), api: api, store: store, probe: probe,
        errors: errors)
}

/// Records every status the SDK publishes, starting with the current one.
func collectStatuses(_ sdk: Strybok) -> Box<[DeferredLinkStatus]> {
    let seen = Box<[DeferredLinkStatus]>([])
    let stream = sdk.deferredLinkStatuses()
    Task {
        for await status in stream { seen.append(status) }
    }
    return seen
}

func waitForStatus(
    _ sdk: Strybok, _ status: DeferredLinkStatus,
    file: StaticString = #filePath, line: UInt = #line
) async {
    await waitUntil("status \(status)", file: file, line: line) { sdk.deferredLinkStatus == status }
}
