import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

// Campaign values (SDK contract, "Campaign query"): what of a tapped URL's query is sent
// to resolve, what the resolved link carries, and what `app_open` reports.

private func resolved(_ extra: String = "") -> StrybokHTTPResponse {
    .json(#"{"linkId":"link_1","appId":"app_1","routePath":"/x"\#(extra)}"#)
}

/// The resolve request URL for `lookup`, written out byte for byte.
private func resolveURL(for lookup: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return "https://api.strybok.com/v1/public/resolve?url="
        + lookup.addingPercentEncoding(withAllowedCharacters: allowed)!
}

final class CampaignQueryTests: XCTestCase {
    func testIsEmptyWhenThereIsNoQueryOrNothingOfOursInIt() {
        for query in [
            nil, "", "&", "&&&", "=", "utm_source", "utm_source=", "token=secret", "utm=1",
            "utm_id=42&gclid=x&fbclid=y", "a=/b/c&d=%2F",
        ] as [String?] {
            XCTAssertEqual(CampaignQuery.make(from: query), "", query ?? "nil")
        }
    }

    func testKeepsTheFiveKeysAndNothingElse() {
        let all =
            "utm_source=instagram&utm_medium=social&utm_campaign=spring&utm_term=shoes&utm_content=banner"
        XCTAssertEqual(CampaignQuery.make(from: all), all)
        XCTAssertEqual(
            CampaignQuery.make(
                from: "token=secret&utm_source=a&utm_id=7&utm_sourcex=b&xutm_medium=c&gclid=d"),
            "utm_source=a")
    }

    func testWritesTheKeptPairsInTheFixedOrder() {
        XCTAssertEqual(
            CampaignQuery.make(
                from: "utm_content=e&x=1&utm_term=d&utm_campaign=c&utm_medium=b&y=2&utm_source=a"),
            "utm_source=a&utm_medium=b&utm_campaign=c&utm_term=d&utm_content=e")
        XCTAssertEqual(
            CampaignQuery.make(from: "utm_content=e&utm_medium=b"), "utm_medium=b&utm_content=e")
    }

    func testComparesKeyNamesExactlyInLowerCase() {
        XCTAssertEqual(
            CampaignQuery.make(
                from: "UTM_SOURCE=a&Utm_Medium=b&utm_Campaign=c&utm-term=d&utm_content%20=e"),
            "")
        XCTAssertEqual(CampaignQuery.make(from: "UTM_SOURCE=a&utm_source=b"), "utm_source=b")
    }

    func testTakesTheFirstOccurrenceOfAKeyEvenWhenItsValueIsDropped() {
        XCTAssertEqual(
            CampaignQuery.make(from: "utm_source=first&utm_source=second"), "utm_source=first")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=two%20words&utm_source=second"), "")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=&utm_source=second"), "")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source&utm_source=second"), "")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=%zz&utm_source=second"), "")
        XCTAssertEqual(
            CampaignQuery.make(from: "utm_medium=a&utm_source=b&utm_medium=c&utm_source=d"),
            "utm_source=b&utm_medium=a")
    }

    func testDropsValuesThatAreEmptyTooLongOrOutsideTheAllowedCharacters() {
        let allowed = "AZaz09._~-"
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=\(allowed)"), "utm_source=\(allowed)")
        let longest = String(repeating: "a", count: 64)
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=\(longest)"), "utm_source=\(longest)")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=\(longest)a"), "")
        for value in [
            "", "two%20words", "two+words", "a%2Bb", "a@b.c", "a%40b.c", "a/b", "a%2Fb", "a%25b",
            "a%26b", "a%3Db", "a=b", "a,b", "a:b", "a!b", "(other)", "%22quoted%22", "it's", "<b>",
            "caf%C3%A9", "caf\u{e9}", "%D0%B2%D0%B5%D1%81%D0%BD%D0%B0", "a%00b", "a%0Ab", "%", "%4",
            "%zz", "%FF", "%C3", "\u{1F600}",
        ] {
            XCTAssertEqual(
                CampaignQuery.make(from: "utm_source=\(value)&utm_medium=ok"), "utm_medium=ok", value)
        }
    }

    func testPercentDecodesKeysAndValuesBeforeCheckingThem() {
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=%69nstagram"), "utm_source=instagram")
        XCTAssertEqual(CampaignQuery.make(from: "utm%5Fsource=a"), "utm_source=a")
        XCTAssertEqual(CampaignQuery.make(from: "utm%5fsource=a"), "utm_source=a")
        XCTAssertEqual(
            CampaignQuery.make(from: "%75tm_medium=spring%5Fsale%2D1%2E0%7E"),
            "utm_medium=spring_sale-1.0~")
        // A `+` is a space, in keys too, so neither side can match.
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=a+b&utm+medium=c"), "")
        // An encoded separator is part of the value, not a separator.
        XCTAssertEqual(CampaignQuery.make(from: "x=1%26utm_source=a"), "")
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=a%26utm_medium=b"), "")
        // A key whose own escape is malformed is not one of ours and is not a first occurrence.
        XCTAssertEqual(CampaignQuery.make(from: "utm_source%zz=a&utm_source=b"), "utm_source=b")
    }

    func testSplitsEachPartOnItsFirstEqualsSignOnly() {
        XCTAssertEqual(CampaignQuery.make(from: "utm_source=a=b&utm_medium=c"), "utm_medium=c")
        XCTAssertEqual(CampaignQuery.make(from: "=utm_source&utm_medium=c"), "utm_medium=c")
    }
}

