import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

// Links without an API call (SDK contract, "Links without an API call"): the `parameterLinks`
// option, which URLs are ours with it, what is sent, and what stays as it was.

/// The shared test vectors of the SDK contract. `Fixtures/parameter-links-vectors.json` is a
/// byte-identical copy of the contract's file, declared as a resource of this test target.
struct ParameterLinkVectors: Decodable {
    struct Option: Decodable {
        let payloadKeys: [String]
    }

    struct Lookup: Decodable {
        let name: String
        let parameterLinks: Option?
        let url: String
        /// What goes into the `url` parameter of resolve; `nil`: the URL is not ours.
        let lookup: String?
    }

    struct Configuration: Decodable {
        let name: String
        let parameterLinks: Option?
        let valid: Bool
    }

    let allowedHosts: [String]
    let lookups: [Lookup]
    let configurations: [Configuration]

    static func load() throws -> ParameterLinkVectors {
        let file = try XCTUnwrap(
            Bundle.module.url(forResource: "parameter-links-vectors", withExtension: "json"),
            "the vectors are a resource of the test target")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
}

/// The resolve request for `lookup`, written out byte for byte: every byte outside
/// `A-Z a-z 0-9 - . _ ~` as `%XX`.
private func resolveRequestURL(_ lookup: String) -> String {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    let encoded = lookup.utf8.map { byte -> String in
        if unreserved.contains(byte) { return String(Character(Unicode.Scalar(byte))) }
        return "%" + (byte < 0x10 ? "0" : "") + String(byte, radix: 16, uppercase: true)
    }
    return "https://api.strybok.com/v1/public/resolve?url=" + encoded.joined()
}

/// `string` as a `URL` holding exactly that text, or `nil` when Foundation cannot represent it
/// unchanged: from iOS 17 and macOS 14 `URL(string:)` percent-encodes what RFC 3986 does not
/// allow (a raw `é`, `"`, `|`, `[`, a lone `%`), earlier versions refuse it.
private func exactURL(_ string: String) -> URL? {
    let url: URL?
    if #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) {
        url = URL(string: string, encodingInvalidCharacters: false)
    } else {
        url = URL(string: string)
    }
    return url?.absoluteString == string ? url : nil
}

/// Host, path and query of an `https` URL string, split as the contract describes, for strings
/// no `URL` can hold.
private func rawParts(_ string: String) -> (host: String, path: String, query: String?)? {
    guard string.hasPrefix("https://") else { return nil }
    let rest = string.dropFirst("https://".count)
    let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
    let authority = rest[..<authorityEnd]
    guard !authority.contains("@"), !authority.contains(":") else { return nil }
    let tail = rest[authorityEnd...]
    let pathEnd = tail.firstIndex { "?#".contains($0) } ?? tail.endIndex
    var query: String?
    if pathEnd < tail.endIndex, tail[pathEnd] == "?" {
        query = String(tail[tail.index(after: pathEnd)...].prefix { $0 != "#" })
    }
    return (authority.lowercased(), String(tail[..<pathEnd]), query)
}

private func parameterLinks(_ keys: [String]) -> ParameterLinks {
    try! ParameterLinks(payloadKeys: keys)
}

