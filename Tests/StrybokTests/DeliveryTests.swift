import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

final class ColdStartTests: XCTestCase {
    func testDeliversTheLaunchLinkOnceEvenIfTheListenerAttachesLate() async {
        let api = FakeAPI()
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: invite))
        await sdk.start()
        XCTAssertEqual(api.resolves.value.count, 1, "start() returns after the launch link resolved")

        let received = collect(sdk)
        await waitUntil("launch link delivered") { received.value.count == 1 }
        await settle()

        XCTAssertEqual(received.value.map(\.routePath), ["/invite/abc123"])
        XCTAssertEqual(api.resolves.value.count, 1)
        sdk.stop()
    }

    func testAURLForwardedBeforeStartIsTheLaunchLink() async {
        let api = FakeAPI()
        let sdk = makeSDK(api)
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = invite
        XCTAssertTrue(sdk.handle(userActivity: activity))
        await settle()
        XCTAssertTrue(api.resolves.value.isEmpty, "nothing happens before start()")

        let initial = await sdk.initialLink()
        XCTAssertEqual(initial?.routePath, "/invite/abc123")
        XCTAssertEqual(initial?.url, invite)
        let again = await sdk.initialLink()
        XCTAssertNil(again)

        let received = collect(sdk)
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertEqual(api.resolves.value.count, 1)
        sdk.stop()
    }

    func testEveryURLForwardedBeforeStartIsDelivered() async {
        let api = FakeAPI { request in
            let slug = URL(string: lookup(of: request)!)!.lastPathComponent
            return ok(route: "/p/\(slug)", linkId: "link_\(slug)")
        }
        let sdk = makeSDK(api)
        sdk.handle(url("https://\(host)/first"))
        sdk.handle(url("https://\(host)/first"))  // reported twice by the OS
        sdk.handle(url("https://\(host)/second"))
        await sdk.start()

        let received = collect(sdk)
        await waitUntil("both delivered") { received.value.count == 2 }
        await settle()
        XCTAssertEqual(Set(received.value.map(\.routePath)), ["/p/first", "/p/second"])
        XCTAssertEqual(api.resolves.value.count, 2)
        sdk.stop()
    }

    func testDeduplicatesALaunchLinkThatIsReplayedOnTheStream() async {
        let api = FakeAPI()
        let sdk = makeSDK(
            api, source: FakeLinkSource(launchURL: invite, replayLaunchURLOnStream: true))
        let received = collect(sdk)
        await sdk.start()
        await waitUntil("delivered and reported") {
            received.value.count == 1 && api.eventBodies.value.count == 1
        }
        await settle()

        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(api.resolves.value.count, 1)
        XCTAssertEqual(api.eventBodies.value.count, 1)
        sdk.stop()
    }

    func testDeduplicatesALaunchLinkReportedByBothHandleAndTheSource() async {
        let api = FakeAPI()
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: invite))
        sdk.handle(invite)
        let initial = await sdk.initialLink()
        XCTAssertNotNil(initial)
        await settle()
        XCTAssertEqual(api.resolves.value.count, 1)
        sdk.stop()
    }

    func testInitialLinkConsumesTheLaunchLinkSoTheStreamDoesNotRepeatIt() async {
        let sdk = makeSDK(FakeAPI(), source: FakeLinkSource(launchURL: invite))
        let initial = await sdk.initialLink()
        XCTAssertEqual(initial?.routePath, "/invite/abc123")
        let again = await sdk.initialLink()
        XCTAssertNil(again)

        let received = collect(sdk)
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        sdk.stop()
    }

    func testInitialLinkReturnsNilOnceAListenerAlreadyReceivedIt() async {
        let sdk = makeSDK(FakeAPI(), source: FakeLinkSource(launchURL: invite))
        let received = collect(sdk)
        await sdk.start()
        await waitUntil("delivered") { received.value.count == 1 }
        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        sdk.stop()
    }

    func testNoLaunchLinkForeignLaunchLinkAndRepeatedStartAreHarmless() async {
        let api = FakeAPI()
        let errors = Box<[StrybokError]>([])
        let source = FakeLinkSource(launchURL: url("https://other.example.com/x"))
        let sdk = makeSDK(api, source: source, errors: errors)
        async let first: Void = sdk.start()
        async let second: Void = sdk.start()
        _ = await (first, second)
        await sdk.start()
        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        XCTAssertTrue(api.resolves.value.isEmpty)
        XCTAssertTrue(errors.value.isEmpty)

        let bare = makeSDK(api)
        await bare.start()
        let none = await bare.initialLink()
        XCTAssertNil(none)
        XCTAssertTrue(api.resolves.value.isEmpty)
        sdk.stop()
        bare.stop()
    }

    func testAFailingLaunchLinkIsReportedThroughOnErrorAndStartCompletes() async {
        let errors = Box<[StrybokError]>([])
        let sdk = makeSDK(
            FakeAPI { _ in StrybokHTTPResponse(statusCode: 404) },
            source: FakeLinkSource(launchURL: invite),
            errors: errors
        )
        await sdk.start()
        XCTAssertEqual(errors.value.count, 1)
        if case .linkNotFound(let failed)? = errors.value.first {
            XCTAssertEqual(failed, invite)
        } else {
            XCTFail("Unexpected errors: \(errors.value)")
        }
        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        sdk.stop()
    }
}

