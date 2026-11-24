import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

private let key = "pk_test_4f9a1c7e2b"
private let secretPayload: [String: JSONValue] = ["productId": 42, "note": "payload-marker-7731"]

private func created(statusCode: Int = 201, route: String = "/product/42") -> StrybokHTTPResponse {
    .json(
        #"{"linkId":"link_9","slug":"aB3dE5fG","routePath":"\#(route)","url":"https://\#(host)/aB3dE5fG"}"#,
        statusCode: statusCode
    )
}

private func makeCreator(
    _ transport: StubTransport,
    clientKey: String? = key,
    maxRetries: Int = 2,
    timeout: TimeInterval = 5,
    retryDelay: TimeInterval = 0.001,
    errors: Box<[StrybokError]>? = nil,
    source: FakeLinkSource? = nil,
    apiBaseURL: URL = apiBase,
    allowedHosts: Set<String> = [host]
) -> Strybok {
    var onError: (@Sendable (StrybokError) -> Void)?
    if let errors { onError = { errors.append($0) } }
    return Strybok(
        configuration: StrybokConfiguration(
            apiBaseURL: apiBaseURL,
            allowedHosts: allowedHosts,
            timeout: timeout,
            maxRetries: maxRetries,
            retryDelay: retryDelay,
            onError: onError,
            clientKey: clientKey,
            linkSource: source,
            transport: transport
        ))
}

/// Runs `createLink`, which must fail, and returns the error.
private func failure(
    _ sdk: Strybok,
    _ routePath: String = "/product/42",
    payload: [String: JSONValue]? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> StrybokError? {
    do {
        let link = try await sdk.createLink(routePath: routePath, payload: payload)
        XCTFail("Expected an error, got \(link)", file: file, line: line)
        return nil
    } catch {
        XCTAssertNil(error.url, "createLink errors carry no link URL", file: file, line: line)
        return error
    }
}

/// Everything an app could log or show from `error`.
private func visibleText(_ error: StrybokError) -> String {
    "\(error) \(String(reflecting: error)) \(error.localizedDescription) \(String(describing: error.url))"
}

private func json(_ request: URLRequest) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? NSDictionary
}

final class CreateLinkTests: XCTestCase {
    // MARK: - Request

