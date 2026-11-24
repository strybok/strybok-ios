import CryptoKit
import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

private let key = "pk_test_4f9a1c7e2b"
private let otherKey = "pk_test_other_99"
private let secretPayload: [String: JSONValue] = ["productId": 42, "note": "payload-marker-7731"]

private typealias Handler = @Sendable (URLRequest) async throws -> StrybokHTTPResponse

private func created() -> StrybokHTTPResponse {
    .json(
        #"{"linkId":"link_9","slug":"aB3dE5fG","routePath":"/product/42","url":"https://\#(host)/aB3dE5fG"}"#,
        statusCode: 201
    )
}

private func refusal(
    _ status: Int, _ code: String, reason: String? = nil, headers: [String: String] = [:]
) -> StrybokHTTPResponse {
    let details = reason.map { #","details":{"reason":"\#($0)"}"# } ?? ""
    return .json(
        #"{"error":{"code":"\#(code)","message":"refused"\#(details)}}"#, statusCode: status,
        headers: headers)
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func json(_ request: URLRequest) -> [String: String]? {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
}

/// Everything an app could log or show from `error`.
private func visibleText(_ error: StrybokError) -> String {
    "\(error) \(String(reflecting: error)) \(error.localizedDescription) \(String(describing: error.url))"
}

/// App Attest without a device: hands out keys and proofs, records every call.
private final class FakeAttestor: AppAttestor, Sendable {
    let supported = Box(true)
    let calls = Box<[String]>([])
    let hashes = Box<[Data]>([])
    let keysMade = Box(0)
    let onGenerateKey = Box<(@Sendable () async throws -> Void)?>(nil)
    let onAttest = Box<(@Sendable (String) async throws -> Void)?>(nil)
    let onAssert = Box<(@Sendable (String) async throws -> Void)?>(nil)

    /// Identifier of the n-th generated key: 44 characters of standard base64, like Apple's.
    static func keyId(_ number: Int) -> String {
        Data(repeating: UInt8(number), count: 32).base64EncodedString()
    }
    /// Bytes whose base64 form differs between the standard and the URL alphabet.
    static let attestation = Data([0xFB, 0xFF, 0xFE, 0x01])
    static let assertion = Data([0xFB, 0xFF, 0xBF, 0x02, 0x03])

    var isSupported: Bool {
        calls.append("isSupported")
        return supported.value
    }

    func generateKey() async throws -> String {
        calls.append("generateKey")
        try await onGenerateKey.value?()
        return Self.keyId(keysMade.mutate { $0 += 1; return $0 })
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        calls.append("attestKey:\(keyId)")
        hashes.append(clientDataHash)
        try await onAttest.value?(keyId)
        return Self.attestation
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        calls.append("generateAssertion:\(keyId)")
        hashes.append(clientDataHash)
        try await onAssert.value?(keyId)
        return Self.assertion
    }

    /// Calls other than the `isSupported` checks.
    var work: [String] { calls.value.filter { $0 != "isSupported" } }
}

/// In-memory key store that records how it was used.
private final class RecordingKeyStore: AttestationKeyStore, Sendable {
    let values = Box<[String: String]>([:])
    let reads = Box<[String]>([])
    let writes = Box<[String]>([])

    func keyId(scope: String) -> String? {
        reads.append(scope)
        return values.value[scope]
    }

    func setKeyId(_ keyId: String?, scope: String) {
        writes.append(scope)
        values.mutate { $0[scope] = keyId }
    }
}

/// The service: challenge, proof and link endpoints, with replaceable answers.
private final class Harness: Sendable {
    let attestor = FakeAttestor()
    let store = RecordingKeyStore()
    let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
    let challenges = Box(0)
    let grants = Box(0)
    let onChallenge: Box<Handler?> = Box(nil)
    let onRegister: Box<Handler?> = Box(nil)
    let onAssert: Box<Handler?> = Box(nil)
    let onLinks: Box<Handler> = Box({ _ in created() })
    let transport: StubTransport

    init() {
        let challenges = challenges
        let grants = grants
        let clock = clock
        let (onChallenge, onRegister, onAssert, onLinks) = (onChallenge, onRegister, onAssert, onLinks)
        let grant: Handler = { _ in
            let number = grants.mutate { $0 += 1; return $0 }
            let expires = iso(clock.value.addingTimeInterval(3600))
            return .json(#"{"token":"session-token-\#(number)","expiresAt":"\#(expires)"}"#)
        }
        transport = StubTransport { request in
            switch request.url?.path {
            case "/v1/public/attest/challenge":
                if let handler = onChallenge.value { return try await handler(request) }
                let number = challenges.mutate { $0 += 1; return $0 }
                return .json(
                    #"{"challenge":"\#(Harness.challenge(number))","expiresAt":"\#(iso(clock.value.addingTimeInterval(300)))"}"#
                )
            case "/v1/public/attest/ios/register":
                return try await (onRegister.value ?? grant)(request)
            case "/v1/public/attest/ios/assert":
                return try await (onAssert.value ?? grant)(request)
            default:
                return try await onLinks.value(request)
            }
        }
    }

    /// The n-th challenge: 43 characters of base64url, like the service's.
    static func challenge(_ number: Int) -> String {
        "challenge-\(number)_" + String(repeating: "A", count: 43 - "challenge-\(number)_".count)
    }

    static func hash(ofChallenge number: Int) -> Data {
        Data(SHA256.hash(data: Data(challenge(number).utf8)))
    }

    func sdk(
        clientKey: String? = key,
        attestation: Bool = true,
        maxRetries: Int = 0,
        timeout: TimeInterval = 5,
        attestorTimeout: TimeInterval = 5,
        apiBaseURL: URL = apiBase,
        source: FakeLinkSource? = nil
    ) -> Strybok {
        var configuration = StrybokConfiguration(
            apiBaseURL: apiBaseURL,
            allowedHosts: [host],
            timeout: timeout,
            maxRetries: maxRetries,
            retryDelay: 0.001,
            clientKey: clientKey,
            attestation: attestation,
            linkSource: source,
            transport: transport
        )
        let clock = clock
        configuration.now = { clock.value }
        configuration.attestor = attestor
        configuration.attestationKeyStore = store
        configuration.attestorTimeout = attestorTimeout
        return Strybok(configuration: configuration)
    }

    /// Paths of all requests, without the common prefix.
    var paths: [String] {
        transport.requests.map { $0.url!.path.replacingOccurrences(of: "/v1/public/", with: "") }
    }

    func requests(_ suffix: String) -> [URLRequest] {
        transport.requests.filter { $0.url!.path.hasSuffix(suffix) }
    }

    /// The attestation header of every `createLink` request, in order.
    var linkTokens: [String?] {
        requests("/links").map { $0.value(forHTTPHeaderField: "X-Strybok-Attestation") }
    }

    var scope: String { AttestationSession.scope(clientKey: key, apiBaseURL: apiBase) }

    /// Makes the device look like one that registered `keyId` on an earlier launch.
    func remember(_ keyId: String) {
        store.values.mutate { $0[scope] = keyId }
    }
}

/// Runs `createLink`, which must fail, and returns the error.
private func failure(
    _ sdk: Strybok, file: StaticString = #filePath, line: UInt = #line
) async -> StrybokError? {
    do {
        let link = try await sdk.createLink(routePath: "/product/42", payload: secretPayload)
        XCTFail("Expected an error, got \(link)", file: file, line: line)
        return nil
    } catch {
        XCTAssertNil(error.url, file: file, line: line)
        return error
    }
}

@discardableResult
private func share(_ sdk: Strybok) async throws -> CreatedLink {
    try await sdk.createLink(routePath: "/product/42", payload: secretPayload)
}

final class AttestationTests: XCTestCase {
    // MARK: - Off by default

    func testIsOffByDefaultAndThenSendsNothingExtra() async throws {
        XCTAssertFalse(
            StrybokConfiguration(apiBaseURL: apiBase, allowedHosts: [host], clientKey: key).attestation)

        let harness = Harness()
        try await share(harness.sdk(attestation: false))
        try await share(harness.sdk(attestation: false))

        XCTAssertEqual(harness.paths, ["links", "links"])
        XCTAssertEqual(harness.linkTokens, [nil, nil])
        XCTAssertEqual(harness.attestor.calls.value, [], "App Attest must not be touched")
        XCTAssertEqual(harness.store.reads.value, [])
        XCTAssertEqual(harness.store.writes.value, [])
    }

    func testWithoutAClientKeyNothingIsAttempted() async {
        let harness = Harness()
        for clientKey in [nil, "", "pk bad key"] {
            let error = await failure(harness.sdk(clientKey: clientKey))
            guard case .unauthorized? = error else { return XCTFail("Unexpected: \(String(describing: error))") }
        }
        XCTAssertEqual(harness.paths, [])
        XCTAssertEqual(harness.attestor.calls.value, [])
        XCTAssertEqual(harness.store.reads.value, [])
    }

    // MARK: - Lazy

    func testNothingHappensUntilCreateLinkIsCalled() async throws {
        let harness = Harness()
        harness.onLinks.value = { _ in ok() }  // Answers resolve and event requests here.
        let source = FakeLinkSource(launchURL: invite)
        let sdk = harness.sdk(source: source)

        await sdk.start()
        let launch = await sdk.initialLink()
        XCTAssertEqual(launch?.routePath, "/invite/abc123")
        _ = try await sdk.resolve(invite)
        await settle()

        XCTAssertFalse(harness.paths.contains { $0.hasPrefix("attest") || $0 == "links" })
        XCTAssertEqual(harness.attestor.calls.value, [])
        XCTAssertEqual(harness.store.reads.value, [])
        XCTAssertEqual(harness.store.writes.value, [])
        for request in harness.transport.requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Strybok-Attestation"))
        }
        sdk.stop()
    }

    // MARK: - First time: register

    func testFirstCallRegistersANewKeyAndSendsTheToken() async throws {
        let harness = Harness()
        let link = try await share(harness.sdk())
        XCTAssertEqual(link.linkId, "link_9")

        XCTAssertEqual(harness.paths, ["attest/challenge", "attest/ios/register", "links"])
        XCTAssertEqual(
            harness.attestor.work, ["generateKey", "attestKey:\(FakeAttestor.keyId(1))"])
        // clientDataHash is SHA-256 of the UTF-8 bytes of the challenge string.
        XCTAssertEqual(harness.attestor.hashes.value, [Harness.hash(ofChallenge: 1)])
        XCTAssertEqual(harness.attestor.hashes.value.first?.count, 32)

        let challenge = try XCTUnwrap(harness.requests("/attest/challenge").first)
        XCTAssertEqual(challenge.url?.absoluteString, "https://api.strybok.com/v1/public/attest/challenge")
        XCTAssertEqual(challenge.httpMethod, "POST")
        XCTAssertNil(challenge.httpBody)

        let register = try XCTUnwrap(harness.requests("/attest/ios/register").first)
        XCTAssertEqual(register.httpMethod, "POST")
        XCTAssertEqual(
            json(register),
            [
                "keyId": FakeAttestor.keyId(1),
                "attestation": "+//+AQ==",  // standard base64 with padding
                "challenge": Harness.challenge(1),
            ])
        XCTAssertEqual(FakeAttestor.keyId(1).count, 44)

        for request in [challenge, register] {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Strybok-Key"), key)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Strybok-Attestation"))
        }

        let create = try XCTUnwrap(harness.requests("/links").first)
        XCTAssertEqual(create.value(forHTTPHeaderField: "X-Strybok-Attestation"), "session-token-1")
        XCTAssertEqual(create.value(forHTTPHeaderField: "X-Strybok-Key"), key)

        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(1)])
    }

    func testTheKeyIsStoredOnlyAfterTheServiceAcceptedIt() async throws {
        let harness = Harness()
        let stored = harness.store.values
        let storedDuringRegister = Box<[String: String]?>(nil)
        harness.onRegister.value = { _ in
            storedDuringRegister.value = stored.value
            return refusal(403, "ATTESTATION_FAILED", reason: "chain")
        }
        try await share(harness.sdk())

        XCTAssertEqual(storedDuringRegister.value, [:])
        XCTAssertEqual(harness.store.values.value, [:], "A refused key must not be kept")
        XCTAssertEqual(harness.linkTokens, [nil])
    }

    // MARK: - Afterwards: assert

    func testALaterLaunchAssertsWithTheStoredKey() async throws {
        let harness = Harness()
        harness.remember(FakeAttestor.keyId(7))
        try await share(harness.sdk())

        XCTAssertEqual(harness.paths, ["attest/challenge", "attest/ios/assert", "links"])
        XCTAssertEqual(harness.attestor.work, ["generateAssertion:\(FakeAttestor.keyId(7))"])
        XCTAssertEqual(harness.attestor.hashes.value, [Harness.hash(ofChallenge: 1)])
        let assert = try XCTUnwrap(harness.requests("/attest/ios/assert").first)
        XCTAssertEqual(
            json(assert),
            [
                "keyId": FakeAttestor.keyId(7),
                "assertion": "+/+/AgM=",
                "challenge": Harness.challenge(1),
            ])
        XCTAssertEqual(assert.value(forHTTPHeaderField: "X-Strybok-Key"), key)
        XCTAssertEqual(harness.linkTokens, ["session-token-1"])
        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(7)])
    }

    func testAKeyRegisteredByOneInstanceIsAssertedByTheNext() async throws {
        let harness = Harness()
        try await share(harness.sdk())
        try await share(harness.sdk())  // A new launch: no token in memory, the key is stored.

        XCTAssertEqual(
            harness.paths,
            [
                "attest/challenge", "attest/ios/register", "links",
                "attest/challenge", "attest/ios/assert", "links",
            ])
        XCTAssertEqual(harness.linkTokens, ["session-token-1", "session-token-2"])
        XCTAssertEqual(harness.attestor.keysMade.value, 1)
    }

    // MARK: - Token cache

    func testTheTokenIsReusedUntilAMinuteBeforeItExpires() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        let start = harness.clock.value

        try await share(sdk)
        try await share(sdk)
        harness.clock.value = start.addingTimeInterval(3600 - 61)
        try await share(sdk)
        XCTAssertEqual(harness.requests("/attest/challenge").count, 1)
        XCTAssertEqual(harness.linkTokens, ["session-token-1", "session-token-1", "session-token-1"])

        harness.clock.value = start.addingTimeInterval(3600 - 60)
        try await share(sdk)
        XCTAssertEqual(
            harness.paths.suffix(3), ["attest/challenge", "attest/ios/assert", "links"],
            "A token in its last minute is replaced, with the stored key")
        XCTAssertEqual(harness.linkTokens.last, "session-token-2")

        try await share(sdk)
        XCTAssertEqual(harness.requests("/attest/challenge").count, 2)
        XCTAssertEqual(harness.linkTokens.last, "session-token-2")
    }

    func testExpiryWithoutFractionalSecondsIsUnderstood() async throws {
        XCTAssertEqual(
            AttestationSession.date("2027-01-15T08:00:00Z"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(
            AttestationSession.date("2027-01-15T08:00:00.000Z"),
            Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(AttestationSession.date("soon"))
    }

    // MARK: - Concurrency

    func testParallelCallsShareOneAttestation() async throws {
        let harness = Harness()
        harness.attestor.onGenerateKey.value = { try await Task.sleep(nanoseconds: 60_000_000) }
        let sdk = harness.sdk()

        let links = await withTaskGroup(of: CreatedLink?.self) { group -> [CreatedLink?] in
            for _ in 0..<12 { group.addTask { try? await share(sdk) } }
            var all: [CreatedLink?] = []
            for await link in group { all.append(link) }
            return all
        }

        XCTAssertEqual(links.compactMap { $0 }.count, 12)
        XCTAssertEqual(harness.requests("/attest/challenge").count, 1)
        XCTAssertEqual(harness.requests("/attest/ios/register").count, 1)
        XCTAssertEqual(harness.attestor.work.count, 2, "One key, one attestation")
        XCTAssertEqual(harness.linkTokens, Array(repeating: "session-token-1", count: 12))
    }

    func testParallelCallsWhoseTokenWasRefusedShareOneNewAttestation() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        try await share(sdk)  // session-token-1 is cached.

        harness.attestor.onAssert.value = { _ in try await Task.sleep(nanoseconds: 60_000_000) }
        harness.onLinks.value = { request in
            request.value(forHTTPHeaderField: "X-Strybok-Attestation") == "session-token-1"
                ? refusal(401, "ATTESTATION_INVALID", reason: "exhausted") : created()
        }
        let made = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<8 { group.addTask { (try? await share(sdk)) != nil } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        XCTAssertEqual(made, 8)
        XCTAssertEqual(harness.requests("/attest/ios/assert").count, 1)
        XCTAssertEqual(harness.requests("/attest/challenge").count, 2)
    }

    func testACancelledCallerLeavesWithoutWaitingForTheAttestation() async throws {
        let harness = Harness()
        harness.onChallenge.value = { _ in try await hang() }
        let sdk = harness.sdk(timeout: 2)
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
        await waitUntil("challenge requested") { harness.paths == ["attest/challenge"] }
        task.cancel()
        let error = await task.value
        guard case .cancelled(nil)? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(harness.requests("/links").count, 0)
    }

    func testAfterStopNothingIsAttested() async {
        let harness = Harness()
        let sdk = harness.sdk()
        sdk.stop()
        let error = await failure(sdk)
        guard case .cancelled? = error else { return XCTFail("Unexpected: \(String(describing: error))") }
        XCTAssertEqual(harness.paths, [])
        XCTAssertEqual(harness.attestor.calls.value, [])
    }

    // MARK: - ATTESTATION_INVALID: attest again, retry once

    func testARefusedTokenIsReplacedAndTheRequestSentOnceMore() async throws {
        for reason in ["expired", "invalid", "exhausted"] {
            let harness = Harness()
            let sdk = harness.sdk(maxRetries: 0)  // The second request is not a retry.
            try await share(sdk)

            let calls = Box(0)
            harness.onLinks.value = { _ in
                calls.mutate({ $0 += 1; return $0 }) == 1
                    ? refusal(401, "ATTESTATION_INVALID", reason: reason) : created()
            }
            let link = try await share(sdk)
            XCTAssertEqual(link.slug, "aB3dE5fG", reason)

            XCTAssertEqual(
                harness.paths.suffix(4), ["links", "attest/challenge", "attest/ios/assert", "links"],
                reason)
            XCTAssertEqual(harness.linkTokens.suffix(2), ["session-token-1", "session-token-2"], reason)
            let sent = harness.requests("/links").suffix(2).map(\.httpBody)
            XCTAssertEqual(sent.first, sent.last, "The same request is sent again")
            // The new challenge is a new one.
            XCTAssertEqual(
                harness.requests("/attest/ios/assert").last.flatMap(json)?["challenge"],
                Harness.challenge(2), reason)

            // The fresh token is the cached one from now on.
            try await share(sdk)
            XCTAssertEqual(harness.linkTokens.last, "session-token-2", reason)
            XCTAssertEqual(harness.requests("/attest/challenge").count, 2, reason)
        }
    }

    func testATokenRefusedTwiceFailsWithoutAThirdAttempt() async throws {
        let harness = Harness()
        let sdk = harness.sdk(maxRetries: 3)
        let calls = Box(0)
        harness.onLinks.value = { _ in
            refusal(
                401, "ATTESTATION_INVALID",
                reason: calls.mutate({ $0 += 1; return $0 }) == 1 ? "expired" : "exhausted")
        }
        let error = await failure(sdk)
        guard case .attestationFailed(reason: "exhausted")? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(
            harness.paths,
            [
                "attest/challenge", "attest/ios/register", "links",
                "attest/challenge", "attest/ios/assert", "links",
            ])
        XCTAssertEqual(harness.linkTokens, ["session-token-1", "session-token-2"])

        // Neither refused token is used again.
        harness.onLinks.value = { _ in created() }
        try await share(sdk)
        XCTAssertEqual(harness.linkTokens.last, "session-token-3")
    }

    func testARefusedTokenThatCannotBeReplacedFails() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        try await share(sdk)

        harness.onLinks.value = { _ in refusal(401, "ATTESTATION_INVALID", reason: "expired") }
        harness.onAssert.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "counter") }
        let error = await failure(sdk)
        guard case .attestationFailed(reason: "expired")? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(harness.requests("/links").count, 2, "No second request without a token")
        XCTAssertEqual(harness.requests("/attest/ios/assert").count, 1)
    }

    func testARefusalWithoutAReasonOrWithAnOddOneCarriesNoReason() async throws {
        for body in [
            #"{"error":{"code":"ATTESTATION_INVALID"}}"#,
            #"{"error":{"code":"ATTESTATION_INVALID","details":{"reason":"session-token-1 pk_test"}}}"#,
            #"{"error":{"code":"ATTESTATION_INVALID","details":{"reason":7}}}"#,
        ] {
            let harness = Harness()
            harness.onLinks.value = { _ in .json(body, statusCode: 401) }
            let error = await failure(harness.sdk())
            guard case .attestationFailed(reason: nil)? = error else {
                return XCTFail("Unexpected: \(String(describing: error)) for \(body)")
            }
            XCTAssertEqual(harness.requests("/links").count, 2)
        }
    }

    // MARK: - Unknown key: start over once

    func testAKeyTheServiceDoesNotKnowIsReplacedOnce() async throws {
        let harness = Harness()
        harness.remember(FakeAttestor.keyId(7))
        harness.onAssert.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "unknown_key") }
        try await share(harness.sdk())

        XCTAssertEqual(
            harness.paths,
            [
                "attest/challenge", "attest/ios/assert",
                "attest/challenge", "attest/ios/register", "links",
            ])
        XCTAssertEqual(
            harness.attestor.work,
            [
                "generateAssertion:\(FakeAttestor.keyId(7))", "generateKey",
                "attestKey:\(FakeAttestor.keyId(1))",
            ])
        // A new challenge for the new proof.
        XCTAssertEqual(
            harness.requests("/attest/ios/register").first.flatMap(json)?["challenge"],
            Harness.challenge(2))
        XCTAssertEqual(
            harness.attestor.hashes.value, [Harness.hash(ofChallenge: 1), Harness.hash(ofChallenge: 2)])
        XCTAssertEqual(harness.linkTokens, ["session-token-1"])
        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(1)])
    }

    func testAKeyThatIsGoneFromTheDeviceIsReplacedOnce() async throws {
        let harness = Harness()
        harness.remember(FakeAttestor.keyId(7))
        harness.attestor.onAssert.value = { _ in throw AppAttestorError.invalidKey }
        try await share(harness.sdk())

        XCTAssertEqual(
            harness.paths,
            ["attest/challenge", "attest/challenge", "attest/ios/register", "links"])
        XCTAssertEqual(harness.linkTokens, ["session-token-1"])
        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(1)])
    }

    func testAKeyTheServiceAlreadyHasIsReplacedOnce() async throws {
        let harness = Harness()
        let calls = Box(0)
        let grants = harness.grants
        let clock = harness.clock
        harness.onRegister.value = { _ in
            if calls.mutate({ $0 += 1; return $0 }) == 1 {
                return refusal(403, "ATTESTATION_FAILED", reason: "key_exists")
            }
            grants.value += 1
            return .json(
                #"{"token":"session-token-1","expiresAt":"\#(iso(clock.value.addingTimeInterval(3600)))"}"#)
        }
        try await share(harness.sdk())

        XCTAssertEqual(
            harness.paths,
            [
                "attest/challenge", "attest/ios/register",
                "attest/challenge", "attest/ios/register", "links",
            ])
        XCTAssertEqual(
            harness.requests("/attest/ios/register").compactMap { json($0)?["keyId"] },
            [FakeAttestor.keyId(1), FakeAttestor.keyId(2)])
        XCTAssertEqual(harness.linkTokens, ["session-token-1"])
        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(2)])
    }

    func testStartingOverHappensOnlyOnce() async throws {
        // Unknown key, then the new key is refused as well: give up for this call.
        let harness = Harness()
        harness.remember(FakeAttestor.keyId(7))
        harness.onAssert.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "unknown_key") }
        harness.onRegister.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "key_exists") }
        try await share(harness.sdk())
        XCTAssertEqual(
            harness.paths,
            [
                "attest/challenge", "attest/ios/assert",
                "attest/challenge", "attest/ios/register", "links",
            ])
        XCTAssertEqual(harness.linkTokens, [nil])
        XCTAssertEqual(harness.store.values.value, [:], "The unknown key is discarded")

        // The key exists again and again.
        let again = Harness()
        again.onRegister.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "key_exists") }
        try await share(again.sdk())
        XCTAssertEqual(again.requests("/attest/ios/register").count, 2)
        XCTAssertEqual(again.linkTokens, [nil])
        XCTAssertEqual(again.store.values.value, [:])
    }

    // MARK: - Unavailable: no header, the service decides

    func testAnUnsupportedDeviceSendsTheRequestWithoutAToken() async throws {
        let harness = Harness()
        harness.attestor.supported.value = false
        try await share(harness.sdk())

        XCTAssertEqual(harness.paths, ["links"], "Not even a challenge is requested")
        XCTAssertEqual(harness.linkTokens, [nil])
        XCTAssertEqual(harness.attestor.work, [])
        XCTAssertEqual(harness.store.values.value, [:])
    }

    func testAnUnsupportedDeviceGetsTheServiceAnswerInRequiredMode() async {
        let harness = Harness()
        harness.attestor.supported.value = false
        harness.onLinks.value = { _ in refusal(401, "ATTESTATION_REQUIRED") }
        let error = await failure(harness.sdk(maxRetries: 3))
        guard case .attestationRequired? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(harness.paths, ["links"], "Not retried")
    }

    func testAppAttestFailuresSendTheRequestWithoutAToken() async throws {
        struct Odd: Error {}
        let failures: [(String, @Sendable (FakeAttestor) -> Void)] = [
            ("generateKey", { $0.onGenerateKey.value = { throw AppAttestorError.failed } }),
            ("generateKey odd", { $0.onGenerateKey.value = { throw Odd() } }),
            ("attestKey", { $0.onAttest.value = { _ in throw AppAttestorError.failed } }),
            ("attestKey invalid", { $0.onAttest.value = { _ in throw AppAttestorError.invalidKey } }),
            ("attestKey apple", { $0.onAttest.value = { _ in throw AppAttestorError.serverUnavailable } }),
        ]
        for (name, arrange) in failures {
            let harness = Harness()
            arrange(harness.attestor)
            try await share(harness.sdk())
            XCTAssertEqual(harness.paths, ["attest/challenge", "links"], name)
            XCTAssertEqual(harness.linkTokens, [nil], name)
            XCTAssertEqual(harness.store.values.value, [:], name)
        }

        for error in [AppAttestorError.failed, .serverUnavailable] {
            let harness = Harness()
            harness.remember(FakeAttestor.keyId(7))
            harness.attestor.onAssert.value = { _ in throw error }
            try await share(harness.sdk())
            XCTAssertEqual(harness.paths, ["attest/challenge", "links"])
            XCTAssertEqual(harness.linkTokens, [nil])
            XCTAssertEqual(
                harness.store.values.value, [harness.scope: FakeAttestor.keyId(7)],
                "Only an invalid key is discarded")
        }
    }

    func testAnAppAttestCallThatNeverReturnsDoesNotHoldCreateLink() async throws {
        let harness = Harness()
        harness.attestor.onGenerateKey.value = { try await Task.sleep(nanoseconds: 60_000_000_000) }
        let started = Date()
        try await share(harness.sdk(attestorTimeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(harness.paths, ["attest/challenge", "links"])
        XCTAssertEqual(harness.linkTokens, [nil])
    }

    func testAKeyAppleCouldNotAttestIsTriedAgainLater() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        harness.attestor.onAttest.value = { _ in throw AppAttestorError.serverUnavailable }
        try await share(sdk)
        XCTAssertEqual(harness.linkTokens, [nil])

        harness.attestor.onAttest.value = nil
        harness.clock.value += 61
        try await share(sdk)
        XCTAssertEqual(
            harness.attestor.work,
            [
                "generateKey", "attestKey:\(FakeAttestor.keyId(1))",
                "attestKey:\(FakeAttestor.keyId(1))",
            ], "The same key, not a new one")
        XCTAssertEqual(harness.linkTokens, [nil, "session-token-1"])
        XCTAssertEqual(harness.store.values.value, [harness.scope: FakeAttestor.keyId(1)])
    }

    func testChallengeAnswersThatMakeAttestationUnavailable() async throws {
        let answers: [(String, Handler)] = [
            ("429", { _ in refusal(429, "RATE_LIMITED", headers: ["Retry-After": "30"]) }),
            ("503 not configured", { _ in refusal(503, "ATTESTATION_NOT_CONFIGURED") }),
            ("500", { _ in StrybokHTTPResponse(statusCode: 500) }),
            ("404", { _ in StrybokHTTPResponse(statusCode: 404) }),
            ("offline", { _ in throw Offline() }),
            ("not json", { _ in .json("<html>") }),
            ("no challenge", { _ in .json(#"{"expiresAt":"2027-01-15T08:05:00.000Z"}"#) }),
            ("empty challenge", { _ in .json(#"{"challenge":""}"#) }),
            ("challenge not a string", { _ in .json(#"{"challenge":7}"#) }),
        ]
        for (name, answer) in answers {
            let harness = Harness()
            harness.onChallenge.value = answer
            // Attestation requests are never retried, whatever `maxRetries` says.
            try await share(harness.sdk(maxRetries: 3))
            XCTAssertEqual(harness.paths, ["attest/challenge", "links"], name)
            XCTAssertEqual(harness.linkTokens, [nil], name)
            XCTAssertEqual(harness.attestor.work, [], name)
        }
    }

    func testAChallengeThatDoesNotAnswerInTimeMakesAttestationUnavailable() async throws {
        let harness = Harness()
        harness.onChallenge.value = { _ in try await hang() }
        try await share(harness.sdk(maxRetries: 3, timeout: 0.05))
        XCTAssertEqual(harness.paths, ["attest/challenge", "links"])
        XCTAssertEqual(harness.linkTokens, [nil])
    }

    func testProofAnswersThatMakeAttestationUnavailable() async throws {
        let answers: [(String, Handler)] = [
            ("failed: chain", { _ in refusal(403, "ATTESTATION_FAILED", reason: "chain") }),
            ("failed: challenge", { _ in refusal(403, "ATTESTATION_FAILED", reason: "challenge") }),
            ("failed: environment", { _ in refusal(403, "ATTESTATION_FAILED", reason: "environment") }),
            ("failed: no reason", { _ in refusal(403, "ATTESTATION_FAILED") }),
            ("403 other", { _ in refusal(403, "FORBIDDEN", reason: "unknown_key") }),
            ("409", { _ in refusal(409, "ATTESTATION_NOT_CONFIGURED") }),
            ("429", { _ in refusal(429, "RATE_LIMITED") }),
            ("422", { _ in refusal(422, "VALIDATION_ERROR") }),
            ("503 not configured", { _ in refusal(503, "ATTESTATION_NOT_CONFIGURED") }),
            ("503 unavailable", { _ in refusal(503, "ATTESTATION_UNAVAILABLE", reason: "upstream") }),
            ("offline", { _ in throw Offline() }),
            ("not json", { _ in .json("ok") }),
            ("no token", { _ in .json(#"{"expiresAt":"2027-01-15T09:00:00.000Z"}"#) }),
            ("token not a string", { _ in .json(#"{"token":7,"expiresAt":"2027-01-15T09:00:00.000Z"}"#) }),
            ("empty token", { _ in .json(#"{"token":"","expiresAt":"2027-01-15T09:00:00.000Z"}"#) }),
            ("token not a header", { _ in .json(#"{"token":"a\nb","expiresAt":"2027-01-15T09:00:00.000Z"}"#) }),
            ("no expiry", { _ in .json(#"{"token":"session-token-1"}"#) }),
            ("odd expiry", { _ in .json(#"{"token":"session-token-1","expiresAt":"soon"}"#) }),
        ]
        for (name, answer) in answers {
            for stored in [false, true] {
                let harness = Harness()
                if stored { harness.remember(FakeAttestor.keyId(7)) }
                harness.onRegister.value = answer
                harness.onAssert.value = answer
                try await share(harness.sdk(maxRetries: 3))
                let proof = stored ? "attest/ios/assert" : "attest/ios/register"
                XCTAssertEqual(harness.paths, ["attest/challenge", proof, "links"], name)
                XCTAssertEqual(harness.linkTokens, [nil], name)
                XCTAssertEqual(
                    harness.store.values.value,
                    stored ? [harness.scope: FakeAttestor.keyId(7)] : [:], name)
            }
        }
    }

    func testAfterAnUnavailableAttemptTheNextOneWaitsAMinute() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        harness.onChallenge.value = { _ in refusal(429, "RATE_LIMITED") }
        try await share(sdk)
        harness.onChallenge.value = nil

        harness.clock.value += 59
        try await share(sdk)
        XCTAssertEqual(harness.paths, ["attest/challenge", "links", "links"])
        XCTAssertEqual(harness.linkTokens, [nil, nil])

        harness.clock.value += 1
        try await share(sdk)
        XCTAssertEqual(harness.paths.suffix(3), ["attest/challenge", "attest/ios/register", "links"])
        XCTAssertEqual(harness.linkTokens.last, "session-token-1")
    }

    // MARK: - Unauthorized on the attestation endpoints

    func testAKeyRefusedByAnAttestationEndpointIsUnauthorized() async {
        let challenge = Harness()
        challenge.onChallenge.value = { _ in refusal(401, "UNAUTHENTICATED") }
        var error = await failure(challenge.sdk())
        guard case .unauthorized? = error else { return XCTFail("Unexpected: \(String(describing: error))") }
        XCTAssertEqual(challenge.paths, ["attest/challenge"], "createLink is not sent")

        for stored in [false, true] {
            let proof = Harness()
            if stored { proof.remember(FakeAttestor.keyId(7)) }
            proof.onRegister.value = { _ in refusal(401, "UNAUTHENTICATED") }
            proof.onAssert.value = { _ in refusal(401, "UNAUTHENTICATED") }
            let sdk = proof.sdk()
            error = await failure(sdk)
            guard case .unauthorized? = error else {
                return XCTFail("Unexpected: \(String(describing: error))")
            }
            XCTAssertEqual(proof.requests("/links").count, 0)

            // Not remembered as "unavailable": the next call asks again.
            _ = await failure(sdk)
            XCTAssertEqual(proof.requests("/attest/challenge").count, 2)
        }
    }

    // MARK: - createLink answers

    func testAttestationAnswersOfCreateLinkAreMapped() async throws {
        // 401 ATTESTATION_REQUIRED, also with attestation switched off.
        for attestation in [true, false] {
            let harness = Harness()
            harness.onLinks.value = { _ in refusal(401, "ATTESTATION_REQUIRED") }
            let error = await failure(harness.sdk(attestation: attestation, maxRetries: 3))
            guard case .attestationRequired? = error else {
                return XCTFail("Unexpected: \(String(describing: error))")
            }
            XCTAssertEqual(harness.requests("/links").count, 1, "Not retried")
        }

        // 401 ATTESTATION_INVALID with attestation switched off: nothing to attest with.
        let off = Harness()
        off.onLinks.value = { _ in refusal(401, "ATTESTATION_INVALID", reason: "invalid") }
        var error = await failure(off.sdk(attestation: false))
        guard case .attestationFailed(reason: "invalid")? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(off.paths, ["links"])

        // Any other 401 stays `unauthorized`.
        for body in [#"{"error":{"code":"UNAUTHENTICATED"}}"#, "", #"{"error":{"code":7}}"#] {
            let harness = Harness()
            harness.onLinks.value = { _ in .json(body, statusCode: 401) }
            error = await failure(harness.sdk())
            guard case .unauthorized? = error else {
                return XCTFail("Unexpected: \(String(describing: error))")
            }
            XCTAssertEqual(harness.requests("/links").count, 1)
        }

        // 429 for callers without proof is a 429 like any other.
        let limited = Harness()
        limited.attestor.supported.value = false
        limited.onLinks.value = { _ in
            .json(
                #"{"error":{"code":"RATE_LIMITED","details":{"scope":"unattested"}}}"#, statusCode: 429,
                headers: ["Retry-After": "120"])
        }
        error = await failure(limited.sdk(maxRetries: 3))
        guard case .rateLimited(retryAfter: 120)? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(limited.requests("/links").count, 1)

        // 503 ATTESTATION_NOT_CONFIGURED is a 5xx: retried, then `server`.
        let broken = Harness()
        broken.onLinks.value = { _ in refusal(503, "ATTESTATION_NOT_CONFIGURED") }
        error = await failure(broken.sdk(maxRetries: 2))
        guard case .server(nil, statusCode: 503)? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        XCTAssertEqual(broken.requests("/links").count, 3)
        XCTAssertEqual(broken.linkTokens, Array(repeating: "session-token-1", count: 3))
        XCTAssertEqual(broken.requests("/attest/challenge").count, 1, "Retries reuse the token")
    }

    func testOtherAnswersAreUntouchedByAttestation() async throws {
        let harness = Harness()
        let sdk = harness.sdk()
        harness.onLinks.value = { _ in refusal(403, "FORBIDDEN") }
        var error = await failure(sdk)
        guard case .routeNotAllowed(routePath: "/product/42")? = error else {
            return XCTFail("Unexpected: \(String(describing: error))")
        }
        harness.onLinks.value = { _ in refusal(422, "VALIDATION_ERROR") }
        error = await failure(sdk)
        guard case .validation? = error else { return XCTFail("Unexpected: \(String(describing: error))") }
        XCTAssertEqual(harness.requests("/attest/challenge").count, 1, "The token stays valid")
    }

    // MARK: - Key storage scope

    func testTheStoredKeyIsScopedToTheClientKeyAndTheAPI() async throws {
        let scope = AttestationSession.scope
        let base = scope(key, apiBase)
        XCTAssertNotEqual(base, scope(otherKey, apiBase))
        XCTAssertNotEqual(base, scope(key, url("https://api.staging.strybok.com")))
        XCTAssertNotEqual(base, scope(key, url("https://api.strybok.com/v2")))
        XCTAssertNotEqual(base, scope(key, url("https://api.strybok.com:8443")))
        XCTAssertNotEqual(base, scope(key, url("http://api.strybok.com")))
        XCTAssertEqual(base, scope(key, url("https://API.Strybok.com/")))
        XCTAssertFalse(base.contains(key), "The client key is not written to the store")
        XCTAssertFalse(base.contains("strybok.com"))
    }

    func testAnotherAppOrEnvironmentNeverReusesAStoredKey() async throws {
        let harness = Harness()
        try await share(harness.sdk())  // registers key 1 for `key` on production
        try await share(harness.sdk(clientKey: otherKey))
        try await share(harness.sdk(apiBaseURL: url("https://api.staging.strybok.com")))

        XCTAssertEqual(harness.requests("/attest/ios/register").count, 3)
        XCTAssertEqual(harness.requests("/attest/ios/assert").count, 0)
        XCTAssertEqual(
            harness.requests("/attest/ios/register").map { $0.value(forHTTPHeaderField: "X-Strybok-Key") },
            [key, otherKey, key])
        XCTAssertEqual(
            harness.requests("/attest/ios/register").last?.url?.host, "api.staging.strybok.com")
        XCTAssertEqual(
            harness.store.values.value,
            [
                AttestationSession.scope(clientKey: key, apiBaseURL: apiBase): FakeAttestor.keyId(1),
                AttestationSession.scope(clientKey: otherKey, apiBaseURL: apiBase): FakeAttestor.keyId(2),
                AttestationSession.scope(
                    clientKey: key, apiBaseURL: url("https://api.staging.strybok.com")):
                    FakeAttestor.keyId(3),
            ])

        // Back on the first app: its own key is asserted, the others are untouched.
        try await share(harness.sdk())
        XCTAssertEqual(
            harness.requests("/attest/ios/assert").last.flatMap(json)?["keyId"], FakeAttestor.keyId(1))
        XCTAssertEqual(harness.store.values.value.count, 3)
    }

    func testDiscardingAKeyLeavesOtherScopesAlone() async throws {
        let harness = Harness()
        let other = AttestationSession.scope(clientKey: otherKey, apiBaseURL: apiBase)
        harness.store.values.value = [harness.scope: FakeAttestor.keyId(7), other: FakeAttestor.keyId(8)]
        harness.attestor.onAssert.value = { _ in throw AppAttestorError.invalidKey }
        harness.attestor.onGenerateKey.value = { throw AppAttestorError.failed }
        try await share(harness.sdk())
        XCTAssertEqual(harness.store.values.value, [other: FakeAttestor.keyId(8)])
    }

    func testTheBuiltInMemoryStoreKeepsScopesApart() {
        let store = MemoryAttestationKeyStore()
        store.setKeyId("one", scope: "a")
        store.setKeyId("two", scope: "b")
        XCTAssertEqual(store.keyId(scope: "a"), "one")
        store.setKeyId(nil, scope: "a")
        XCTAssertNil(store.keyId(scope: "a"))
        XCTAssertEqual(store.keyId(scope: "b"), "two")
    }

    // MARK: - Defaults on this platform

    func testTheDefaultAttestorNeverCrashesWhereAppAttestIsMissing() async throws {
        // On a Mac running `swift test` App Attest is not usable; whatever the answer,
        // asking must be safe and the unsupported stand-in must refuse politely.
        _ = defaultAppAttestor().isSupported
        let none = UnsupportedAttestor()
        XCTAssertFalse(none.isSupported)
        do {
            _ = try await none.generateKey()
            XCTFail("Expected an error")
        } catch {}
    }

    // MARK: - Errors carry nothing private

    func testErrorsNeverContainTheKeyTheTokenThePayloadOrTheProof() async throws {
        var errors: [StrybokError] = []
        func collect(_ arrange: (Harness) -> Void, sharedFirst: Bool = false) async throws {
            let harness = Harness()
            let sdk = harness.sdk()
            if sharedFirst { try await share(sdk) }
            arrange(harness)
            if let error = await failure(sdk) { errors.append(error) }
        }
        try await collect { $0.onLinks.value = { _ in refusal(401, "ATTESTATION_REQUIRED") } }
        try await collect { $0.onLinks.value = { _ in refusal(401, "ATTESTATION_INVALID", reason: "expired") } }
        try await collect(
            {
                $0.onLinks.value = { _ in refusal(401, "ATTESTATION_INVALID", reason: "exhausted") }
                $0.onAssert.value = { _ in refusal(403, "ATTESTATION_FAILED", reason: "signature") }
            }, sharedFirst: true)
        try await collect { $0.onChallenge.value = { _ in refusal(401, "UNAUTHENTICATED") } }
        try await collect { $0.onRegister.value = { _ in refusal(401, "UNAUTHENTICATED") } }
        try await collect { $0.onLinks.value = { _ in refusal(503, "ATTESTATION_NOT_CONFIGURED") } }
        try await collect { $0.onLinks.value = { _ in throw Offline() } }
        try await collect {
            $0.onLinks.value = { request in
                // A service that echoes what it was sent must not leak through the reason.
                let token = request.value(forHTTPHeaderField: "X-Strybok-Attestation") ?? ""
                return .json(
                    #"{"error":{"code":"ATTESTATION_INVALID","details":{"reason":"\#(token)"}}}"#,
                    statusCode: 401)
            }
        }
        XCTAssertEqual(errors.count, 8)

        let secrets = [
            key, "session-token", "payload-marker-7731", "challenge-", FakeAttestor.keyId(1), "+//+AQ==",
            "+/+/AgM=",
        ]
        for error in errors {
            let text = visibleText(error)
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(secret) leaked in: \(text)")
            }
        }
    }
}
