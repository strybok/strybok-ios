import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

/// Flow B of the contract: the service guesses the link on the first launch.
final class ProbabilisticMatchingTests: XCTestCase {
    // MARK: Delivered

    func testMatchesAfterStartAndDeliversTheLinkMarkedAsAGuess() async throws {
        let fixture = makeDeferred(matching: true)
        let sdk = fixture.sdk
        XCTAssertEqual(sdk.deferredLinkStatus, .checking)
        let statuses = collectStatuses(sdk)
        let received = collect(sdk)
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty, "nothing happens before start()")

        await sdk.start()
        await waitUntil("delivered") { received.value.count == 1 }
        await waitUntil("status") { statuses.value.last == .delivered }
        await settle()

        let link = try XCTUnwrap(received.value.first)
        XCTAssertEqual(received.value.count, 1)
        XCTAssertTrue(link.isDeferred)
        XCTAssertTrue(link.isProbabilisticMatch)
        XCTAssertEqual(link.url, url("https://\(host)/invite777"))
        XCTAssertEqual(link.routePath, "/invite/abc123")
        XCTAssertEqual(link.payload, ["invitationId": "abc123"])
        XCTAssertEqual(link.campaign.source, "instagram")

        XCTAssertEqual(statuses.value, [.checking, .delivered])
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        XCTAssertEqual(fixture.api.all.value.count, 1, "no app_open, no resolve, no redeem")
        XCTAssertEqual(fixture.probe.calls.value, 1, "the clipboard was asked first")
        XCTAssertTrue(fixture.errors.value.isEmpty)

        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        sdk.stop()
    }

    func testTheRequestCarriesExactlyTheSpecifiedFields() async throws {
        for (family, language) in [("iphone", "en-GB"), ("ipad", "zh-Hans-CN"), ("ipod", "uk")] {
            let fixture = makeDeferred(
                matching: true,
                environment: FakeEnvironment(preferredLanguage: language, family: family))
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .delivered)

            let request = try XCTUnwrap(fixture.api.matches.value.first)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString, "https://api.strybok.com/v1/public/deferred-links/match")
            XCTAssertEqual(
                request.allHTTPHeaderFields?.keys.sorted(), ["Accept", "Content-Type"],
                "no other header")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let body = jsonBody(request)
            XCTAssertEqual(
                body.keys.sorted(), ["bundleId", "deviceFamily", "locale", "platform", "sdkVersion"],
                "nothing else: no identifier, model, screen, OS version, time zone or carrier")
            XCTAssertEqual(body["platform"] as? String, "ios")
            XCTAssertEqual(body["bundleId"] as? String, testBundleId)
            XCTAssertEqual(body["deviceFamily"] as? String, family)
            XCTAssertEqual(body["locale"] as? String, language)
            XCTAssertEqual(body["sdkVersion"] as? String, Strybok.sdkVersion)
            fixture.sdk.stop()
        }
    }

    func testItIsQueuedUntilAListenerAttachesAndIsNeverTheInitialLink() async {
        let fixture = makeDeferred(matching: true)
        let sdk = fixture.sdk
        await sdk.start()
        await waitForStatus(sdk, .delivered)
        let initial = await sdk.initialLink()
        XCTAssertNil(initial, "a deferred link is never the launch link")

        let received = collect(sdk)
        await waitUntil("queued link delivered") { received.value.count == 1 }
        await settle()
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [true])
        XCTAssertTrue(fixture.api.events.value.isEmpty)
        sdk.stop()
    }

    // MARK: Never on the start path

    func testStartDoesNotWaitForTheMatchRequest() async {
        let fixture = makeDeferred(
            api: DeferredAPI(match: { _ in try await hang() }), matching: true,
            source: nil)
        let started = Date()
        await fixture.sdk.start()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await waitUntil("match sent") { fixture.api.matches.value.count == 1 }
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .checking)

        // Creating links and resolving do not wait for it either.
        let resolved = try? await fixture.sdk.resolve(invite)
        XCTAssertEqual(resolved?.routePath, "/invite/abc123")
        fixture.sdk.stop()
    }

    func testStartDoesNotWaitForTheClipboardProbe() async {
        let fixture = makeDeferred(matching: true, probe: FakeProbe(true, hangs: true))
        let started = Date()
        await fixture.sdk.start()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await waitUntil("probe asked") { fixture.probe.calls.value == 1 }
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        fixture.sdk.stop()
    }

    func testAProbeThatNeverAnswersDoesNotBlockMatchingForEver() async {
        let fixture = makeDeferred(
            matching: true, probe: FakeProbe(true, hangs: true), timeout: 0.05)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .delivered)
        fixture.sdk.stop()
    }

    func testItRunsOncePerProcess() async {
        let fixture = makeDeferred(
            api: DeferredAPI(match: { _ in .json("{}", statusCode: 503) }), matching: true)
        let sdk = fixture.sdk
        await sdk.start()
        await sdk.start()
        sdk.enableDeferredLinks()
        sdk.skipPastedLink()
        sdk.skipPastedLink()
        await waitForStatus(sdk, .pending)
        await sdk.start()
        sdk.skipPastedLink()
        let result = await sdk.redeemPastedLink("not a link")
        XCTAssertEqual(result, .notOurs)
        await settle()
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        XCTAssertEqual(fixture.store.log, ["attempts=1"])
        sdk.stop()
    }

    func testSwitchingOnLaterRunsTheCheckThen() async {
        let fixture = makeDeferred(deferredLinks: false, matching: true)
        let sdk = fixture.sdk
        let statuses = collectStatuses(sdk)
        await sdk.start()
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertFalse(fixture.store.touched)

        sdk.enableDeferredLinks()
        await waitUntil("status") { statuses.value.last == .delivered }
        XCTAssertEqual(statuses.value, [.disabled, .checking, .delivered])
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        sdk.stop()
    }

    func testSwitchingOnBeforeStartWaitsForStart() async {
        let fixture = makeDeferred(deferredLinks: false, matching: true)
        fixture.sdk.enableDeferredLinks()
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .delivered)
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        fixture.sdk.stop()
    }

    // MARK: Flow table

    func testStep1DoneFromAnEarlierLaunchStopsEverything() async {
        let store = FakeDeferredStore()
        store.inner.setDone(scope: FakeDeferredStore.scope)
        let fixture = makeDeferred(store: store, matching: true, probe: FakeProbe(true))
        await fixture.sdk.start()
        await settle()
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .notFirstLaunch)
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertEqual(fixture.probe.calls.value, 0)
        XCTAssertTrue(store.log.isEmpty)
        fixture.sdk.stop()
    }

    func testStep3ThreeAttemptsThenFailedForGood() async {
        let store = FakeDeferredStore()
        // Three launches in which the service cannot be reached…
        for launch in 1...3 {
            let fixture = makeDeferred(
                api: DeferredAPI(match: { _ in .json("{}", statusCode: 503) }), store: store,
                matching: true, maxRetries: 1)
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .pending)
            XCTAssertEqual(fixture.api.matches.value.count, 2, "retried like resolving")
            XCTAssertEqual(
                Set(fixture.api.matches.value.map(\.httpBody)).count, 1, "identical body")
            XCTAssertEqual(store.attempts, launch)
            XCTAssertFalse(store.isDone)
            XCTAssertTrue(fixture.errors.value.isEmpty, "nothing goes to onError")
            fixture.sdk.stop()
        }
        // …the fourth gives up without asking.
        let fourth = makeDeferred(store: store, matching: true)
        await fourth.sdk.start()
        await waitForStatus(fourth.sdk, .failed)
        XCTAssertTrue(fourth.api.all.value.isEmpty)
        XCTAssertTrue(store.isDone)
        XCTAssertEqual(store.attempts, 3)
        fourth.sdk.stop()

        let fifth = makeDeferred(store: store, matching: true)
        await fifth.sdk.start()
        await settle()
        XCTAssertEqual(fifth.sdk.deferredLinkStatus, .notFirstLaunch)
        XCTAssertTrue(fifth.api.all.value.isEmpty)
        fifth.sdk.stop()
    }

    func testStep4AttemptsAreStoredBeforeTheRequest() async {
        let store = FakeDeferredStore()
        let seen = Box<[String]>([])
        let api = DeferredAPI(match: { _ in
            seen.value = store.log
            return matchAnswer()
        })
        let fixture = makeDeferred(api: api, store: store, matching: true)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .delivered)
        XCTAssertEqual(seen.value, ["attempts=1"], "counted before, done only after the answer")
        fixture.sdk.stop()
    }

    func testACrashDuringTheRequestCostsOneAttemptAndNeverRepeatsForEver() async {
        let store = FakeDeferredStore()
        for launch in 1...3 {
            // The process dies while the request is in flight.
            let fixture = makeDeferred(
                api: DeferredAPI(match: { _ in try await hang() }), store: store, matching: true)
            await fixture.sdk.start()
            await waitUntil("request sent") { fixture.api.matches.value.count == 1 }
            XCTAssertEqual(store.attempts, launch)
            XCTAssertFalse(store.isDone)
            fixture.sdk.stop()
        }
        let next = makeDeferred(store: store, matching: true)
        await next.sdk.start()
        await waitForStatus(next.sdk, .failed)
        XCTAssertTrue(next.api.all.value.isEmpty, "an app that dies on every start stops asking")
        next.sdk.stop()
    }

    func testStep5ANormalLinkBeforeTheCheckSupersedesWithoutARequest() async {
        let fixture = makeDeferred(matching: true, source: FakeLinkSource(launchURL: invite))
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .superseded)
        await settle()
        XCTAssertTrue(fixture.api.matches.value.isEmpty, "no request")
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        XCTAssertEqual(received.value.map(\.isDeferred), [false], "one launch, one navigation")
        fixture.sdk.stop()
    }

    func testANormalLinkThatFailedToResolveStillSupersedes() async {
        let fixture = makeDeferred(matching: true)
        fixture.api.onResolve.value = { _ in .json("{}", statusCode: 404) }
        fixture.sdk.handle(invite)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .superseded)
        XCTAssertTrue(fixture.api.matches.value.isEmpty)
        XCTAssertEqual(fixture.errors.value.count, 1, "the normal link's own error only")
        fixture.sdk.stop()
    }

    func testAForeignURLDoesNotSupersede() async {
        let fixture = makeDeferred(matching: true)
        fixture.sdk.handle(url("https://example.com/invite777"))
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .delivered)
        fixture.sdk.stop()
    }

    func testANormalLinkDuringTheRequestSupersedes() async {
        let latch = Latch()
        let api = DeferredAPI(match: { _ in
            try await latch.wait()
            return matchAnswer()
        })
        let fixture = makeDeferred(api: api, matching: true)
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitUntil("match sent") { api.matches.value.count == 1 }

        fixture.sdk.handle(invite)
        await waitUntil("normal link") { received.value.count == 1 }
        latch.open()
        await waitForStatus(fixture.sdk, .superseded)
        await settle()

        XCTAssertEqual(received.value.map(\.isDeferred), [false], "the guess is dropped, not queued")
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        fixture.sdk.stop()
    }

    func testANormalLinkAfterDeliveryIsJustAnotherLink() async {
        let fixture = makeDeferred(matching: true)
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitUntil("deferred link") { received.value.count == 1 }
        fixture.sdk.handle(invite)
        await waitUntil("normal link") { received.value.count == 2 }
        XCTAssertEqual(received.value.map(\.isDeferred), [true, false])
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .delivered)
        fixture.sdk.stop()
    }

    func testStep6DevicesAndLanguagesThatCannotBeMatchedAreUnavailable() async {
        let environments = [
            FakeEnvironment(family: nil),  // Mac, TV, Vision
            FakeEnvironment(preferredLanguage: nil),
            FakeEnvironment(preferredLanguage: ""),
            FakeEnvironment(preferredLanguage: "x"),
            FakeEnvironment(preferredLanguage: "en GB"),
            FakeEnvironment(preferredLanguage: "en-US@calendar=gregorian"),
            FakeEnvironment(bundleId: nil),
        ]
        for environment in environments {
            let store = FakeDeferredStore()
            let fixture = makeDeferred(store: store, matching: true, environment: environment)
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .unavailable)
            XCTAssertTrue(fixture.api.all.value.isEmpty, "no request: \(environment)")
            XCTAssertEqual(store.log, ["attempts=1", "done"])
            fixture.sdk.stop()
        }
    }

    func testLocaleFormat() {
        for good in ["en", "uk", "fil", "en-GB", "en_GB", "zh-Hans-CN", "sr-Latn-RS", "es-419"] {
            XCTAssertTrue(DeferredLinkFormat.isLocale(good), good)
        }
        for bad in ["", "e", "engl", "12", "en-", "-en", "en--GB", "en-toolongsubtag", "en GB",
            "en-a-b-c-d-e", "en-GB!", "é"]
        {
            XCTAssertFalse(DeferredLinkFormat.isLocale(bad), bad)
        }
    }

    func testAnUnusable200StoresDoneAndFails() async {
        let unusable: [StrybokHTTPResponse] = [
            .json("not json"),
            deferredAnswer(),  // not marked as a probabilistic match
            deferredAnswer(extra: #","matched":"exact""#),
            deferredAnswer(extra: #","matched":true"#),
            deferredAnswer(deferred: #","deferred":false"#, extra: #","matched":"probabilistic""#),
            deferredAnswer(deferred: "", extra: #","matched":"probabilistic""#),
            deferredAnswer(
                url: "https://evil.example/invite777", extra: #","matched":"probabilistic""#),
            deferredAnswer(route: "//evil.example", extra: #","matched":"probabilistic""#),
        ]
        for answer in unusable {
            let fixture = makeDeferred(api: DeferredAPI(match: { _ in answer }), matching: true)
            let received = collect(fixture.sdk)
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .failed)
            await settle()
            let body = String(decoding: answer.body, as: UTF8.self)
            XCTAssertTrue(received.value.isEmpty, body)
            XCTAssertEqual(fixture.store.log, ["attempts=1", "done"], body)
            XCTAssertTrue(fixture.errors.value.isEmpty)
            fixture.sdk.stop()
        }
    }

    func testNoMatchIsNotFoundAndFinal() async {
        for status in [404, 400, 403, 422] {
            let fixture = makeDeferred(
                api: DeferredAPI(match: { _ in .json("{}", statusCode: status) }), matching: true,
                maxRetries: 2)
            let received = collect(fixture.sdk)
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .notFound)
            await settle()
            XCTAssertEqual(fixture.api.matches.value.count, 1, "4xx is not retried")
            XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
            XCTAssertTrue(received.value.isEmpty)
            XCTAssertTrue(fixture.errors.value.isEmpty, "nothing goes to onError")
            fixture.sdk.stop()
        }
    }

    func testTemporaryFailuresArePendingAndTriedAgainOnALaterLaunch() async {
        let failures: [DeferredAPI.Handler] = [
            { _ in .json("{}", statusCode: 429) },
            { _ in .json("{}", statusCode: 500) },
            { _ in throw Offline() },
            { _ in try await hang() },
        ]
        for (index, failure) in failures.enumerated() {
            let store = FakeDeferredStore()
            let first = makeDeferred(
                api: DeferredAPI(match: failure), store: store, matching: true, maxRetries: 1,
                timeout: 0.05)
            let received = collect(first.sdk)
            await first.sdk.start()
            await waitForStatus(first.sdk, .pending)
            XCTAssertEqual(first.api.matches.value.count, index == 0 ? 1 : 2, "429 is not retried")
            XCTAssertEqual(store.log, ["attempts=1"], "done is not stored")
            XCTAssertTrue(received.value.isEmpty)
            XCTAssertTrue(first.errors.value.isEmpty, "nothing goes to onError")
            first.sdk.stop()

            let second = makeDeferred(store: store, matching: true)
            await second.sdk.start()
            await waitForStatus(second.sdk, .delivered)
            XCTAssertEqual(store.log, ["attempts=1", "attempts=2", "done"])
            second.sdk.stop()
        }
    }

    func testDoneIsStoredBeforeTheLinkReachesTheApp() async {
        let fixture = makeDeferred(matching: true)
        let doneWhenDelivered = Box<Bool?>(nil)
        fixture.sdk.addListener { _ in doneWhenDelivered.value = fixture.store.isDone }
        await fixture.sdk.start()
        await waitUntil("delivered") { doneWhenDelivered.value != nil }
        XCTAssertEqual(doneWhenDelivered.value, true)
        fixture.sdk.stop()
    }

    // MARK: Clipboard first

    func testWaitsForThePasteWhenTheClipboardMayHoldALink() async {
        let fixture = makeDeferred(matching: true, probe: FakeProbe(true))
        let statuses = collectStatuses(fixture.sdk)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .awaitingPaste)
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty, "no match yet")
        XCTAssertTrue(fixture.store.log.isEmpty, "no attempt is counted while waiting")
        XCTAssertEqual(statuses.value, [.checking, .awaitingPaste])
        fixture.sdk.stop()
    }

    func testSkippingThePasteStartsMatching() async {
        let fixture = makeDeferred(matching: true, probe: FakeProbe(true))
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .awaitingPaste)

        fixture.sdk.skipPastedLink()
        fixture.sdk.skipPastedLink()
        await waitForStatus(fixture.sdk, .delivered)
        await settle()
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [true])
        fixture.sdk.stop()
    }

    func testPastingSomethingElseStartsMatching() async {
        let fixture = makeDeferred(matching: true, probe: FakeProbe(true))
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .awaitingPaste)

        let result = await fixture.sdk.redeemPastedLink("https://example.com/some-page")
        XCTAssertEqual(result, .notOurs)
        await waitForStatus(fixture.sdk, .delivered)
        XCTAssertTrue(fixture.api.redeems.value.isEmpty)
        XCTAssertEqual(fixture.api.matches.value.count, 1)
        await waitUntil("delivered") { received.value.count == 1 }
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [true])
        fixture.sdk.stop()
    }

    func testPastingOurLinkMeansMatchingNeverRuns() async {
        let outcomes: [(StrybokHTTPResponse, PastedLinkResult, DeferredLinkStatus)] = [
            (deferredAnswer(), .delivered, .delivered),
            (.json("{}", statusCode: 404), .notFound, .notFound),
            (.json("{}"), .failed, .failed),
        ]
        for (answer, expected, status) in outcomes {
            let fixture = makeDeferred(
                api: DeferredAPI(redeem: { _ in answer }), matching: true, probe: FakeProbe(true))
            let received = collect(fixture.sdk)
            await fixture.sdk.start()
            await waitForStatus(fixture.sdk, .awaitingPaste)

            let result = await fixture.sdk.redeemPastedLink(pastedLink)
            XCTAssertEqual(result, expected)
            fixture.sdk.skipPastedLink()
            await settle()
            XCTAssertTrue(fixture.api.matches.value.isEmpty, "the exact link wins over a guess")
            XCTAssertEqual(fixture.sdk.deferredLinkStatus, status)
            XCTAssertEqual(fixture.store.log, ["done"], "no attempt was used")
            XCTAssertEqual(received.value.count, expected == .delivered ? 1 : 0)
            XCTAssertEqual(received.value.first?.isProbabilisticMatch ?? false, false)
            fixture.sdk.stop()
        }
    }

    func testAPasteThatCouldNotReachTheServiceKeepsWaiting() async {
        let fixture = makeDeferred(
            api: DeferredAPI(redeem: { _ in .json("{}", statusCode: 503) }), matching: true,
            probe: FakeProbe(true))
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .awaitingPaste)

        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .failed)
        await settle()
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .awaitingPaste, "they can tap Paste again")
        XCTAssertTrue(fixture.api.matches.value.isEmpty)

        fixture.sdk.skipPastedLink()
        await waitForStatus(fixture.sdk, .delivered)
        fixture.sdk.stop()
    }

    func testSkippingBeforeStartMeansTheClipboardIsNotWaitedFor() async {
        let fixture = makeDeferred(matching: true, probe: FakeProbe(true))
        fixture.sdk.skipPastedLink()
        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .delivered)
        XCTAssertEqual(fixture.probe.calls.value, 0)
        fixture.sdk.stop()
    }

    func testAPasteBeforeStartThatWasHandledMeansMatchingNeverRuns() async {
        let fixture = makeDeferred(matching: true)
        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        await fixture.sdk.start()
        await settle()
        XCTAssertTrue(fixture.api.matches.value.isEmpty)
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .delivered)
        XCTAssertEqual(fixture.store.log, ["done"])
        fixture.sdk.stop()
    }

    // MARK: The two flows at once

    func testMatchingWaitsWhileAPastedLinkIsBeingRedeemed() async {
        let latch = Latch()
        let fixture = makeDeferred(matching: true, probe: FakeProbe(false))
        fixture.api.onRedeem.value = { _ in
            try await latch.wait()
            return deferredAnswer()
        }
        let received = collect(fixture.sdk)
        async let pasted = fixture.sdk.redeemPastedLink(pastedLink)
        await waitUntil("redeem sent") { fixture.api.redeems.value.count == 1 }

        await fixture.sdk.start()
        await waitForStatus(fixture.sdk, .awaitingPaste)
        await settle()
        XCTAssertTrue(fixture.api.matches.value.isEmpty)

        latch.open()
        let result = await pasted
        XCTAssertEqual(result, .delivered)
        await settle()
        XCTAssertTrue(fixture.api.matches.value.isEmpty)
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [false])
        XCTAssertEqual(fixture.store.log, ["done"])
        fixture.sdk.stop()
    }

    func testAPasteThatFinishesWhileTheMatchIsInFlightWinsAndTheGuessIsDropped() async {
        let latch = Latch()
        let api = DeferredAPI(match: { _ in
            try await latch.wait()
            return matchAnswer()
        })
        let fixture = makeDeferred(api: api, matching: true)
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitUntil("match sent") { api.matches.value.count == 1 }

        let result = await fixture.sdk.redeemPastedLink(pastedLink)
        XCTAssertEqual(result, .delivered)
        latch.open()
        await settle()

        XCTAssertEqual(received.value.count, 1, "never two deferred links")
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [false])
        XCTAssertEqual(fixture.sdk.deferredLinkStatus, .delivered)
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        fixture.sdk.stop()
    }

    func testAMatchThatFinishesWhileAPasteIsInFlightWinsAndThePasteIsAlreadyHandled() async {
        let matchLatch = Latch()
        let redeemLatch = Latch()
        let api = DeferredAPI(
            redeem: { _ in
                try await redeemLatch.wait()
                return deferredAnswer()
            },
            match: { _ in
                try await matchLatch.wait()
                return matchAnswer()
            })
        let fixture = makeDeferred(api: api, matching: true)
        let received = collect(fixture.sdk)
        await fixture.sdk.start()
        await waitUntil("match sent") { api.matches.value.count == 1 }
        async let pasted = fixture.sdk.redeemPastedLink(pastedLink)
        await waitUntil("redeem sent") { api.redeems.value.count == 1 }

        matchLatch.open()
        await waitForStatus(fixture.sdk, .delivered)
        // The answer to the paste arrives afterwards: it must not deliver a second link.
        redeemLatch.open()
        let result = await pasted
        XCTAssertEqual(result, .alreadyHandled)
        await settle()
        XCTAssertEqual(received.value.count, 1, "never two deferred links")
        XCTAssertEqual(received.value.map(\.isProbabilisticMatch), [true])
        XCTAssertEqual(fixture.store.log, ["attempts=1", "done"])
        fixture.sdk.stop()
    }

    // MARK: Stop

    func testStoppingDuringTheCheckDeliversNothingAndEndsTheStatusStream() async {
        let fixture = makeDeferred(
            api: DeferredAPI(match: { _ in try await hang() }), matching: true)
        let received = collect(fixture.sdk)
        let finished = Box(false)
        let stream = fixture.sdk.deferredLinkStatuses()
        Task {
            for await _ in stream {}
            finished.value = true
        }
        await fixture.sdk.start()
        await waitUntil("match sent") { fixture.api.matches.value.count == 1 }
        fixture.sdk.stop()
        await waitUntil("status stream finished") { finished.value }
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertEqual(fixture.store.log, ["attempts=1"])
        XCTAssertTrue(fixture.errors.value.isEmpty)

        fixture.sdk.skipPastedLink()
        fixture.sdk.enableDeferredLinks()
        await settle()
        XCTAssertEqual(fixture.api.matches.value.count, 1)
    }

    func testStoppedBeforeStartFinishesNeverMatches() async {
        let fixture = makeDeferred(matching: true)
        fixture.sdk.stop()
        await fixture.sdk.start()
        await settle()
        XCTAssertTrue(fixture.api.all.value.isEmpty)
        XCTAssertFalse(fixture.store.log.contains("attempts=1"))
    }
}