    func testPostsAllFieldsWithTheKeyHeaderAndReturnsTheCreatedLink() async throws {
        let transport = StubTransport { _ in created() }
        let link = try await makeCreator(transport).createLink(
            routePath: "/product/42",
            payload: ["productId": 42],
            title: "Red shoes",
            description: "Look at these",
            imageURL: url("https://cdn.example.com/shoes.png")
        )

        XCTAssertEqual(link.url, url("https://\(host)/aB3dE5fG"))
        XCTAssertEqual(link.slug, "aB3dE5fG")
        XCTAssertEqual(link.routePath, "/product/42")
        XCTAssertEqual(link.linkId, "link_9")

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.strybok.com/v1/public/links")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Strybok-Key"), key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            json(request),
            [
                "routePath": "/product/42",
                "payload": ["productId": 42],
                "title": "Red shoes",
                "description": "Look at these",
                "imageUrl": "https://cdn.example.com/shoes.png",
            ])
    }

    func testArgumentsThatWereNotGivenAreOmittedNotSentAsNull() async throws {
        let transport = StubTransport { _ in created() }
        let sdk = makeCreator(transport)

        _ = try await sdk.createLink(routePath: "/product/42")
        XCTAssertEqual(
            String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self),
            #"{"routePath":"/product/42"}"#)

        _ = try await sdk.createLink(routePath: "/product/42", title: "Red shoes")
        XCTAssertEqual(json(transport.requests[1]), ["routePath": "/product/42", "title": "Red shoes"])
    }

    func testAnEmptyPayloadObjectIsStillSent() async throws {
        let transport = StubTransport { _ in created() }
        _ = try await makeCreator(transport).createLink(routePath: "/product/42", payload: [:])
        XCTAssertEqual(
            String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self),
            #"{"payload":{},"routePath":"/product/42"}"#)
    }

    func testPayloadValuesKeepTheirJSONTypes() async throws {
        let transport = StubTransport { _ in created() }
        _ = try await makeCreator(transport).createLink(
            routePath: "/product/42",
            payload: ["n": 42, "f": 1.5, "b": true, "z": nil, "a": ["x", ["k": "v"]], "s": "Червоні 👟"]
        )
        XCTAssertEqual(
            json(transport.requests[0])?["payload"] as? NSDictionary,
            ["n": 42, "f": 1.5, "b": true, "z": NSNull(), "a": ["x", ["k": "v"]], "s": "Червоні 👟"])
        let sent = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(sent.contains(#""n":42,"#), "whole numbers are sent without a fraction: \(sent)")
    }

    func testKeepsAPathPrefixOfTheAPIBaseURL() async throws {
        let transport = StubTransport { _ in created() }
        let sdk = makeCreator(transport, apiBaseURL: url("https://example.com/strybok/"))
        _ = try await sdk.createLink(routePath: "/product/42")
        XCTAssertEqual(
            transport.requests.first?.url?.absoluteString,
            "https://example.com/strybok/v1/public/links")
    }

    // MARK: - Success

    func testAnExistingIdenticalLinkIsSuccessLikeANewOne() async throws {
        for status in [200, 201] {
            let transport = StubTransport { _ in created(statusCode: status) }
            let link = try await makeCreator(transport).createLink(routePath: "/product/42")
            XCTAssertEqual(link.url, url("https://\(host)/aB3dE5fG"), "\(status)")
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testTheReturnedURLIsNotCheckedAgainstAllowedHosts() async throws {
        let transport = StubTransport { _ in
            .json(
                #"{"linkId":"l","slug":"s","routePath":"/x","url":"https://other.example.net/s"}"#,
                statusCode: 201)
        }
        let link = try await makeCreator(transport, allowedHosts: []).createLink(routePath: "/x")
        XCTAssertEqual(link.url.host, "other.example.net")
    }

    func testASuccessAnswerThatCannotBeReadIsAServerErrorAndIsNotRetried() async {
        for status in [200, 201] {
            for body in [
                "not json",
                "",
                "[]",
                "null",
                #"{"slug":"s","routePath":"/x","url":"https://\#(host)/s"}"#,
                #"{"linkId":"l","routePath":"/x","url":"https://\#(host)/s"}"#,
                #"{"linkId":"l","slug":"s","url":"https://\#(host)/s"}"#,
                #"{"linkId":"l","slug":"s","routePath":"/x"}"#,
                #"{"linkId":1,"slug":"s","routePath":"/x","url":"https://\#(host)/s"}"#,
                #"{"linkId":"l","slug":null,"routePath":"/x","url":"https://\#(host)/s"}"#,
                #"{"linkId":"l","slug":"s","routePath":"/x","url":"http://\#(host)/s"}"#,
                #"{"linkId":"l","slug":"s","routePath":"/x","url":"myapp://open/s"}"#,
                #"{"linkId":"l","slug":"s","routePath":"/x","url":"https://"}"#,
                #"{"linkId":"l","slug":"s","routePath":"/x","url":42}"#,
            ] {
                let transport = StubTransport { _ in .json(body, statusCode: status) }
                let error = await failure(makeCreator(transport), "/x")
                guard case .server(nil, statusCode: status)? = error else {
                    XCTFail("Unexpected result for \(body): \(String(describing: error))")
                    continue
                }
                XCTAssertEqual(transport.requests.count, 1, "not retried: \(body)")
            }
        }
    }

    // MARK: - Rejections are not retried

    func testUnauthorizedStatus() async {
        let transport = StubTransport { _ in
            .json(#"{"error":{"code":"UNAUTHENTICATED"}}"#, statusCode: 401)
        }
        let error = await failure(makeCreator(transport))
        guard case .unauthorized? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testForbiddenIsRouteNotAllowedWithTheRoute() async {
        let transport = StubTransport { _ in .json(#"{"error":{"code":"FORBIDDEN"}}"#, statusCode: 403) }
        let error = await failure(makeCreator(transport), "/admin/1")
        guard case .routeNotAllowed(routePath: "/admin/1")? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTooManyRequestsIsRateLimitedWithRetryAfterSeconds() async {
        for name in ["Retry-After", "retry-after", "RETRY-AFTER"] {
            let transport = StubTransport { _ in .json("{}", statusCode: 429, headers: [name: "37"]) }
            let error = await failure(makeCreator(transport))
            guard case .rateLimited(retryAfter: 37)? = error else {
                XCTFail("Unexpected result for \(name): \(String(describing: error))")
                continue
            }
            XCTAssertEqual(transport.requests.count, 1, "429 is never retried automatically")
        }
    }

    func testRateLimitedWithoutAUsableRetryAfter() async {
        for headers in [
            [:],
            ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"],
            ["Retry-After": "-5"],
            ["Retry-After": ""],
        ] {
            let transport = StubTransport { _ in .json("{}", statusCode: 429, headers: headers) }
            let error = await failure(makeCreator(transport))
            guard case .rateLimited(retryAfter: nil)? = error else {
                XCTFail("Unexpected result for \(headers): \(String(describing: error))")
                continue
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testValidationStatusesCarryTheServerDetails() async {
        let body = """
            {"error":{"code":"VALIDATION_ERROR","message":"The request is invalid","details":{"issues":[
            {"path":"title","message":"Too long"},{"path":"","message":"Unrecognized key"}]}}}
            """
        for status in [400, 413, 422] {
            let transport = StubTransport { _ in .json(body, statusCode: status) }
            let error = await failure(makeCreator(transport))
            guard case .validation(let message, let issues)? = error else {
                XCTFail("Unexpected result for \(status): \(String(describing: error))")
                continue
            }
            XCTAssertEqual(message, "The request is invalid")
            XCTAssertEqual(
                issues,
                [
                    StrybokValidationIssue(path: "title", message: "Too long"),
                    StrybokValidationIssue(path: "", message: "Unrecognized key"),
                ])
            XCTAssertEqual(error?.localizedDescription, "The request is invalid")
            XCTAssertEqual(transport.requests.count, 1, "\(status) is not retried")
        }
    }

    func testAValidationAnswerWithoutReadableDetailsStillHasAMessage() async {
        for body in [
            "",
            "not json",
            "[]",
            #"{"error":"nope"}"#,
            #"{"error":{"message":7,"details":{"issues":"x"}}}"#,
            #"{"error":{"details":{"issues":[1,{"path":"a"},null]}}}"#,
        ] {
            let transport = StubTransport { _ in .json(body, statusCode: 422) }
            let error = await failure(makeCreator(transport))
            guard case .validation(let message, let issues)? = error else {
                XCTFail("Unexpected result for \(body): \(String(describing: error))")
                continue
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(issues, [], body)
        }
    }

    func testOtherClientErrorsAndUnexpectedStatusesAreServerErrors() async {
        for status in [402, 404, 405, 409, 418, 204, 302] {
            let transport = StubTransport { _ in .json("{}", statusCode: status) }
            let error = await failure(makeCreator(transport))
            guard case .server(nil, statusCode: status)? = error else {
                XCTFail("Unexpected result for \(status): \(String(describing: error))")
                continue
            }
            XCTAssertEqual(transport.requests.count, 1, "\(status) is not retried")
        }
    }

    // MARK: - Retries

    func testServerErrorsAreRetriedAndThenSucceed() async throws {
        let calls = Box(0)
        let transport = StubTransport { _ in
            calls.mutate({ $0 += 1; return $0 }) < 3 ? StrybokHTTPResponse(statusCode: 503) : created()
        }
        let link = try await makeCreator(transport).createLink(routePath: "/product/42")
        XCTAssertEqual(link.slug, "aB3dE5fG")
        XCTAssertEqual(calls.value, 3)
    }

    func testReportsTheLastServerErrorAfterMaxRetries() async {
        let calls = Box(0)
        let transport = StubTransport { _ in
            StrybokHTTPResponse(statusCode: calls.mutate({ $0 += 1; return $0 }) == 3 ? 502 : 500)
        }
        let error = await failure(makeCreator(transport))
        guard case .server(nil, statusCode: 502)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 3, "one attempt plus maxRetries")
    }

    func testNetworkFailuresAreRetriedAndThenSucceed() async throws {
        let calls = Box(0)
        let transport = StubTransport { _ in
            if calls.mutate({ $0 += 1; return $0 }) < 3 { throw Offline() }
            return created()
        }
        _ = try await makeCreator(transport).createLink(routePath: "/product/42")
        XCTAssertEqual(calls.value, 3)
    }

    func testGivesUpWithANetworkErrorAfterMaxRetries() async {
        let transport = StubTransport { _ in throw Offline() }
        let error = await failure(makeCreator(transport, maxRetries: 1))
        guard case .network(nil, let underlying)? = error, underlying is Offline else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testTimeoutsAreRetriedAndThenReported() async {
        let transport = StubTransport { _ in try await hang() }
        let error = await failure(makeCreator(transport, maxRetries: 1, timeout: 0.05))
        guard case .timeout(nil)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testATimeoutIsRetriedAndThenSucceeds() async throws {
        let calls = Box(0)
        let transport = StubTransport { _ in
            if calls.mutate({ $0 += 1; return $0 }) == 1 { return try await hang() }
            return created()
        }
        _ = try await makeCreator(transport, timeout: 0.05).createLink(routePath: "/product/42")
        XCTAssertEqual(calls.value, 2)
    }

    func testATransportTimeoutIsReportedAsTimeout() async {
        let transport = StubTransport { _ in throw URLError(.timedOut) }
        let error = await failure(makeCreator(transport, maxRetries: 0))
        guard case .timeout(nil)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
    }

    func testZeroMaxRetriesMeansASingleAttempt() async {
        let transport = StubTransport { _ in StrybokHTTPResponse(statusCode: 500) }
        _ = await failure(makeCreator(transport, maxRetries: 0))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testEveryRetrySendsExactlyTheSameRequest() async throws {
        let transport = StubTransport { _ in StrybokHTTPResponse(statusCode: 503) }
        do {
            _ = try await makeCreator(transport).createLink(
                routePath: "/product/42",
                payload: ["b": 1, "a": [true, nil, 1.5], "nested": ["z": "я", "y": 2]],
                title: "Red shoes",
                description: "Look at these",
                imageURL: url("https://cdn.example.com/shoes.png")
            )
            XCTFail("Expected an error")
        } catch {}

        let requests = transport.requests
        XCTAssertEqual(requests.count, 3)
        let first = try XCTUnwrap(requests.first)
        XCTAssertNotNil(first.httpBody)
        for request in requests.dropFirst() {
            XCTAssertEqual(request.httpBody, first.httpBody)
            XCTAssertEqual(request.allHTTPHeaderFields, first.allHTTPHeaderFields)
            XCTAssertEqual(request.url, first.url)
            XCTAssertEqual(request.httpMethod, first.httpMethod)
        }
    }

    func testTheSameContentAlwaysProducesTheSameBody() async throws {
        // Dictionary order is not stable in Swift; the body must not depend on it.
        let transport = StubTransport { _ in created() }
        let sdk = makeCreator(transport)
        var payload: [String: JSONValue] = [:]
        for index in 0..<40 { payload["key\(index)"] = .number(Double(index)) }
        var reversed: [String: JSONValue] = [:]
        for index in (0..<40).reversed() { reversed["key\(index)"] = .number(Double(index)) }

        _ = try await sdk.createLink(routePath: "/p", payload: payload)
        _ = try await sdk.createLink(routePath: "/p", payload: reversed)
        XCTAssertEqual(transport.requests[0].httpBody, transport.requests[1].httpBody)
    }

    func testWaitsRetryDelayBeforeTheFirstRetryAndDoublesIt() async {
        let times = Box<[Date]>([])
        let transport = StubTransport { _ in
            times.append(Date())
            return StrybokHTTPResponse(statusCode: 503)
        }
        _ = await failure(makeCreator(transport, retryDelay: 0.04))
        let seen = times.value
        XCTAssertEqual(seen.count, 3)
        guard seen.count == 3 else { return }
        XCTAssertGreaterThanOrEqual(seen[1].timeIntervalSince(seen[0]), 0.035)
        XCTAssertGreaterThanOrEqual(seen[2].timeIntervalSince(seen[1]), 0.075)
    }

    // MARK: - Checks before any network call

    func testAMissingOrEmptyClientKeyIsUnauthorized() async {
        for clientKey in [nil, ""] as [String?] {
            let transport = StubTransport { _ in created() }
            let error = await failure(makeCreator(transport, clientKey: clientKey))
            guard case .unauthorized? = error else {
                XCTFail("Unexpected result: \(String(describing: error))")
                continue
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAKeyThatCannotBeAHeaderValueIsRefusedWithoutLeakingIt() async {
        for clientKey in ["pk_bad\r\nX-Injected: 1", "pk bad", "\t\t", "pk_ключ"] {
            let transport = StubTransport { _ in created() }
            let error = await failure(makeCreator(transport, clientKey: clientKey))
            guard case .unauthorized? = error else {
                XCTFail("Unexpected result: \(String(describing: error))")
                continue
            }
            XCTAssertFalse(visibleText(.unauthorized).contains(clientKey))
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testARouteThatIsNotASingleSlashPathIsAValidationError() async {
        for route in [
            "",
            "product/42",
            "//evil.example.com",
            "https://evil.example.com/x",
            " /product",
            "/" + String(repeating: "a", count: 512),
            // 257 characters, but 513 UTF-16 code units, which is what the service counts.
            "/" + String(repeating: "👟", count: 256),
        ] {
            let transport = StubTransport { _ in created() }
            let error = await failure(makeCreator(transport), route)
            guard case .validation(_, issues: [])? = error else {
                XCTFail("Unexpected result for \(route): \(String(describing: error))")
                continue
            }
            XCTAssertTrue(transport.requests.isEmpty, route)
        }
    }

    func testARouteOfExactly512CharactersIsSent() async throws {
        let transport = StubTransport { _ in created() }
        let route = "/" + String(repeating: "a", count: 511)
        _ = try await makeCreator(transport).createLink(routePath: route)
        XCTAssertEqual(json(transport.requests[0]), ["routePath": route])
    }

    func testAPayloadThatIsNotJSONIsAValidationError() async {
        for payload: [String: JSONValue] in [
            ["n": .number(.nan)],
            ["nested": ["deep": [.number(.infinity)]]],
        ] {
            let transport = StubTransport { _ in created() }
            let error = await failure(makeCreator(transport), payload: payload)
            guard case .validation? = error else {
                XCTFail("Unexpected result: \(String(describing: error))")
                continue
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testTheKeyIsCheckedBeforeTheRoute() async {
        let transport = StubTransport { _ in created() }
        let error = await failure(makeCreator(transport, clientKey: nil), "nope")
        guard case .unauthorized? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
    }

    func testOtherLimitsAreLeftToTheServer() async throws {
        let transport = StubTransport { _ in created() }
        _ = try await makeCreator(transport).createLink(
            routePath: "/product/42",
            payload: ["big": .string(String(repeating: "z", count: 8000))],
            title: String(repeating: "x", count: 500),
            description: String(repeating: "y", count: 1000),
            imageURL: url("http://insecure.example.com/a.png")
        )
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Errors never contain the key or the payload

    func testErrorsNeverContainTheKeyOrThePayload() async {
        let answers: [(String, StubTransport.Handler)] = [
            ("401", { _ in .json(#"{"error":{"message":"Authentication is required"}}"#, statusCode: 401) }),
            ("403", { _ in .json(#"{"error":{"message":"Route not allowed"}}"#, statusCode: 403) }),
            ("429", { _ in .json("{}", statusCode: 429, headers: ["Retry-After": "60"]) }),
            (
                "422",
                { _ in
                    .json(
                        #"{"error":{"message":"The request is invalid","details":{"issues":[{"path":"payload","message":"Too large"}]}}}"#,
                        statusCode: 422)
                }
            ),
            ("404", { _ in .json("{}", statusCode: 404) }),
            ("500", { _ in .json("{}", statusCode: 500) }),
            ("malformed", { _ in .json(#"{"nope":true}"#, statusCode: 201) }),
            ("network", { _ in throw Offline() }),
            ("timeout", { _ in try await hang() }),
        ]
        for (name, answer) in answers {
            let sdk = makeCreator(StubTransport(answer), maxRetries: 0, timeout: 0.05)
            guard let error = await failure(sdk, payload: secretPayload) else { continue }
            let text = visibleText(error)
            XCTAssertFalse(text.contains(key), "\(name): \(text)")
            XCTAssertFalse(text.contains("payload-marker-7731"), "\(name): \(text)")
            XCTAssertFalse(text.contains("productId"), "\(name): \(text)")
        }

        let transport = StubTransport { _ in created() }
        let preflight = [
            await failure(makeCreator(transport, clientKey: ""), payload: secretPayload),
            await failure(makeCreator(transport), "product", payload: secretPayload),
            await failure(
                makeCreator(transport), payload: ["note": "payload-marker-7731", "x": .number(.nan)]),
        ]
        for error in preflight.compactMap({ $0 }) {
            XCTAssertFalse(visibleText(error).contains(key))
            XCTAssertFalse(visibleText(error).contains("payload-marker-7731"))
        }
        XCTAssertEqual(preflight.compactMap({ $0 }).count, 3)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Independent of the start path

    /// Answers resolve, event and create-link requests; `onCreate` decides the last.
    private func fullAPI(
        onCreate: @escaping StubTransport.Handler = { _ in created() }
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/public/links") { return try await onCreate(request) }
            if path.hasSuffix("/v1/public/events") { return StrybokHTTPResponse(statusCode: 202) }
            return ok()
        }
    }

    func testWorksWithoutStartAndDoesNotTouchTheLinkSource() async throws {
        let transport = fullAPI()
        let source = FakeLinkSource(launchURL: invite)
        let sdk = makeCreator(transport, source: source)

        let link = try await sdk.createLink(routePath: "/product/42")

        XCTAssertEqual(link.linkId, "link_9")
        await settle()
        XCTAssertEqual(
            transport.requests.map { $0.url?.path }, ["/v1/public/links"],
            "createLink must not start link handling")
        // The launch link is still there for a later start.
        let launch = await sdk.initialLink()
        XCTAssertEqual(launch?.url, invite)
    }

    func testWorksWithNoAllowedHostsAtAll() async throws {
        let transport = fullAPI()
        let link = try await makeCreator(transport, allowedHosts: []).createLink(routePath: "/p")
        XCTAssertEqual(link.slug, "aB3dE5fG")
    }

    func testStartAndIncomingLinksNeverCallIt() async {
        let transport = fullAPI()
        let source = FakeLinkSource(launchURL: invite)
        let sdk = makeCreator(transport, source: source)
        let received = collect(sdk)

        await sdk.start()
        sdk.handle(url("https://\(host)/other"))
        await waitUntil("both links delivered") { received.value.count == 2 }
        await settle()

        let requests = transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/v1/public/links") == true })
        XCTAssertFalse(
            requests.contains { $0.value(forHTTPHeaderField: "X-Strybok-Key") != nil },
            "the key is sent with createLink only")
        sdk.stop()
    }

    func testStartDoesNotWaitForACreateLinkThatIsStillRunning() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let transport = fullAPI { _ in
            for await _ in gate {}
            return created()
        }
        let sdk = makeCreator(transport, source: FakeLinkSource(launchURL: invite))

        let creating = Task { try await sdk.createLink(routePath: "/product/42") }
        await waitUntil("create request sent") { transport.requests.count == 1 }

        let launch = await sdk.initialLink()
        XCTAssertEqual(launch?.routePath, "/invite/abc123")

        open.finish()
        let link = try await creating.value
        XCTAssertEqual(link.linkId, "link_9")
    }

    func testErrorsAreThrownToTheCallerNeverPassedToOnError() async {
        let errors = Box<[StrybokError]>([])
        let transport = fullAPI { _ in .json("{}", statusCode: 403) }
        let sdk = makeCreator(transport, errors: errors)
        await sdk.start()

        _ = await failure(sdk, "/admin")
        _ = await failure(sdk, "not-a-route")
        await settle()

        XCTAssertTrue(errors.value.isEmpty)
    }

    // MARK: - Cancellation (Swift-specific)

    func testCancellingTheCallerEndsCreateLinkWithCancelled() async {
        let transport = StubTransport { _ in try await hang() }
        let sdk = makeCreator(transport)
        let task = Task { () -> StrybokError? in
            do {
                _ = try await sdk.createLink(routePath: "/product/42")
                return nil
            } catch let error as StrybokError {
                return error
            } catch {
                return nil
            }
        }
        await waitUntil("request sent") { transport.requests.count == 1 }
        task.cancel()
        let error = await task.value
        guard case .cancelled(nil)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(transport.requests.count, 1, "a cancelled call is not retried")
    }

    func testAfterStopItThrowsCancelledWithoutANetworkCall() async {
        let transport = StubTransport { _ in created() }
        let sdk = makeCreator(transport)
        sdk.stop()
        let error = await failure(sdk)
        guard case .cancelled(nil)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Transport headers

    func testResponseHeaderLookupIgnoresCase() {
        let response = StrybokHTTPResponse(statusCode: 429, headers: ["retry-after": "5", "X-A": "b"])
        XCTAssertEqual(response.value(forHeader: "Retry-After"), "5")
        XCTAssertEqual(response.value(forHeader: "x-a"), "b")
        XCTAssertNil(response.value(forHeader: "Missing"))
        XCTAssertEqual(StrybokHTTPResponse(statusCode: 200).headers, [:])
    }
}