final class RunningAppTests: XCTestCase {
    private func slugAPI() -> FakeAPI {
        FakeAPI { request in
            let slug = URL(string: lookup(of: request)!)!.lastPathComponent
            return ok(route: "/p/\(slug)", linkId: "link_\(slug)")
        }
    }

    func testDeliversEachForegroundLinkExactlyOnce() async {
        let api = slugAPI()
        let source = FakeLinkSource()
        let sdk = makeSDK(api, source: source)
        let received = collect(sdk)
        await sdk.start()

        source.emit(url("https://\(host)/first"))
        source.emit(url("https://\(host)/second"))
        source.emit(url("https://evil.example.com/third"))
        await waitUntil("two links") { received.value.count == 2 }
        await settle()

        XCTAssertEqual(Set(received.value.map(\.routePath)), ["/p/first", "/p/second"])
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(api.resolves.value.count, 2)
        sdk.stop()
    }

    func testDeliversLinksForwardedWithHandle() async {
        let api = slugAPI()
        let errors = Box<[StrybokError]>([])
        let sdk = makeSDK(api, errors: errors)
        let received = collect(sdk)
        await sdk.start()

        XCTAssertTrue(sdk.handle(url("https://\(host)/first?utm=1")))
        XCTAssertTrue(sdk.handle(url("https://\(host)/second")))
        XCTAssertFalse(sdk.handle(url("https://evil.example.com/third")))
        await waitUntil("two links") { received.value.count == 2 }
        await settle()

        XCTAssertEqual(Set(received.value.map(\.routePath)), ["/p/first", "/p/second"])
        XCTAssertEqual(api.resolves.value.count, 2)
        XCTAssertTrue(errors.value.isEmpty, "foreign URLs are dropped silently")
        sdk.stop()
    }

    func testTheAsyncStreamReceivesQueuedAndLaterLinksInOrder() async {
        let api = slugAPI()
        let sdk = makeSDK(api)
        await sdk.start()
        sdk.handle(url("https://\(host)/queued"))
        await waitUntil("resolved while nobody listens") { api.resolves.value.count == 1 }
        await settle()

        var iterator = sdk.links().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.routePath, "/p/queued")

        sdk.handle(url("https://\(host)/later"))
        let second = await iterator.next()
        XCTAssertEqual(second?.routePath, "/p/later")
        sdk.stop()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testDropsAnImmediateDuplicateButHonoursTheSameLinkTappedAgainLater() async {
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let api = FakeAPI()
        let source = FakeLinkSource()
        let sdk = makeSDK(api, source: source, now: { now.value })
        let received = collect(sdk)
        await sdk.start()

        source.emit(invite)
        source.emit(invite)
        sdk.handle(invite)
        await waitUntil("first tap") { received.value.count == 1 }
        await settle()
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(api.resolves.value.count, 1)

        // App in the background, the user taps the same link again a minute later.
        now.mutate { $0 += 60 }
        source.emit(invite)
        await waitUntil("second tap") { received.value.count == 2 }
        await settle()
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(api.resolves.value.count, 2)
        sdk.stop()
    }

    func testMultipleListenersEachSeeALinkOnce() async {
        let sdk = makeSDK(FakeAPI())
        let a = collect(sdk)
        let b = collect(sdk)
        let stream = sdk.links()
        await sdk.start()
        sdk.handle(invite)
        await waitUntil("both callbacks") { a.value.count == 1 && b.value.count == 1 }
        var iterator = stream.makeAsyncIterator()
        let fromStream = await iterator.next()
        XCTAssertEqual(fromStream?.linkId, "link_1")
        await settle()
        XCTAssertEqual(a.value.count, 1)
        XCTAssertEqual(b.value.count, 1)
        sdk.stop()
    }