/// A resolve answer for a path or long link.
private func pathAnswer(
    linkId: String = "lnk_paths_app_1", route: String = "/catalog/item",
    payload: String = #"{"id":"from-the-service"}"#
) -> StrybokHTTPResponse {
    .json(
        #"{"linkId":"\#(linkId)","appId":"app_1","routePath":"\#(route)","payload":\#(payload),"#
            + #""campaign":{"source":"service"}}"#)
}

final class ParameterLinkVectorTests: XCTestCase {
    private func vectorConfiguration(
        _ vectors: ParameterLinkVectors, _ option: ParameterLinks?, _ api: FakeAPI
    ) -> StrybokConfiguration {
        StrybokConfiguration(
            apiBaseURL: apiBase,
            allowedHosts: Set(vectors.allowedHosts),
            maxRetries: 0,
            reportAppOpens: false,
            parameterLinks: option,
            transport: api.transport)
    }

    func testEveryLookupCase() async throws {
        let vectors = try ParameterLinkVectors.load()
        XCTAssertFalse(vectors.lookups.isEmpty)
        var ran = 0
        var unrepresentable: [String] = []

        for vector in vectors.lookups {
            let name = vector.name
            let option = try vector.parameterLinks.map { try ParameterLinks(payloadKeys: $0.payloadKeys) }

            guard let tapped = exactURL(vector.url) else {
                // No `URL` holds this text, so the SDK can never be handed it: Foundation would
                // percent-encode it into another URL first (or refuse it). The rules still give
                // the expected answer for the raw text, and the request is encoded as for any.
                unrepresentable.append(name)
                XCTAssertNotEqual(URL(string: vector.url)?.absoluteString, vector.url, name)
                let parts = try XCTUnwrap(rawParts(vector.url), name)
                XCTAssertTrue(vectors.allowedHosts.contains(parts.host), name)
                let lookup = LinkLookup.make(
                    host: parts.host, path: parts.path, query: parts.query, options: option)
                XCTAssertEqual(lookup, vector.lookup, name)
                if let lookup {
                    let sdk = Strybok(configuration: vectorConfiguration(vectors, option, FakeAPI()))
                    XCTAssertEqual(
                        sdk.endpoint("/v1/public/resolve", lookup: lookup).absoluteString,
                        resolveRequestURL(lookup), name)
                }
                ran += 1
                continue
            }

            // resolve(_:)
            let api = FakeAPI()
            let sdk = Strybok(configuration: vectorConfiguration(vectors, option, api))
            XCTAssertEqual(sdk.isStrybokLink(tapped), vector.lookup != nil, name)
            if let lookup = vector.lookup {
                do {
                    let link = try await sdk.resolve(tapped)
                    XCTAssertEqual(link.url, tapped, name)
                } catch {
                    XCTFail("\(name): \(error)")
                }
                XCTAssertEqual(api.resolves.value.count, 1, name)
                let request = try XCTUnwrap(api.resolves.value.first, name)
                XCTAssertEqual(request.httpMethod, "GET", name)
                XCTAssertEqual(request.url?.absoluteString, resolveRequestURL(lookup), name)
                XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"], name)
                XCTAssertNil(request.httpBody, name)
            } else {
                // Also checks that the error carries the URL as received.
                await assertThrows(sdk, tapped) {
                    if case .unsupportedLink = $0 { return true }
                    return false
                }
                XCTAssertTrue(api.resolves.value.isEmpty, "\(name): no request")
            }
            sdk.stop()

            // The automatic flow: the URL arrives from the OS and launches the app.
            let flowAPI = FakeAPI()
            let errors = Box<[StrybokError]>([])
            var configuration = vectorConfiguration(vectors, option, flowAPI)
            configuration.onError = { errors.append($0) }
            let flow = Strybok(configuration: configuration)
            let received = collect(flow)
            XCTAssertEqual(flow.handle(tapped), vector.lookup != nil, name)
            await flow.start()
            XCTAssertEqual(
                flowAPI.resolves.value.compactMap(\.url?.absoluteString),
                vector.lookup.map { [resolveRequestURL($0)] } ?? [], name)
            if vector.lookup != nil {
                await waitUntil("\(name): delivered") { received.value.count == 1 }
                XCTAssertEqual(received.value.first?.url, tapped, name)
            } else {
                XCTAssertTrue(received.value.isEmpty, name)
            }
            XCTAssertTrue(errors.value.isEmpty, "\(name): \(errors.value)")
            flow.stop()
            ran += 1
        }

        XCTAssertEqual(ran, vectors.lookups.count, "every case ran")
        // Only strings with characters or escapes that RFC 3986 does not allow take the raw path;
        // every other case went through resolve(_:) and the automatic flow.
        print("Vector cases no URL can hold, checked on the raw text: \(unrepresentable)")
    }

    /// More cases next to the shared file (the Kotlin Multiplatform SDK runs the same table):
    /// strict UTF-8, UTF-16 lengths, dot segments and reserved paths, and deep links.
    func testMoreCasesBeyondTheSharedVectors() throws {
        let link = "https://myapp.strybok.link"
        let emoji = "%F0%9F%98%80"
        let cases: [(url: String, lookup: String?)] = [
            ("\(link)/p?id=%C0%80&lang=uk", "\(link)/p?lang=uk"),  // overlong
            ("\(link)/p?id=%ED%A0%80&lang=uk", "\(link)/p?lang=uk"),  // a surrogate
            ("\(link)/p?id=%F4%90%80%80&lang=uk", "\(link)/p?lang=uk"),  // above U+10FFFF
            ("\(link)/p?id=%f0%9f%98%80", "\(link)/p?id=\(emoji)"),
            ("\(link)/p?id=%C2%85&lang=%C2%A0", "\(link)/p?lang=%C2%A0"),  // U+0085 is a control
            ("\(link)/p?id=" + String(repeating: emoji, count: 128), "\(link)/p?id=" + String(repeating: emoji, count: 128)),
            ("\(link)/p?id=" + String(repeating: emoji, count: 129), "\(link)/p"),  // 258 UTF-16 units
            ("\(link)/p?id=a&id=b&lang=", "\(link)/p?id=a"),
            ("\(link)/p?%69%64=x&id=y", "\(link)/p?id=x"),
            ("\(link)/p?id%zz=1&id=2", "\(link)/p?id=2"),
            ("\(link)/a/%2e", nil),
            ("\(link)/a/.%2E/b", nil),
            ("\(link)/%2e%2e%2e", "\(link)/%2e%2e%2e"),
            ("\(link)/.well-knownx", "\(link)/.well-knownx"),
            ("\(link)/_strybok/", nil),
            ("\(link)/Favicon.ico", "\(link)/Favicon.ico"),
            ("\(link)/?link=HTTPS%3A%2F%2FEXAMPLE.COM%2FP%3FID%3D1%26id%3D2", "\(link)/?link=https%3A%2F%2Fexample.com%2FP%3Fid%3D2"),
            ("\(link)/?link=https%3A%2F%2Fexample.com%3Fid%3D1", "\(link)/?link=https%3A%2F%2Fexample.com%2F%3Fid%3D1"),
            ("\(link)/?link=https%3A%2F%2Fexample.com%23x%3Fid%3D1", "\(link)/?link=https%3A%2F%2Fexample.com%2F"),
            ("\(link)/?link=https%3A%2F%2Fexample.com%2Fcaf%C3%A9", "\(link)/?link=https%3A%2F%2Fexample.com%2Fcaf%C3%A9"),
            ("\(link)/?link=https%3A%2F%2Fexample.com%2Fa%5Cb", nil),
            ("\(link)/?link=https%3A%2F%2Fexample.com&apn", "\(link)/?link=https%3A%2F%2Fexample.com%2F&apn="),
            ("\(link)/?link=http%3A%2F%2Fexample.com%2Fp&utm_source=a&apn=x&ibi=y", "\(link)/?link=http%3A%2F%2Fexample.com%2Fp&apn=x&ibi=y&utm_source=a"),
            ("\(link)/?link=https%3A%2F%2Fexample.com%2Fp%3Fid%3D%25zz", "\(link)/?link=https%3A%2F%2Fexample.com%2Fp"),
            ("\(link)/?link=%zz", nil),
            ("\(link)/?link=https%3A%2F%2Fexample.com&link=x&id=7", "\(link)/?link=https%3A%2F%2Fexample.com%2F"),
        ]
        let option = parameterLinks(["id", "lang"])
        for (string, expected) in cases {
            let parts = try XCTUnwrap(rawParts(string), string)
            XCTAssertEqual(
                LinkLookup.make(host: parts.host, path: parts.path, query: parts.query, options: option),
                expected, string)
        }
    }

    func testEveryConfigurationCase() throws {
        let vectors = try ParameterLinkVectors.load()
        XCTAssertFalse(vectors.configurations.isEmpty)
        for vector in vectors.configurations {
            guard let keys = vector.parameterLinks?.payloadKeys else {
                // Not setting the option is always valid.
                XCTAssertTrue(vector.valid, vector.name)
                let configuration = StrybokConfiguration(
                    apiBaseURL: apiBase, allowedHosts: Set(vectors.allowedHosts))
                XCTAssertNil(configuration.parameterLinks, vector.name)
                continue
            }
            do {
                let accepted = try ParameterLinks(payloadKeys: keys)
                XCTAssertTrue(vector.valid, "\(vector.name): accepted")
                XCTAssertEqual(accepted.payloadKeys, keys, vector.name)
                let configuration = StrybokConfiguration(
                    apiBaseURL: apiBase, allowedHosts: Set(vectors.allowedHosts),
                    parameterLinks: accepted)
                XCTAssertEqual(configuration.parameterLinks, accepted, vector.name)
            } catch {
                XCTAssertFalse(vector.valid, "\(vector.name): rejected with \(error.message)")
                XCTAssertTrue(error.message.hasPrefix("parameterLinks: "), error.message)
            }
        }
    }
}

final class ParameterLinksOptionTests: XCTestCase {
    func testIsOffByDefault() {
        XCTAssertNil(StrybokConfiguration(apiBaseURL: apiBase, allowedHosts: [host]).parameterLinks)
    }

    func testAnInvalidOptionCannotBeCreatedAndSaysWhy() {
        let cases: [([String], String)] = [
            ((0...20).map { "k\($0)" }, "at most 20"),
            (["id", "id"], "\"id\" appears twice"),
            ([""], "not 1–40"),
            (["a b"], "not 1–40"),
            (["utm_term"], "read by Strybok"),
            (["Utm_X"], "read by Strybok"),
            (["strybok_click"], "read by Strybok"),
        ]
        for (keys, reason) in cases {
            XCTAssertThrowsError(try ParameterLinks(payloadKeys: keys), "\(keys)") { error in
                let message = (error as? StrybokConfigurationError)?.message ?? ""
                XCTAssertTrue(message.contains(reason), message)
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
    }

    func testTheKeysKeepTheirOrder() throws {
        XCTAssertEqual(try ParameterLinks(payloadKeys: ["lang", "id", "ST"]).payloadKeys, ["lang", "id", "ST"])
        XCTAssertEqual(try ParameterLinks(payloadKeys: []).payloadKeys, [])
    }
}

final class ParameterLinksBehaviourTests: XCTestCase {
    private let keys = parameterLinks(["id", "lang"])

    func testTheDeliveredLinkHasTheRouteAndPayloadOfTheAnswerNotOfTheTappedURL() async throws {
        let api = FakeAPI { _ in pathAnswer() }
        let sdk = makeSDK(api, parameterLinks: keys)
        let received = collect(sdk)
        await sdk.start()

        let tapped = url("https://\(host)/product/42?id=7&lang=uk&utm_source=tapped&secret=x#reviews")
        XCTAssertTrue(sdk.handle(tapped))
        await waitUntil("delivered") { received.value.count == 1 }
        let link = try XCTUnwrap(received.value.first)
        XCTAssertEqual(link.url, tapped, "the URL as received")
        XCTAssertEqual(link.routePath, "/catalog/item", "never the tapped path")
        XCTAssertEqual(link.payload, ["id": "from-the-service"], "never read from the URL")
        XCTAssertEqual(link.linkId, "lnk_paths_app_1")
        XCTAssertEqual(link.campaign, LinkCampaign(source: "service"))
        XCTAssertFalse(link.isDeferred)
        XCTAssertEqual(
            lookup(of: try XCTUnwrap(api.resolves.value.first)),
            "https://\(host)/product/42?id=7&lang=uk&utm_source=tapped")

        let resolved = try await sdk.resolve(tapped)
        XCTAssertEqual(resolved.routePath, "/catalog/item")
        XCTAssertEqual(resolved.payload, ["id": "from-the-service"])
        sdk.stop()
    }

    func testAnEmptyPayloadInTheAnswerStaysEmpty() async throws {
        let api = FakeAPI { _ in pathAnswer(payload: "null") }
        let link = try await makeSDK(api, parameterLinks: keys).resolve(
            url("https://\(host)/product/42?id=7"))
        XCTAssertEqual(link.payload, [:])
    }

    func testAppOpenCarriesTheLinkIdTheServiceReturned() async throws {
        for (tapped, linkId) in [
            ("https://\(host)/product/42?id=7", "lnk_paths_app_1"),
            ("https://\(host)/?link=https%3A%2F%2Fexample.com%2Fp%3Fid%3D7&apn=com.example.app", "lnk_firebase_app_1"),
        ] {
            let api = FakeAPI { _ in pathAnswer(linkId: linkId) }
            let sdk = makeSDK(api, parameterLinks: keys)
            _ = collect(sdk)
            await sdk.start()
            sdk.handle(url(tapped))
            await waitUntil("event sent") { api.eventBodies.value.count == 1 }
            await settle()
            XCTAssertEqual(api.events.count, 1, tapped)
            let event = try XCTUnwrap(api.events.first)
            XCTAssertEqual(event["linkId"] as? String, linkId, tapped)
            XCTAssertEqual(event["type"] as? String, "app_open")
            XCTAssertEqual(event["campaign"] as? [String: String], ["source": "service"])
            XCTAssertEqual(Set(event.keys), ["eventId", "linkId", "type", "platform", "sdkVersion", "campaign"])
            sdk.stop()
        }
    }

    func testALongLinkSendsTheRebuiltDeepLinkAndIsDeliveredWithTheAnswersRoute() async throws {
        let api = FakeAPI { _ in pathAnswer(linkId: "lnk_firebase_app_1", route: "/product/42") }
        let sdk = makeSDK(api, parameterLinks: keys)
        let tapped = url(
            "https://\(host)/?link=https%3A%2F%2FShop.Example.com%2Fproduct%2F42%3Fid%3D7%26token%3Dsecret%23top"
                + "&apn=com.example.app&ibi=com.example.App&afl=https%3A%2F%2Fexample.com&st=Title&utm_medium=email")
        let link = try await sdk.resolve(tapped)
        XCTAssertEqual(link.routePath, "/product/42")
        XCTAssertEqual(link.url, tapped)
        let sent = try XCTUnwrap(lookup(of: try XCTUnwrap(api.resolves.value.first)))
        XCTAssertEqual(
            sent,
            "https://\(host)/?link=https%3A%2F%2Fshop.example.com%2Fproduct%2F42%3Fid%3D7"
                + "&apn=com.example.app&ibi=com.example.App&utm_medium=email")
        for leaked in ["token", "secret", "top", "afl", "Title"] {
            XCTAssertFalse(sent.contains(leaked), leaked)
        }
    }

    func testAPathThatIsNoLinkIsLinkNotFound() async {
        let api = FakeAPI { _ in .json(#"{"error":{"code":"NOT_FOUND"}}"#, statusCode: 404) }
        let errors = Box<[StrybokError]>([])
        let sdk = makeSDK(api, errors: errors, parameterLinks: keys)
        await sdk.start()
        let tapped = url("https://\(host)/no/such/route")
        XCTAssertTrue(sdk.handle(tapped))
        await waitUntil("error") { errors.value.count == 1 }
        guard case .linkNotFound(let failed)? = errors.value.first else {
            return XCTFail("\(errors.value)")
        }
        XCTAssertEqual(failed, tapped)
        XCTAssertEqual(api.resolves.value.count, 1, "a 404 is not retried")
        sdk.stop()
    }

    func testWithoutTheOptionPathLinksAndLongLinksAreDroppedSilently() async {
        let api = FakeAPI()
        let errors = Box<[StrybokError]>([])
        let sdk = makeSDK(api, errors: errors)
        let received = collect(sdk)
        await sdk.start()
        for candidate in [
            "https://\(host)/product/42?id=7",
            "https://\(host)/?link=https%3A%2F%2Fexample.com%2Fp",
            "https://\(host)/",
            "https://\(host)?id=7",
        ] {
            XCTAssertFalse(sdk.isStrybokLink(url(candidate)), candidate)
            XCTAssertFalse(sdk.handle(url(candidate)), candidate)
        }
        await settle()
        XCTAssertTrue(api.resolves.value.isEmpty)
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(errors.value.isEmpty)
        sdk.stop()
    }

    func testTheSameURLTwiceIsOneTapAndDifferentStringsAreTwoLinks() async {
        let api = FakeAPI { _ in pathAnswer() }
        let sdk = makeSDK(api, parameterLinks: keys)
        let received = collect(sdk)
        await sdk.start()
        sdk.handle(url("https://\(host)/product/42?id=7&x=1"))
        sdk.handle(url("https://\(host)/product/42?id=7&x=1"))
        sdk.handle(url("https://\(host)/product/42?id=7&x=2"))
        await waitUntil("two links") { received.value.count == 2 }
        await settle()
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(api.resolves.value.count, 2)
        XCTAssertEqual(
            Set(api.resolves.value.compactMap { lookup(of: $0) }), ["https://\(host)/product/42?id=7"])
        sdk.stop()
    }

    // MARK: Deferred links keep the slug rule

    func testAPastedLinkMustStillHaveASingleSlug() async {
        let fixture = makeDeferred(parameterLinks: keys)
        for string in [
            "https://\(host)/product/42?strybok_click=\(clickId)",
            "https://\(host)/?strybok_click=\(clickId)",
            "https://\(host)?strybok_click=\(clickId)",
            "https://\(host)/?link=https%3A%2F%2Fexample.com%2Fp&strybok_click=\(clickId)",
        ] {
            let result = await fixture.sdk.redeemPastedLink(string)
            XCTAssertEqual(result, .notOurs, string)
        }
        XCTAssertTrue(fixture.api.all.value.isEmpty, "no request")
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        fixture.sdk.stop()
    }

    func testARedeemAnswerWhoseURLIsNotASlugLinkIsRefused() async {
        for answerURL in [
            "https://\(host)/product/42",
            "https://\(host)/a/b",
            "https://\(host)/",
            "https://\(host)/?link=https%3A%2F%2Fexample.com%2Fp",
        ] {
            let api = DeferredAPI(redeem: { _ in deferredAnswer(url: answerURL) })
            let fixture = makeDeferred(api: api, parameterLinks: keys)
            let received = collect(fixture.sdk)
            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(result, .failed, answerURL)
            XCTAssertEqual(fixture.sdk.deferredLinkStatus, .failed, answerURL)
            XCTAssertEqual(fixture.store.log, ["done"], answerURL)
            await settle()
            XCTAssertTrue(received.value.isEmpty, answerURL)
            // The same URL arriving from the OS is a path link of this app.
            XCTAssertTrue(fixture.sdk.isStrybokLink(url(answerURL)), answerURL)
            fixture.sdk.stop()
        }
    }

    func testAMatchAnswerWhoseURLIsNotASlugLinkIsRefused() async {
        let api = DeferredAPI(match: { _ in
            deferredAnswer(url: "https://\(host)/product/42", extra: #","matched":"probabilistic""#)
        })
        let fixture = makeDeferred(api: api, matching: true, parameterLinks: keys)
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .failed)
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        fixture.sdk.stop()
    }

    func testAPathLinkIsANormalLinkThatWinsOverAGuess() async {
        let fixture = makeDeferred(matching: true, parameterLinks: keys)
        let received = collect(fixture.sdk)
        XCTAssertTrue(fixture.sdk.handle(url("https://\(host)/product/42?id=7")))
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .superseded)
        await waitUntil("delivered") { received.value.count == 1 }
        XCTAssertTrue(fixture.api.matches.value.isEmpty, "no request")
        XCTAssertEqual(received.value.map(\.isDeferred), [false])
        fixture.sdk.stop()
    }
}