final class CampaignResolveRequestTests: XCTestCase {
    func testSendsTheExampleOfTheContractExactlyAsWrittenThere() async throws {
        let api = FakeAPI()
        let sdk = Strybok(
            configuration: StrybokConfiguration(
                apiBaseURL: apiBase, allowedHosts: ["myapp.strybok.link"],
                transport: api.transport))
        let tapped = url(
            "https://MyApp.strybok.link/invite777?utm_source=instagram&fbclid=abc&utm_medium=two%20words&utm_source=x#top"
        )
        let link = try await sdk.resolve(tapped)

        XCTAssertEqual(link.url, tapped)
        XCTAssertEqual(api.resolves.value.count, 1)
        let request = try XCTUnwrap(api.resolves.value.first)
        XCTAssertEqual(
            lookup(of: request), "https://myapp.strybok.link/invite777?utm_source=instagram")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.strybok.com/v1/public/resolve"
                + "?url=https%3A%2F%2Fmyapp.strybok.link%2Finvite777%3Futm_source%3Dinstagram")
    }

    func testSendsAllFiveValuesInTheFixedOrderAndNothingElseOfTheURL() async throws {
        let api = FakeAPI()
        _ = try await makeSDK(api).resolve(
            url(
                "https://\(host)/invite777?utm_content=banner&token=secret&utm_term=shoes&email=a%40b.c"
                    + "&utm_campaign=spring_sale&gclid=G1&utm_medium=social&utm_id=7&utm_source=instagram#private"
            ))
        let request = try XCTUnwrap(api.resolves.value.first)
        let sent = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(
            sent,
            resolveURL(
                for: "https://\(host)/invite777?utm_source=instagram&utm_medium=social"
                    + "&utm_campaign=spring_sale&utm_term=shoes&utm_content=banner"))
        // One query parameter only: the campaign values travel inside `url`, encoded.
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
            ["url"])
        for leaked in ["secret", "token", "email", "b.c", "gclid", "G1", "utm_id", "private"] {
            XCTAssertFalse(sent.contains(leaked), leaked)
        }
    }

    func testDropsBadValuesTakesTheFirstOfARepeatedKeyAndDecodesFirst() async throws {
        let longest = String(repeating: "a", count: 64)
        let cases: [(query: String, sent: String)] = [
            ("utm_source=first&utm_source=second", "?utm_source=first"),
            ("utm_source=two%20words&utm_source=second", ""),
            ("utm_source=a+b&utm_medium=ok", "?utm_medium=ok"),
            ("utm_source=%69nstagram", "?utm_source=instagram"),
            ("utm%5Fsource=instagram", "?utm_source=instagram"),
            ("utm_source=a%40b.c&utm_medium=%D0%B2", ""),
            ("utm_source=\(longest)", "?utm_source=\(longest)"),
            ("utm_source=\(longest)a", ""),
            ("utm_source=&utm_medium", ""),
            ("UTM_SOURCE=a&Utm_Medium=b", ""),
        ]
        for (query, sent) in cases {
            let api = FakeAPI()
            _ = try await makeSDK(api).resolve(url("https://\(host)/invite777?\(query)"))
            XCTAssertEqual(
                api.resolves.value.first?.url?.absoluteString,
                resolveURL(for: "https://\(host)/invite777\(sent)"), query)
        }
    }

    func testSendsExactlyTheEarlierRequestWhenNoCampaignValueIsLeft() async throws {
        // What versions before 0.4.0 sent.
        let before = "https://api.strybok.com/v1/public/resolve?url=https%3A%2F%2F\(host)%2Finvite777"
        for suffix in [
            "", "?", "#utm_source=instagram", "?token=secret#f", "?utm_source=two%20words",
            "?utm_id=1&fbclid=2", "?#",
        ] {
            let api = FakeAPI()
            _ = try await makeSDK(api).resolve(url("https://\(host)/invite777\(suffix)"))
            let request = try XCTUnwrap(api.resolves.value.first)
            XCTAssertEqual(request.url?.absoluteString, before, suffix)
            XCTAssertEqual(request.httpMethod, "GET", suffix)
            XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"], suffix)
            XCTAssertNil(request.httpBody, suffix)
        }
    }

    func testChangesNothingElseOfTheRequestAndRetriesSendTheSameOne() async throws {
        let calls = Box(0)
        let api = FakeAPI { _ in
            calls.mutate({ $0 += 1; return $0 }) < 3 ? StrybokHTTPResponse(statusCode: 503) : resolved()
        }
        _ = try await makeSDK(api).resolve(url("https://\(host)/invite777?utm_source=instagram&x=1"))
        XCTAssertEqual(api.resolves.value.count, 3)
        for request in api.resolves.value {
            XCTAssertEqual(
                request.url?.absoluteString,
                resolveURL(for: "https://\(host)/invite777?utm_source=instagram"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
            XCTAssertNil(request.httpBody)
        }
    }

    func testAQueryNeverMakesAForeignURLOursAndErrorsKeepTheURLAsReceived() async {
        let api = FakeAPI { _ in StrybokHTTPResponse(statusCode: 404) }
        let sdk = makeSDK(api)
        let query = "?utm_source=instagram"
        for candidate in [
            "https://evil.example.com/invite777",
            "https://\(host).evil.example.com/invite777",
            "http://\(host)/invite777",
            "https://user@\(host)/invite777",
            "https://user:pw@\(host)/invite777",
            "https://\(host):8443/invite777",
            "https://\(host)/a/b",
            "https://\(host)/invite777/",
            "https://\(host)/a.b",
            "https://\(host)/a%2Fb",
            "https://\(host)/",
            "https://\(host)",
            "https://\(host)/" + String(repeating: "a", count: 65),
        ] {
            for target in [url(candidate), url(candidate + query)] {
                XCTAssertFalse(sdk.isStrybokLink(target), target.absoluteString)
                XCTAssertFalse(sdk.handle(target), target.absoluteString)
                // `assertThrows` also checks that the error carries the URL as received.
                await assertThrows(sdk, target) {
                    if case .unsupportedLink = $0 { return true }
                    return false
                }
            }
        }
        // What looks like an authority inside the query is only text.
        XCTAssertFalse(sdk.isStrybokLink(url("https://evil.example.com/abc?utm_source=\(host)")))
        XCTAssertTrue(sdk.isStrybokLink(url("https://\(host)/invite777\(query)")))
        XCTAssertTrue(
            sdk.isStrybokLink(url("https://\(host)/invite777?utm_source=x@evil.example.com:8443/y")))
        XCTAssertTrue(sdk.isStrybokLink(url("https://\(host):443/invite777\(query)")))
        XCTAssertTrue(api.resolves.value.isEmpty)

        await assertThrows(sdk, url("https://\(host)/invite777?utm_source=instagram&token=secret")) {
            if case .linkNotFound = $0 { return true }
            return false
        }
    }
}

final class CampaignResponseTests: XCTestCase {
    func testIsWhatTheServerSent() async throws {
        let api = FakeAPI { _ in
            resolved(#","campaign":{"source":"instagram","medium":"social","campaign":"spring"}"#)
        }
        let link = try await makeSDK(api).resolve(url("https://\(host)/invite777?utm_source=instagram"))
        XCTAssertEqual(
            link.campaign, LinkCampaign(source: "instagram", medium: "social", campaign: "spring"))
        XCTAssertEqual(link.campaign.source, "instagram")
        XCTAssertNil(link.campaign.term)
        XCTAssertNil(link.campaign.content)
        XCTAssertFalse(link.campaign.isEmpty)
    }

    func testKeepsAllFiveFields() async throws {
        let api = FakeAPI { _ in
            resolved(#","campaign":{"source":"a","medium":"b","campaign":"c","term":"d","content":"e"}"#)
        }
        let link = try await makeSDK(api).resolve(invite)
        XCTAssertEqual(
            link.campaign,
            LinkCampaign(source: "a", medium: "b", campaign: "c", term: "d", content: "e"))
    }

    func testComesFromTheAnswerNotFromTheURL() async throws {
        let api = FakeAPI { _ in resolved(#","campaign":{"source":"newsletter"}"#) }
        let link = try await makeSDK(api).resolve(
            url("https://\(host)/invite777?utm_source=instagram&utm_medium=social"))
        XCTAssertEqual(link.campaign, LinkCampaign(source: "newsletter"))

        let none = try await makeSDK(FakeAPI { _ in resolved() }).resolve(
            url("https://\(host)/invite777?utm_source=instagram"))
        XCTAssertTrue(none.campaign.isEmpty)
    }

    func testIsEmptyWhenMissingOrNotAnObject() async throws {
        for campaign in [
            "", #","campaign":null"#, #","campaign":"instagram""#, #","campaign":42"#,
            #","campaign":true"#, #","campaign":[]"#, #","campaign":["instagram"]"#,
            #","campaign":{}"#,
        ] {
            let link = try await makeSDK(FakeAPI { _ in resolved(campaign) }).resolve(invite)
            XCTAssertEqual(link.campaign, LinkCampaign(), campaign)
            XCTAssertTrue(link.campaign.isEmpty, campaign)
            XCTAssertEqual(link.routePath, "/x", campaign)
        }
    }

    func testIgnoresFieldsThatAreNotStringsAndKeysItDoesNotKnow() async throws {
        let api = FakeAPI { _ in
            resolved(
                #","campaign":{"source":"instagram","medium":7,"campaign":null,"term":{"a":1},"#
                    + #""content":["x"],"id":"ignored","utm_source":"ignored","Source":"ignored"}"#)
        }
        let link = try await makeSDK(api).resolve(invite)
        XCTAssertEqual(link.campaign, LinkCampaign(source: "instagram"))
        XCTAssertEqual(link.campaign.fields, ["source": "instagram"])
    }

    func testAMalformedAnswerIsStillAnErrorWithOrWithoutCampaign() async {
        let api = FakeAPI { _ in .json(#"{"linkId":"l","campaign":{"source":"a"}}"#) }
        await assertThrows(makeSDK(api), invite) {
            if case .server(_, statusCode: 200) = $0 { return true }
            return false
        }
    }

    func testIsDeliveredToListenersAndByInitialLink() async {
        let api = FakeAPI { _ in resolved(#","campaign":{"source":"instagram"}"#) }
        let source = FakeLinkSource(
            launchURL: url("https://\(host)/invite777?utm_source=instagram"))
        let sdk = makeSDK(api, source: source)
        await sdk.start()
        let initial = await sdk.initialLink()
        XCTAssertEqual(initial?.campaign, LinkCampaign(source: "instagram"))

        let received = collect(sdk)
        sdk.handle(url("https://\(host)/other?utm_source=instagram"))
        await waitUntil("delivered") { received.value.count == 1 }
        XCTAssertEqual(received.value.map(\.campaign), [LinkCampaign(source: "instagram")])
    }

    func testLinkCampaignIsAValue() {
        XCTAssertTrue(LinkCampaign().isEmpty)
        XCTAssertFalse(LinkCampaign(term: "x").isEmpty)
        XCTAssertEqual(LinkCampaign(source: "a", content: "b"), LinkCampaign(source: "a", content: "b"))
        XCTAssertNotEqual(LinkCampaign(source: "a"), LinkCampaign(medium: "a"))
        XCTAssertEqual(
            LinkCampaign(source: "a", medium: "b").description, "LinkCampaign(medium: b, source: a)")
        // Existing code that builds a link without a campaign keeps compiling.
        let link = ResolvedLink(url: invite, linkId: "l", appId: "a", routePath: "/x")
        XCTAssertEqual(link.campaign, LinkCampaign())
        XCTAssertNotEqual(
            link,
            ResolvedLink(
                url: invite, linkId: "l", appId: "a", routePath: "/x",
                campaign: LinkCampaign(source: "a")))
    }
}

final class CampaignAppOpenTests: XCTestCase {
    private func event(
        answer: String, tapped: String = "https://\(host)/invite777"
    ) async throws -> (event: [String: Any], body: Data) {
        let api = FakeAPI { _ in resolved(answer) }
        let sdk = makeSDK(api)
        _ = collect(sdk)
        await sdk.start()
        sdk.handle(url(tapped))
        await waitUntil("event sent") { api.eventBodies.value.count == 1 }
        await settle()
        XCTAssertEqual(api.events.count, 1)
        return (try XCTUnwrap(api.events.first), try XCTUnwrap(api.eventBodies.value.first))
    }

    func testReportsTheCampaignExactlyAsResolveReturnedIt() async throws {
        let (event, _) = try await event(
            answer: #","campaign":{"source":"instagram","medium":"social","id":"x","term":5}"#,
            // The URL says something else: it is never the source of the reported values.
            tapped: "https://\(host)/invite777?utm_source=facebook&utm_term=shoes&utm_content=banner")
        XCTAssertEqual(
            Set(event.keys), ["eventId", "linkId", "type", "platform", "sdkVersion", "campaign"])
        XCTAssertEqual(
            event["campaign"] as? [String: String], ["source": "instagram", "medium": "social"])
        XCTAssertEqual(event["type"] as? String, "app_open")
        XCTAssertEqual(event["linkId"] as? String, "link_1")
        XCTAssertEqual(event["sdkVersion"] as? String, Strybok.sdkVersion)
        let eventId = try XCTUnwrap(event["eventId"] as? String)
        XCTAssertNotNil(UUID(uuidString: eventId))
        XCTAssertEqual(eventId, eventId.lowercased())
    }

    func testReportsAllFiveFieldsWhenResolveReturnedThem() async throws {
        let (event, _) = try await event(
            answer: #","campaign":{"source":"a","medium":"b","campaign":"c","term":"d","content":"e"}"#)
        XCTAssertEqual(
            event["campaign"] as? [String: String],
            ["source": "a", "medium": "b", "campaign": "c", "term": "d", "content": "e"])
    }

    func testOmitsCampaignWhenResolveReturnedNoneWhateverTheURLSays() async throws {
        for answer in ["", #","campaign":{}"#, #","campaign":null"#, #","campaign":{"source":1}"#] {
            let (event, body) = try await event(
                answer: answer, tapped: "https://\(host)/invite777?utm_source=instagram")
            XCTAssertEqual(
                Set(event.keys), ["eventId", "linkId", "type", "platform", "sdkVersion"], answer)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("campaign"), answer)
        }
    }
}

final class CampaignDuplicateTests: XCTestCase {
    func testTheSameSlugWithDifferentCampaignValuesIsTwoLinks() async {
        let api = FakeAPI { request in
            let sent = lookup(of: request) ?? ""
            let source = sent.components(separatedBy: "utm_source=").dropFirst().first ?? "none"
            return resolved(#","campaign":{"source":"\#(source)"}"#)
        }
        let sdk = makeSDK(api)
        let received = collect(sdk)
        await sdk.start()

        sdk.handle(url("https://\(host)/invite777?utm_source=instagram"))
        sdk.handle(url("https://\(host)/invite777?utm_source=facebook"))
        sdk.handle(invite)
        await waitUntil("three links") { received.value.count == 3 }
        await waitUntil("three events") { api.eventBodies.value.count == 3 }
        XCTAssertEqual(
            Set(received.value.compactMap(\.campaign.source)), ["instagram", "facebook", "none"])
        XCTAssertEqual(api.resolves.value.count, 3)
        XCTAssertEqual(
            Set(api.events.compactMap { ($0["campaign"] as? [String: String])?["source"] }),
            ["instagram", "facebook", "none"])
    }

    func testComparesTheURLAsReceivedNotTheLookup() async {
        let api = FakeAPI()
        let sdk = makeSDK(api)
        let received = collect(sdk)
        await sdk.start()

        // The identical string is one tap.
        sdk.handle(url("https://\(host)/invite777?utm_source=instagram&x=1"))
        sdk.handle(url("https://\(host)/invite777?utm_source=instagram&x=1"))
        await waitUntil("first link") { received.value.count == 1 }
        await settle()
        XCTAssertEqual(received.value.count, 1)

        // Different strings are different links, even when they send the same lookup.
        sdk.handle(url("https://\(host)/invite777?utm_source=instagram&x=2"))
        sdk.handle(url("https://\(host)/invite777?x=2&utm_source=instagram"))
        await waitUntil("three links") { received.value.count == 3 }
        await settle()
        XCTAssertEqual(
            Set(received.value.map(\.url.absoluteString)),
            [
                "https://\(host)/invite777?utm_source=instagram&x=1",
                "https://\(host)/invite777?utm_source=instagram&x=2",
                "https://\(host)/invite777?x=2&utm_source=instagram",
            ])
        XCTAssertEqual(Set(api.resolves.value.compactMap(\.url?.absoluteString)).count, 1)
        XCTAssertEqual(api.resolves.value.count, 3)
    }

    func testALaunchLinkReportedTwiceWithItsQueryIsDeliveredOnce() async {
        let api = FakeAPI { _ in resolved(#","campaign":{"source":"instagram"}"#) }
        let tapped = url("https://\(host)/invite777?utm_source=instagram")
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: tapped))
        let received = collect(sdk)
        sdk.handle(tapped)
        await sdk.start()
        await waitUntil("delivered") { received.value.count == 1 }
        await settle()
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(api.resolves.value.count, 1)
        XCTAssertEqual(api.eventBodies.value.count, 1)
    }
}
