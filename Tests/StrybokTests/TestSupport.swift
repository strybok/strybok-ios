import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

let host = "my-app.strybok.link"
let apiBase = URL(string: "https://api.strybok.com")!
let invite = URL(string: "https://\(host)/invite777")!

func url(_ string: String) -> URL { URL(string: string)! }

/// A mutable value shared between a test and `@Sendable` closures.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}

extension Box {
    func append<Element>(_ element: Element) where Value == [Element] {
        mutate { $0.append(element) }
    }
}

func ok(route: String = "/invite/abc123", linkId: String = "link_1") -> StrybokHTTPResponse {
    .json(
        #"{"linkId":"\#(linkId)","appId":"app_1","routePath":"\#(route)","payload":{"invitationId":"abc123"}}"#
    )
}

struct Offline: Error {}

/// Suspends until the task is cancelled, then throws.
func hang() async throws -> StrybokHTTPResponse {
    try await Task.sleep(nanoseconds: 60_000_000_000)
    throw Offline()
}

/// Records requests and answers resolve calls with `onResolve` and event calls with `onEvent`.
final class FakeAPI: Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> StrybokHTTPResponse

    let onResolve: Box<Handler>
    let onEvent = Box<Handler>({ _ in StrybokHTTPResponse(statusCode: 202) })
    let resolves = Box<[URLRequest]>([])
    let eventBodies = Box<[Data]>([])

    init(_ onResolve: @escaping Handler = { _ in ok() }) {
        self.onResolve = Box(onResolve)
    }

    var transport: StubTransport {
        StubTransport { [self] request in
            if request.url?.path.hasSuffix("/v1/public/events") == true {
                eventBodies.append(request.httpBody ?? Data())
                return try await onEvent.value(request)
            }
            resolves.append(request)
            return try await onResolve.value(request)
        }
    }

    var events: [[String: Any]] {
        eventBodies.value.map {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] ?? [:]
        }
    }
}

/// The `url` query parameter of a resolve request.
func lookup(of request: URLRequest) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "url" }?.value
}

func makeSDK(
    _ api: FakeAPI,
    source: FakeLinkSource? = nil,
    errors: Box<[StrybokError]>? = nil,
    now: (@Sendable () -> Date)? = nil,
    maxRetries: Int = 2,
    timeout: TimeInterval = 5,
    reportAppOpens: Bool = true,
    apiBaseURL: URL = apiBase,
    parameterLinks: ParameterLinks? = nil
) -> Strybok {
    var onError: (@Sendable (StrybokError) -> Void)?
    if let errors { onError = { errors.append($0) } }
    var configuration = StrybokConfiguration(
        apiBaseURL: apiBaseURL,
        allowedHosts: [host],
        timeout: timeout,
        maxRetries: maxRetries,
        retryDelay: 0.001,
        reportAppOpens: reportAppOpens,
        onError: onError,
        parameterLinks: parameterLinks,
        linkSource: source,
        transport: api.transport
    )
    if let now { configuration.now = now }
    return Strybok(configuration: configuration)
}

/// Attaches a callback listener that records everything it receives.
func collect(_ sdk: Strybok) -> Box<[ResolvedLink]> {
    let received = Box<[ResolvedLink]>([])
    sdk.addListener { received.append($0) }
    return received
}

/// Polls until `condition` holds; fails the test after `timeout` seconds.
func waitUntil(
    _ what: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for: \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Gives work that should NOT happen a chance to happen.
func settle() async {
    try? await Task.sleep(nanoseconds: 80_000_000)
}

func assertThrows(
    _ sdk: Strybok,
    _ target: URL,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ matches: (StrybokError) -> Bool
) async {
    do {
        let link = try await sdk.resolve(target)
        XCTFail("Expected an error, got \(link)", file: file, line: line)
    } catch {
        XCTAssertTrue(matches(error), "Unexpected error: \(error)", file: file, line: line)
        XCTAssertEqual(error.url, target, file: file, line: line)
    }
}