    func testACancelledListenerStopsReceivingAndLinksAreQueuedAgain() async {
        let api = slugAPI()
        let sdk = makeSDK(api)
        let received = Box<[ResolvedLink]>([])
        let token = sdk.addListener { received.append($0) }
        await sdk.start()
        sdk.handle(url("https://\(host)/one"))
        await waitUntil("first") { received.value.count == 1 }

        token.cancel()
        await settle()
        sdk.handle(url("https://\(host)/two"))
        await waitUntil("second resolved") { api.resolves.value.count == 2 }
        await settle()
        XCTAssertEqual(received.value.count, 1)

        let late = collect(sdk)
        await waitUntil("queued link handed to the next listener") { late.value.count == 1 }
        XCTAssertEqual(late.value.first?.routePath, "/p/two")
        sdk.stop()
    }

    func testErrorsGoToOnErrorAndDeliveryKeepsWorking() async {
        let fail = Box(true)
        let errors = Box<[StrybokError]>([])
        let source = FakeLinkSource()
        let sdk = makeSDK(
            FakeAPI { _ in
                if fail.value { throw Offline() }
                return ok()
            },
            source: source,
            errors: errors,
            maxRetries: 0
        )
        let received = collect(sdk)
        await sdk.start()

        let offline = url("https://\(host)/offline1")
        source.emit(offline)
        await waitUntil("error reported") { errors.value.count == 1 }
        if case .network(let failed, _)? = errors.value.first {
            XCTAssertEqual(failed, offline)
        } else {
            XCTFail("Unexpected errors: \(errors.value)")
        }
        XCTAssertTrue(received.value.isEmpty)

        fail.value = false
        source.emit(url("https://\(host)/online1"))
        await waitUntil("delivered") { received.value.count == 1 }
        XCTAssertEqual(errors.value.count, 1)
        sdk.stop()
    }
}

final class AppOpenEventTests: XCTestCase {
    func testSendsOneMinimalBestEffortEventPerDeliveredLink() async throws {
        let api = FakeAPI()
        let sdk = makeSDK(api)
        _ = collect(sdk)
        await sdk.start()
        sdk.handle(invite)
        await waitUntil("event sent") { api.eventBodies.value.count == 1 }
        await settle()

        XCTAssertEqual(api.events.count, 1)
        let event = try XCTUnwrap(api.events.first)
        XCTAssertEqual(Set(event.keys), ["eventId", "linkId", "type", "platform", "sdkVersion"])
        XCTAssertEqual(event["type"] as? String, "app_open")
        XCTAssertEqual(event["linkId"] as? String, "link_1")
        XCTAssertEqual(event["sdkVersion"] as? String, "0.1.0")
        XCTAssertEqual(Strybok.sdkVersion, "0.1.0")
        #if os(iOS)
            XCTAssertEqual(event["platform"] as? String, "ios")
        #else
            // The tests run on macOS, where the SDK reports "unknown".
            XCTAssertEqual(event["platform"] as? String, "unknown")
        #endif
        let eventId = try XCTUnwrap(event["eventId"] as? String)
        XCTAssertNotNil(
            eventId.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                options: .regularExpression),
            eventId)
        sdk.stop()
    }

    func testEventRequestShape() async throws {
        let requests = Box<[URLRequest]>([])
        var configuration = StrybokConfiguration(
            apiBaseURL: url("https://example.com/strybok/"), allowedHosts: [host])
        configuration.transport = StubTransport { request in
            requests.append(request)
            return request.httpMethod == "POST" ? StrybokHTTPResponse(statusCode: 202) : ok()
        }
        let sdk = Strybok(configuration: configuration)
        sdk.handle(invite)
        await sdk.start()
        await waitUntil("event sent") { requests.value.count == 2 }
        let event = try XCTUnwrap(requests.value.first { $0.httpMethod == "POST" })
        XCTAssertEqual(event.url?.absoluteString, "https://example.com/strybok/v1/public/events")
        XCTAssertEqual(event.value(forHTTPHeaderField: "Content-Type"), "application/json")
        sdk.stop()
    }

    func testASlowOrFailingEventsEndpointNeverDelaysOrBreaksDelivery() async {
        let handlers: [FakeAPI.Handler] = [
            { _ in try await hang() },
            { _ in throw Offline() },
            { _ in StrybokHTTPResponse(statusCode: 500) },
        ]
        for handler in handlers {
            let api = FakeAPI()
            api.onEvent.value = handler
            let errors = Box<[StrybokError]>([])
            let sdk = makeSDK(api, errors: errors, timeout: 0.3)
            let received = collect(sdk)
            sdk.handle(invite)
            await sdk.start()
            await waitUntil("delivered") { received.value.count == 1 }
            await waitUntil("event attempted") { api.eventBodies.value.count == 1 }
            await settle()
            XCTAssertEqual(received.value.count, 1)
            XCTAssertTrue(errors.value.isEmpty)
            XCTAssertEqual(api.eventBodies.value.count, 1, "events are not retried")
            sdk.stop()
        }
    }

    func testCanBeTurnedOff() async {
        let api = FakeAPI()
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: invite), reportAppOpens: false)
        await sdk.start()
        let received = collect(sdk)
        await waitUntil("delivered") { received.value.count == 1 }
        await settle()
        XCTAssertTrue(api.eventBodies.value.isEmpty)
        sdk.stop()
    }
}

