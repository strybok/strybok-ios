import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

final class LinkMatchingTests: XCTestCase {
    private let sdk = Strybok(
        configuration: StrybokConfiguration(
            apiBaseURL: apiBase, allowedHosts: ["My-App.Strybok.Link"]))

    func testAcceptsHTTPSLinksOnAnAllowedHostWithASingleSlug() {
        XCTAssertTrue(sdk.isStrybokLink(invite))
        XCTAssertTrue(sdk.isStrybokLink(url("https://MY-APP.strybok.link/AbC_7-x")))
        XCTAssertTrue(sdk.isStrybokLink(url("https://\(host)/abc?utm=1#frag")))
        XCTAssertTrue(sdk.isStrybokLink(url("https://\(host):443/abc")))
        XCTAssertTrue(sdk.isStrybokLink(url("https://\(host)/" + String(repeating: "a", count: 64))))
    }

    func testRejectsEverythingElse() {
        for candidate in [
            "http://\(host)/invite777",
            "myapp://\(host)/invite777",
            "https://evil.example.com/invite777",
            "https://\(host).evil.example.com/invite777",
            "https://evil-\(host)/invite777",
            "https://user:pw@\(host)/invite777",
            "https://user@\(host)/invite777",
            "https://\(host):8443/invite777",
            "https://\(host)",
            "https://\(host)/",
            "https://\(host)/a/b",
            "https://\(host)/abc/",
            "https://\(host)/.well-known/apple-app-site-association",
            "https://\(host)/a%2Fb",
            "https://\(host)/a.b",
            "https://\(host)/" + String(repeating: "a", count: 65),
        ] {
            XCTAssertFalse(sdk.isStrybokLink(url(candidate)), candidate)
        }
    }

    func testResolveRefusesForeignLinksWithoutAnyNetworkCall() async {
        let api = FakeAPI()
        let sdk = makeSDK(api)
        await assertThrows(sdk, url("https://evil.example.com/invite777")) {
            if case .unsupportedLink = $0 { return true }
            return false
        }
        XCTAssertTrue(api.resolves.value.isEmpty)
    }

    func testHandleReportsWhetherTheURLIsOurs() {
        let sdk = makeSDK(FakeAPI())
        XCTAssertTrue(sdk.handle(invite))
        XCTAssertFalse(sdk.handle(url("https://evil.example.com/invite777")))
        XCTAssertFalse(sdk.handle(url("myapp://open/invite777")))

        let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        web.webpageURL = invite
        XCTAssertTrue(sdk.handle(userActivity: web))

        let other = NSUserActivity(activityType: "com.example.other")
        other.webpageURL = invite
        XCTAssertFalse(sdk.handle(userActivity: other))
        XCTAssertFalse(
            sdk.handle(userActivity: NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)))
    }
}
