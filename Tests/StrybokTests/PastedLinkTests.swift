import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

/// Options off: nothing of the deferred-link section happens.
final class DeferredLinksOffTests: XCTestCase {
    func testBothOptionsAreOffByDefault() {
        let configuration = StrybokConfiguration(apiBaseURL: apiBase, allowedHosts: [host])
        XCTAssertFalse(configuration.deferredLinks)
        XCTAssertFalse(configuration.allowProbabilisticMatching)
    }

    func testWithTheOptionOffNothingIsReadStoredOrSent() async {
        let fixture = makeDeferred(deferredLinks: false, probe: FakeProbe(true))
        let sdk = fixture.sdk
        let received = collect(sdk)
        await sdk.start()

        let result = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .disabled)
        let mayPaste = await sdk.pasteboardMayContainLink()
        XCTAssertFalse(mayPaste)
        sdk.skipPastedLink()
        XCTAssertEqual(sdk.deferredLinkStatus, .disabled)
        await settle()

        XCTAssertTrue(fixture.api.all.value.isEmpty, "no request at all")
        XCTAssertFalse(fixture.store.touched, "the store is neither read nor written")
        XCTAssertEqual(fixture.probe.calls.value, 0, "the pasteboard is not even probed")
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(fixture.errors.value.isEmpty)
        sdk.stop()
    }

    func testMatchingAloneDoesNothingWithoutDeferredLinks() async {
        let fixture = makeDeferred(deferredLinks: false, matching: true, probe: FakeProbe(true))
        await fixture.sdk.start()
        await settle()

        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .disabled)
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertFalse(fixture.store.touched)
        XCTAssertEqual(fixture.probe.calls.value, 0)
        fixture.sdk.stop()
    }

    func testOnlyThePastedLinkFlowRunsWithoutTheMatchingOption() async {
        let fixture = makeDeferred(matching: false)
        await fixture.sdk.start()
        fixture.sdk.skipPastedLink()
        await settle()

        XCTAssertTrue(fixture.api.all.value.isEmpty, "no match request without the second option")
        XCTAssertEqual(fixture.probe.calls.value, 0)
        XCTAssertTrue(fixture.store.log.isEmpty)
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .awaitingPaste)
        fixture.sdk.stop()
    }

    func testNormalLinksAreNeitherDeferredNorProbabilistic() async throws {
        let api = FakeAPI()
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: invite))
        let initial = await sdk.initialLink()
        let link = try XCTUnwrap(initial)
        XCTAssertFalse(link.isDeferred)
        XCTAssertFalse(link.isProbabilisticMatch)
        let resolved = try await sdk.resolve(invite)
        XCTAssertFalse(resolved.isDeferred)
        XCTAssertFalse(resolved.isProbabilisticMatch)

        let plain = ResolvedLink(url: invite, linkId: "l", appId: "a", routePath: "/x")
        XCTAssertFalse(plain.isDeferred)
        XCTAssertFalse(plain.isProbabilisticMatch)
        sdk.stop()
    }
}

/// Flow A of the contract: the person pastes the link they copied.
final class PastedLinkTests: XCTestCase {
    // MARK: Delivered

    func testRedeemsAPastedLinkAndDeliversItAsDeferred() async throws {
        let fixture = makeDeferred()
        let sdk = fixture.sdk
        let received = collect(sdk)
        await sdk.start()

        let result = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        await waitUntil("delivered") { received.value.count == 1 }
        await settle()

        let link = try XCTUnwrap(received.value.first)
        XCTAssertEqual(received.value.count, 1)
        XCTAssertTrue(link.isDeferred)
        XCTAssertFalse(link.isProbabilisticMatch)
        XCTAssertEqual(link.url, url("https://\(host)/invite777"), "the answer's url, without the code")
        XCTAssertEqual(link.linkId, "link_d")
        XCTAssertEqual(link.appId, "app_1")
        XCTAssertEqual(link.routePath, "/invite/abc123")
        XCTAssertEqual(link.payload, ["invitationId": "abc123"])
        XCTAssertEqual(link.campaign.source, "instagram")

        XCTAssertEqual(fixture.store.log, ["done"])
        XCTAssertEqual(sdk.deferredLinkStatus, .delivered)
        XCTAssertTrue(fixture.api.events.value.isEmpty, "no app_open for a deferred link")
        XCTAssertTrue(fixture.api.resolves.value.isEmpty, "the pasted URL is not resolved")
        XCTAssertTrue(fixture.errors.value.isEmpty)
        sdk.stop()
    }