final class StopTests: XCTestCase {
    func testStopsDeliveryFinishesTheStreamAndRejectsFurtherUse() async {
        let api = FakeAPI()
        let source = FakeLinkSource()
        let sdk = makeSDK(api, source: source)
        let received = collect(sdk)
        let finished = Box(false)
        let stream = sdk.links()
        Task {
            for await _ in stream {}
            finished.value = true
        }
        await sdk.start()
        XCTAssertTrue(source.hasSubscribers)

        sdk.stop()
        sdk.stop()  // idempotent
        await waitUntil("unsubscribed from the source") { !source.hasSubscribers }
        await waitUntil("stream finished") { finished.value }

        source.emit(invite)
        XCTAssertTrue(sdk.handle(invite), "still recognised, but dropped")
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(api.resolves.value.isEmpty)

        await assertThrows(sdk, invite) {
            if case .cancelled = $0 { return true }
            return false
        }
        await sdk.start()  // no-op
        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        var late = sdk.links().makeAsyncIterator()
        let nothing = await late.next()
        XCTAssertNil(nothing)
        XCTAssertTrue(api.resolves.value.isEmpty)
    }

    func testALinkStillResolvingWhenStoppedIsNotDelivered() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let errors = Box<[StrybokError]>([])
        let api = FakeAPI { _ in
            // Ignores cancellation on purpose: the answer arrives after stop().
            await Task { for await _ in gate {} }.value
            return ok()
        }
        let sdk = makeSDK(api, errors: errors)
        let received = collect(sdk)
        await sdk.start()
        sdk.handle(invite)
        await waitUntil("request in flight") { api.resolves.value.count == 1 }

        sdk.stop()
        open.finish()
        await settle()
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(errors.value.isEmpty)
        XCTAssertTrue(api.eventBodies.value.isEmpty)
    }

    func testStoppingWhileTheLaunchLinkResolvesLetsStartReturn() async {
        let errors = Box<[StrybokError]>([])
        let api = FakeAPI { _ in try await hang() }
        let sdk = makeSDK(api, source: FakeLinkSource(launchURL: invite), errors: errors)
        let started = Task { await sdk.start() }
        await waitUntil("request in flight") { api.resolves.value.count == 1 }
        sdk.stop()
        await started.value
        let initial = await sdk.initialLink()
        XCTAssertNil(initial)
        XCTAssertTrue(errors.value.isEmpty)
    }

    func testLinksBufferedInAnUnreadStreamAreNotDeliveredAfterStop() async {
        let api = FakeAPI()
        let sdk = makeSDK(api)
        let stream = sdk.links()
        await sdk.start()
        sdk.handle(invite)
        await waitUntil("resolved and reported") { api.eventBodies.value.count == 1 }

        sdk.stop()
        var iterator = stream.makeAsyncIterator()
        let link = await iterator.next()
        XCTAssertNil(link)
    }

    func testReleasingTheSDKUnsubscribesFromTheSource() async {
        let source = FakeLinkSource()
        var sdk: Strybok? = makeSDK(FakeAPI(), source: source)
        await sdk?.start()
        XCTAssertTrue(source.hasSubscribers)
        sdk = nil
        await waitUntil("unsubscribed") { !source.hasSubscribers }
    }
}
