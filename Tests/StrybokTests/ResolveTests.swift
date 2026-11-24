import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

final class ResolveTests: XCTestCase {
    func testReturnsRouteAndPayloadAndSendsOnlyHostAndSlug() async throws {
        let api = FakeAPI()
        let tapped = url("https://MY-APP.strybok.link/invite777?token=secret#f")
        let link = try await makeSDK(api).resolve(tapped)

        XCTAssertEqual(link.routePath, "/invite/abc123")
        XCTAssertEqual(link.payload, ["invitationId": "abc123"])
        XCTAssertEqual(link.payload["invitationId"]?.stringValue, "abc123")
        XCTAssertEqual(link.linkId, "link_1")
        XCTAssertEqual(link.appId, "app_1")
        XCTAssertEqual(link.url, tapped, "the original URL is kept, with its query")

        XCTAssertEqual(api.resolves.value.count, 1)
        let request = try XCTUnwrap(api.resolves.value.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.url?.host, "api.strybok.com")
        XCTAssertEqual(request.url?.path, "/v1/public/resolve")
        XCTAssertEqual(lookup(of: request), "https://\(host)/invite777")
        let sent = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(sent.contains("secret"), sent)
        XCTAssertFalse(sent.contains("token"), sent)
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)

        await settle()
        XCTAssertTrue(api.eventBodies.value.isEmpty, "explicit resolution is not an app open")
    }

    func testKeepsAPathPrefixOfTheAPIBaseURL() async throws {
        let api = FakeAPI()
        let sdk = makeSDK(api, apiBaseURL: url("https://example.com/strybok/"))
        _ = try await sdk.resolve(invite)
        XCTAssertEqual(api.resolves.value.first?.url?.path, "/strybok/v1/public/resolve")
    }

    func testNotFoundIsNotRetried() async {
        let api = FakeAPI { _ in .json(#"{"error":{"code":"LINK_NOT_FOUND"}}"#, statusCode: 404) }
        await assertThrows(makeSDK(api), invite) {
            if case .linkNotFound = $0 { return true }
            return false
        }
        XCTAssertEqual(api.resolves.value.count, 1)
    }

    func testOtherClientErrorsAreNotRetried() async {
        let api = FakeAPI { _ in .json("{}", statusCode: 422) }
        await assertThrows(makeSDK(api), invite) {
            if case .server(_, statusCode: 422) = $0 { return true }
            return false
        }
        XCTAssertEqual(api.resolves.value.count, 1)
    }

    func testRetriesNetworkErrorsAndThenSucceeds() async throws {
        let calls = Box(0)
        let api = FakeAPI { _ in
            if calls.mutate({ $0 += 1; return $0 }) < 3 { throw Offline() }
            return ok()
        }
        let link = try await makeSDK(api).resolve(invite)
        XCTAssertEqual(link.routePath, "/invite/abc123")
        XCTAssertEqual(calls.value, 3)
    }

    func testGivesUpWithANetworkErrorAfterMaxRetries() async {
        let api = FakeAPI { _ in throw Offline() }
        await assertThrows(makeSDK(api, maxRetries: 1), invite) {
            if case .network(_, let underlying) = $0 { return underlying is Offline }
            return false
        }
        XCTAssertEqual(api.resolves.value.count, 2)
    }

    func testRetriesServerErrors() async throws {
        let calls = Box(0)
        let api = FakeAPI { _ in
            calls.mutate({ $0 += 1; return $0 }) == 1 ? StrybokHTTPResponse(statusCode: 503) : ok()
        }
        _ = try await makeSDK(api).resolve(invite)
        XCTAssertEqual(calls.value, 2)
    }

    func testReportsTheLastServerErrorAfterMaxRetries() async {
        let api = FakeAPI { _ in StrybokHTTPResponse(statusCode: 503) }
        await assertThrows(makeSDK(api), invite) {
            if case .server(_, statusCode: 503) = $0 { return true }
            return false
        }
        XCTAssertEqual(api.resolves.value.count, 3)
    }

    func testTimesOutWithATypedError() async {
        let api = FakeAPI { _ in try await hang() }
        await assertThrows(makeSDK(api, maxRetries: 1, timeout: 0.05), invite) {
            if case .timeout = $0 { return true }
            return false
        }
        XCTAssertEqual(api.resolves.value.count, 2)
    }

    func testTimeoutDoesNotWaitForATransportThatIgnoresCancellation() async {
        let (never, keepOpen) = AsyncStream<Void>.makeStream()
        let api = FakeAPI { _ in
            // An unstructured task is not cancelled with its parent.
            await Task { for await _ in never {} }.value
            return ok()
        }
        let started = Date()
        await assertThrows(makeSDK(api, maxRetries: 0, timeout: 0.05), invite) {
            if case .timeout = $0 { return true }
            return false
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        keepOpen.finish()
    }

    func testATransportTimeoutIsReportedAsTimeout() async {
        let api = FakeAPI { _ in throw URLError(.timedOut) }
        await assertThrows(makeSDK(api, maxRetries: 0), invite) {
            if case .timeout = $0 { return true }
            return false
        }
    }

    func testRejectsMalformedOrUnsafeResponses() async {
        for body in [
            "not json",
            "",
            "[]",
            #"{"linkId":"l","appId":"a"}"#,
            #"{"linkId":"l","appId":"a","routePath":"https://evil.example.com"}"#,
            #"{"linkId":"l","appId":"a","routePath":"//evil.example.com"}"#,
            #"{"linkId":"l","appId":"a","routePath":""}"#,
            #"{"linkId":1,"appId":"a","routePath":"/x"}"#,
            #"{"linkId":"l","appId":null,"routePath":"/x"}"#,
        ] {
            let api = FakeAPI { _ in .json(body) }
            await assertThrows(makeSDK(api), invite) {
                if case .server(_, statusCode: 200) = $0 { return true }
                return false
            }
            XCTAssertEqual(api.resolves.value.count, 1, "not retried: \(body)")
        }
    }

    func testPayloadIsEmptyWhenMissingOrNotAnObject() async throws {
        for payload in ["", #","payload":null"#, #","payload":"text""#, #","payload":[1,2]"#] {
            let api = FakeAPI { _ in .json(#"{"linkId":"l","appId":"a","routePath":"/x"\#(payload)}"#) }
            let link = try await makeSDK(api).resolve(invite)
            XCTAssertEqual(link.payload, [:], payload)
        }
    }

    func testDecodesNestedPayloadValues() async throws {
        let api = FakeAPI { _ in
            .json(
                #"{"linkId":"l","appId":"a","routePath":"/x","payload":{"n":3,"f":1.5,"b":true,"z":null,"a":["x",{"k":"v"}]}}"#
            )
        }
        let payload = try await makeSDK(api).resolve(invite).payload
        XCTAssertEqual(payload["n"]?.intValue, 3)
        XCTAssertEqual(payload["f"]?.doubleValue, 1.5)
        XCTAssertNil(payload["f"]?.intValue)
        XCTAssertEqual(payload["b"]?.boolValue, true)
        XCTAssertEqual(payload["z"]?.isNull, true)
        XCTAssertEqual(payload["a"]?.arrayValue?.first?.stringValue, "x")
        XCTAssertEqual(payload["a"]?.arrayValue?.last?["k"], "v")
    }

    func testCancellingTheCallerEndsResolveWithCancelled() async {
        let api = FakeAPI { _ in try await hang() }
        let sdk = makeSDK(api)
        let task = Task { () -> StrybokError? in
            do {
                _ = try await sdk.resolve(invite)
                return nil
            } catch let error as StrybokError {
                return error
            } catch {
                return nil
            }
        }
        await waitUntil("request sent") { api.resolves.value.count == 1 }
        task.cancel()
        let error = await task.value
        guard case .cancelled(let cancelledURL)? = error else {
            return XCTFail("Unexpected result: \(String(describing: error))")
        }
        XCTAssertEqual(cancelledURL, invite)
        XCTAssertEqual(api.resolves.value.count, 1, "a cancelled resolve is not retried")
    }
}