    func testTheRequestCarriesExactlyTheSpecifiedFields() async throws {
        let fixture = makeDeferred(apiBaseURL: url("https://api.strybok.com/prefix/"))
        // Everything else in the pasted link stays on the device.
        let pasted = "  https://MY-APP.strybok.link/invite777?utm_source=news&secret=s3cr3t"
            + "&strybok_click=\(clickId)&email=a%40b.c#private-fragment\n"
        let result = await fixture.sdk.redeemPastedLink(pasted)
        XCTAssertEqual(result, .delivered)

        XCTAssertEqual(fixture.api.all.value.count, 1)
        let request = try XCTUnwrap(fixture.api.redeems.value.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.strybok.com/prefix/v1/public/deferred-links/redeem")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.allHTTPHeaderFields?.keys.sorted(), ["Accept", "Content-Type"],
            "no other header")

        let body = jsonBody(request)
        XCTAssertEqual(body.keys.sorted(), ["bundleId", "clickId", "platform", "sdkVersion"])
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["clickId"] as? String, clickId)
        XCTAssertEqual(body["bundleId"] as? String, testBundleId)
        XCTAssertEqual(body["sdkVersion"] as? String, Strybok.sdkVersion)

        let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        for secret in ["s3cr3t", "private-fragment", "email", "news", "invite777", host] {
            XCTAssertFalse(sent.contains(secret), "\(secret) must not be sent")
        }
        fixture.sdk.stop()
    }

    func testItIsQueuedUntilAListenerAttachesAndIsNeverTheInitialLink() async {
        let fixture = makeDeferred()
        let sdk = fixture.sdk
        let result = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered, "works before and without start()")

        let initial = await sdk.initialLink()
        XCTAssertNil(initial, "a deferred link is not the launch link")

        let received = collect(sdk)
        await waitUntil("queued link delivered") { received.value.count == 1 }
        await settle()
        XCTAssertEqual(received.value.map(\.isDeferred), [true])
        sdk.stop()
    }

    func testItIsDeliveredEvenAfterANormalLinkWasDelivered() async {
        let fixture = makeDeferred(source: FakeLinkSource(launchURL: invite))
        let sdk = fixture.sdk
        let received = collect(sdk)
        await sdk.start()
        await waitUntil("launch link") { received.value.count == 1 }

        let result = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        await waitUntil("pasted link") { received.value.count == 2 }
        XCTAssertEqual(received.value.map(\.isDeferred), [false, true])
        XCTAssertEqual(fixture.api.events.value.count, 1, "only the normal link reports an open")
        sdk.stop()
    }

    // MARK: Validation

    func testAnythingThatIsNotALinkOfOursWithAValidCodeIsDroppedWithoutARequest() async {
        let short = "dc_" + String(repeating: "a", count: 31)
        let long = "dc_" + String(repeating: "a", count: 33)
        let rejected = [
            "",
            "   \n",
            "hello",
            "my password is hunter2",
            clickId,
            "strybok_click=\(clickId)",
            "https://\(host)/invite777",
            "https://\(host)/invite777?strybok_click=",
            "https://\(host)/invite777?strybok_click",
            "https://\(host)/invite777?strybok_click=\(short)",
            "https://\(host)/invite777?strybok_click=\(long)",
            "https://\(host)/invite777?strybok_click=xx_" + String(repeating: "a", count: 32),
            "https://\(host)/invite777?strybok_click=dc_" + String(repeating: "-", count: 32),
            "https://\(host)/invite777?strybok_click=DC_" + String(repeating: "a", count: 32),
            // Only the first parameter of that name counts.
            "https://\(host)/invite777?strybok_click=nope&strybok_click=\(clickId)",
            "https://\(host)/invite777?Strybok_Click=\(clickId)",
            "https://\(host)/invite777?xstrybok_click=\(clickId)",
            "https://\(host)/invite777#strybok_click=\(clickId)",
            // Not "ours" by the usual rules.
            "http://\(host)/invite777?strybok_click=\(clickId)",
            "https://evil.example/invite777?strybok_click=\(clickId)",
            "https://\(host).evil.example/invite777?strybok_click=\(clickId)",
            "https://\(host):8443/invite777?strybok_click=\(clickId)",
            "https://user:pass@\(host)/invite777?strybok_click=\(clickId)",
            "https://\(host)/invite777/?strybok_click=\(clickId)",
            "https://\(host)/a/b?strybok_click=\(clickId)",
            "https://\(host)/?strybok_click=\(clickId)",
            "https://\(host)?strybok_click=\(clickId)",
            "strybok://\(host)/invite777?strybok_click=\(clickId)",
            // Text around a link is not a link.
            "Look: \(pastedLink)",
            "\(pastedLink) and more",
            "\(pastedLink)\n\(pastedLink)",
            pastedLink + "&x=" + String(repeating: "y", count: 3000),
        ]
        let fixture = makeDeferred()
        for string in rejected {
            let result = await fixture.sdk.redeemPastedLink(string)
            XCTAssertEqual(result, .notOurs, "should be dropped: \(string.prefix(80))")
        }
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty, "no request for anything that is not ours")
        XCTAssertTrue(fixture.store.log.isEmpty, "nothing is stored")
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .awaitingPaste)
        XCTAssertTrue(fixture.errors.value.isEmpty)

        // …and the person can still paste the right thing afterwards.
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        fixture.sdk.stop()
    }

    func testAcceptedSpellingsOfAPastedLink() async {
        let accepted = [
            pastedLink,
            "  \(pastedLink)\n",
            "\t\(pastedLink)\r\n",
            "https://MY-APP.Strybok.Link/invite777?strybok_click=\(clickId)",
            "HTTPS://\(host)/invite777?strybok_click=\(clickId)",
            "https://\(host):443/invite777?strybok_click=\(clickId)",
            "https://\(host)/invite777?utm_source=x&strybok_click=\(clickId)&other=1",
            "https://\(host)/invite777?strybok_click=\(clickId)#section",
            "https://\(host)/invite777?strybok_click=\(clickId)&strybok_click=second",
        ]
        for string in accepted {
            let fixture = makeDeferred()
            let result = await fixture.sdk.redeemPastedLink(string)
            XCTAssertEqual(result, .delivered, "should be accepted: \(string)")
            XCTAssertEqual(jsonBody(fixture.api.redeems.value[0])["clickId"] as? String, clickId)
            fixture.sdk.stop()
        }
    }

    func testClickIdParsing() {
        XCTAssertEqual(DeferredLinkFormat.clickId(inQuery: "strybok_click=\(clickId)"), clickId)
        XCTAssertEqual(DeferredLinkFormat.clickId(inQuery: "a=1&strybok_click=\(clickId)&b"), clickId)
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: nil))
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: ""))
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: "strybok_click"))
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: "strybok_click=%ZZ"))
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: "strybok_click=\(clickId)x"))
        XCTAssertNil(DeferredLinkFormat.clickId(inQuery: "strybok_click=\(clickId)%20"))
        XCTAssertTrue(DeferredLinkFormat.isClickId(clickId))
        XCTAssertFalse(DeferredLinkFormat.isClickId("dc_" + String(repeating: "é", count: 16)))
    }

    // MARK: Answers

    func testAnUnusable200StoresDoneAndFails() async {
        let unusable: [StrybokHTTPResponse] = [
            .json("not json"),
            .json("[]"),
            .json(#"{"linkId":"l","appId":"a","routePath":"/x","deferred":true}"#),  // no url
            deferredAnswer(deferred: ""),  // `deferred` missing
            deferredAnswer(deferred: #","deferred":false"#),
            deferredAnswer(deferred: #","deferred":"true""#),
            deferredAnswer(url: "https://evil.example/invite777"),
            deferredAnswer(url: "http://\(host)/invite777"),
            deferredAnswer(url: "https://\(host)/a/b"),
            deferredAnswer(route: "//evil.example"),
            deferredAnswer(route: "invite"),
            .json(#"{"appId":"a","routePath":"/x","url":"https://\#(host)/s","deferred":true}"#),
        ]
        for answer in unusable {
            let fixture = makeDeferred(api: DeferredAPI(redeem: { _ in answer }))
            let received = collect(fixture.sdk)
            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            let body = String(decoding: answer.body, as: UTF8.self)
            XCTAssertEqual(result, .failed, body)
            await settle()
            XCTAssertTrue(received.value.isEmpty, "nothing is delivered: \(body)")
            XCTAssertEqual(fixture.store.log, ["done"], body)
            XCTAssertEqual(fixture.sdk.deferredLinkStatus, .failed)
            XCTAssertEqual(fixture.api.redeems.value.count, 1)

            let again = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(again, .alreadyHandled)
            XCTAssertEqual(fixture.api.redeems.value.count, 1)
            XCTAssertTrue(fixture.errors.value.isEmpty)
            fixture.sdk.stop()
        }
    }

    func testARefusedCodeIsNotFoundAndFinal() async {
        for status in [404, 400, 401, 403, 410, 413, 422] {
            let fixture = makeDeferred(
                api: DeferredAPI(redeem: { _ in .json("{}", statusCode: status) }), maxRetries: 2)
            let received = collect(fixture.sdk)
            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(result, .notFound, "status \(status)")
            XCTAssertEqual(fixture.api.redeems.value.count, 1, "4xx is not retried")
            XCTAssertEqual(fixture.store.log, ["done"])
            XCTAssertEqual(fixture.sdk.deferredLinkStatus, .notFound)

            let again = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(again, .alreadyHandled)
            XCTAssertEqual(fixture.api.redeems.value.count, 1)
            await settle()
            XCTAssertTrue(received.value.isEmpty)
            XCTAssertTrue(fixture.errors.value.isEmpty)
            fixture.sdk.stop()
        }
    }

    func testRateLimitingFailsWithoutStoringSoThePersonCanPasteAgain() async {
        let answers = Box<[StrybokHTTPResponse]>([.json("{}", statusCode: 429), deferredAnswer()])
        let fixture = makeDeferred(
            api: DeferredAPI(redeem: { _ in answers.mutate { $0.removeFirst() } }), maxRetries: 2)
        let received = collect(fixture.sdk)

        let first = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(fixture.api.redeems.value.count, 1, "429 is not retried")
        XCTAssertTrue(fixture.store.log.isEmpty, "done is not stored")
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .awaitingPaste)

        let second = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(second, .delivered)
        await waitUntil("delivered") { received.value.count == 1 }
        XCTAssertTrue(fixture.errors.value.isEmpty)
        fixture.sdk.stop()
    }

    func testServerErrorsAreRetriedWithTheIdenticalBodyThenFailWithoutStoring() async {
        let fixture = makeDeferred(
            api: DeferredAPI(redeem: { _ in .json("{}", statusCode: 503) }), maxRetries: 2)
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .failed)
        let bodies = fixture.api.redeems.value.map(\.httpBody)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(Set(bodies).count, 1, "a retry sends the identical body")
        XCTAssertTrue(fixture.store.log.isEmpty)
        XCTAssertTrue(fixture.errors.value.isEmpty, "nothing goes to onError")

        fixture.api.onRedeem.value = { _ in deferredAnswer() }
        let again = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(again, .delivered)
        fixture.sdk.stop()
    }

    func testOtherUnexpectedStatusesFailWithoutStoring() async {
        for status in [204, 301, 304] {
            let fixture = makeDeferred(
                api: DeferredAPI(redeem: { _ in .json("{}", statusCode: status) }))
            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(result, .failed, "status \(status)")
            XCTAssertTrue(fixture.store.log.isEmpty)
            fixture.sdk.stop()
        }
    }

    func testTransportFailuresAndTimeoutsFailWithoutStoring() async {
        let offline = makeDeferred(api: DeferredAPI(redeem: { _ in throw Offline() }), maxRetries: 1)
        let first = await offline.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(offline.api.redeems.value.count, 2)
        XCTAssertTrue(offline.store.log.isEmpty)
        XCTAssertTrue(offline.errors.value.isEmpty)
        offline.sdk.stop()

        let slow = makeDeferred(
            api: DeferredAPI(redeem: { _ in try await hang() }), maxRetries: 1, timeout: 0.05)
        let second = await slow.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(slow.api.redeems.value.count, 2)
        XCTAssertTrue(slow.store.log.isEmpty)
        XCTAssertTrue(slow.errors.value.isEmpty)
        slow.sdk.stop()
    }

    func testWithoutABundleIdentifierNothingIsSent() async {
        let fixture = makeDeferred(environment: FakeEnvironment(bundleId: nil))
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertTrue(fixture.store.log.isEmpty)
        fixture.sdk.stop()
    }

    // MARK: Once only

    func testDoneIsStoredBeforeTheLinkReachesTheApp() async {
        let fixture = makeDeferred()
        let doneWhenDelivered = Box<Bool?>(nil)
        fixture.sdk.addListener { _ in doneWhenDelivered.value = fixture.store.isDone }
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        await waitUntil("delivered") { doneWhenDelivered.value != nil }
        XCTAssertEqual(doneWhenDelivered.value, true)
        fixture.sdk.stop()
    }

    func testDoneIsNotStoredBeforeTheAnswer() async {
        let latch = Latch()
        let fixture = makeDeferred()
        fixture.api.onRedeem.value = { _ in
            try await latch.wait()
            return deferredAnswer()
        }
        async let pending = fixture.sdk.redeemPastedLink(pastedLink)
        await waitUntil("request sent") { fixture.api.redeems.value.count == 1 }
        XCTAssertTrue(fixture.store.log.isEmpty, "a crash now leaves the code usable")
        latch.open()
        let result = await pending
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(fixture.store.log, ["done"])
        fixture.sdk.stop()
    }

    func testASecondPasteIsAlreadyHandledWithoutARequest() async {
        let fixture = makeDeferred()
        let received = collect(fixture.sdk)
        let first = await fixture.sdk.redeemPastedLink(pastedLink)
        let second = await fixture.sdk.redeemPastedLink(pastedLink)
        let third = await fixture.sdk.redeemPastedLink("anything")
        XCTAssertEqual([first, second, third], [.delivered, .alreadyHandled, .alreadyHandled])
        await settle()
        XCTAssertEqual(fixture.api.redeems.value.count, 1)
        XCTAssertEqual(received.value.count, 1)
        fixture.sdk.stop()
    }

    func testADoubleTapDeliversOnce() async {
        let latch = Latch()
        let fixture = makeDeferred()
        fixture.api.onRedeem.value = { _ in
            try await latch.wait()
            return deferredAnswer()
        }
        let received = collect(fixture.sdk)
        let sdk = fixture.sdk
        let taps = (0..<4).map { _ in Task { await sdk.redeemPastedLink(pastedLink) } }
        await waitUntil("first request") { fixture.api.redeems.value.count == 1 }
        await settle()
        latch.open()
        var results: [PastedLinkResult] = []
        for tap in taps { results.append(await tap.value) }
        await settle()

        XCTAssertEqual(results.filter { $0 == .delivered }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyHandled }.count, 3)
        XCTAssertEqual(fixture.api.redeems.value.count, 1, "the code is sent once")
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(fixture.store.log, ["done"])
        sdk.stop()
    }

    func testTheNextLaunchDoesNothing() async {
        let store = FakeDeferredStore()
        let first = makeDeferred(store: store)
        let result = await first.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        first.sdk.stop()

        let second = makeDeferred(store: store, probe: FakeProbe(true))
        XCTAssertEqual(second.sdk.deferredLinkStatus, .notFirstLaunch)
        let again = await second.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(again, .alreadyHandled)
        let mayPaste = await second.sdk.pasteboardMayContainLink()
        XCTAssertFalse(mayPaste)
        XCTAssertEqual(second.probe.calls.value, 0)
        XCTAssertTrue(second.api.all.value.isEmpty)
        second.sdk.stop()
    }

    func testStateIsSeparateForEachAPIHostAndApp() async {
        let store = FakeDeferredStore()
        let first = makeDeferred(store: store)
        _ = await first.sdk.redeemPastedLink(pastedLink)
        first.sdk.stop()

        let otherApp = makeDeferred(
            store: store, environment: FakeEnvironment(bundleId: "com.example.other"))
        let staging = makeDeferred(store: store, apiBaseURL: url("https://api.staging.example"))
        for fixture in [otherApp, staging] {
            XCTAssertEqual(fixture.sdk.deferredLinkStatus, .awaitingPaste)
            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(result, .delivered)
            fixture.sdk.stop()
        }
        XCTAssertEqual(Set(store.writes.value.map(\.scope)).count, 3)
    }

    // MARK: Stop

    func testAfterStopNothingIsSentOrDelivered() async {
        let fixture = makeDeferred()
        fixture.sdk.stop()
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .failed)
        let mayPaste = await fixture.sdk.pasteboardMayContainLink()
        XCTAssertFalse(mayPaste)
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertTrue(fixture.store.log.isEmpty)
    }

    func testStoppingWhileTheRequestIsInFlightDeliversNothing() async {
        let fixture = makeDeferred()
        fixture.api.onRedeem.value = { _ in try await hang() }
        let received = collect(fixture.sdk)
        async let pending = fixture.sdk.redeemPastedLink(pastedLink)
        await waitUntil("request sent") { fixture.api.redeems.value.count == 1 }
        fixture.sdk.stop()
        let result = await pending
        XCTAssertEqual(result, .failed)
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(fixture.store.log.isEmpty, "no answer arrived, so the code stays usable")
        XCTAssertTrue(fixture.errors.value.isEmpty)
    }

    // MARK: Switching on later, the paste hint

    func testCanBeSwitchedOnAfterStart() async {
        let fixture = makeDeferred(deferredLinks: false)
        let sdk = fixture.sdk
        let statuses = collectStatuses(sdk)
        let received = collect(sdk)
        await sdk.start()
        let before = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(before, .disabled)

        sdk.enableDeferredLinks()
        sdk.enableDeferredLinks()
        XCTAssertEqual(sdk.deferredLinkStatus, .awaitingPaste)
        let after = await sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(after, .delivered)
        await waitUntil("delivered") { received.value.count == 1 }
        await waitUntil("statuses") { statuses.value.last == .delivered }
        XCTAssertEqual(statuses.value, [.disabled, .awaitingPaste, .delivered])
        XCTAssertTrue(fixture.api.matches.value.isEmpty)
        sdk.stop()
    }

    func testPasteboardHintComesFromPatternDetectionOnly() async {
        let fixture = makeDeferred(probe: FakeProbe(true))
        let yes = await fixture.sdk.pasteboardMayContainLink()
        XCTAssertTrue(yes)
        fixture.probe.answer.value = false
        let no = await fixture.sdk.pasteboardMayContainLink()
        XCTAssertFalse(no)
        XCTAssertEqual(fixture.probe.calls.value, 2)

        fixture.probe.answer.value = true
        _ = await fixture.sdk.redeemPastedLink(pastedLink)
        let afterDone = await fixture.sdk.pasteboardMayContainLink()
        XCTAssertFalse(afterDone, "nothing to paste once a deferred link was handled")
        XCTAssertEqual(fixture.probe.calls.value, 2)
        XCTAssertTrue(fixture.api.matches.value.isEmpty)
        fixture.sdk.stop()
    }

    func testAProbeThatNeverAnswersIsGivenUp() async {
        let fixture = makeDeferred(probe: FakeProbe(true, hangs: true), timeout: 0.05)
        let answer = await fixture.sdk.pasteboardMayContainLink()
        XCTAssertFalse(answer)
        fixture.sdk.stop()
    }
}
