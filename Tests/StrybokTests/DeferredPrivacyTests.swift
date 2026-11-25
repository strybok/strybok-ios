import Foundation
import StrybokTesting
import XCTest

@testable import Strybok

/// What deferred links may touch: the pasteboard only through pattern detection, and
/// storage only for `attempts` and `done`.
final class DeferredPrivacyTests: XCTestCase {
    // MARK: Pasteboard

    /// The SDK must never call a pasteboard API that returns content. This scans the
    /// shipped sources: `UIPasteboard` may appear in code only as one of the two
    /// pattern-detection calls on the general pasteboard.
    func testTheSourcesUseThePasteboardOnlyForPatternDetection() throws {
        let allowed = [
            "UIPasteboard.general.detectedPatterns(for:",
            "UIPasteboard.general.detectPatterns(for:",
        ]
        let files = try sourceFiles()
        XCTAssertGreaterThan(files.count, 10, "the scan must see the SDK's sources")

        var uses = 0
        for file in files {
            let code = Self.withoutComments(try String(contentsOf: file, encoding: .utf8))
            XCTAssertNil(
                code.range(of: "pasteboard", options: .caseInsensitive).flatMap { _ in
                    Self.firstForbiddenPasteboardUse(in: code, allowed: allowed)
                },
                "\(file.lastPathComponent) uses the pasteboard for something other than pattern detection"
            )
            uses += code.components(separatedBy: "UIPasteboard").count - 1
            // Other spellings of the same thing, and UI the SDK must not ship.
            for forbidden in [
                "NSPasteboard", "UIPasteControl", "PasteButton", "detectValues", "detectedValues",
                "hasStrings", "hasURLs", "itemProviders", "generalPasteboard",
            ] {
                XCTAssertFalse(
                    code.contains(forbidden), "\(file.lastPathComponent) must not use \(forbidden)")
            }
        }
        XCTAssertEqual(uses, 2, "exactly the two pattern-detection calls (iOS 15+, iOS 14)")
    }

    func testTheScannerRejectsContentReadingCalls() {
        let allowed = ["UIPasteboard.general.detectedPatterns(for:"]
        for bad in [
            "let text = UIPasteboard.general.string",
            "let board = UIPasteboard.general",
            "UIPasteboard.general.detectValues(for: [.probableWebURL]) { _ in }",
            "UIPasteboard.general.urls",
            "let type = UIPasteboard.self",
            #"NSClassFromString("UIPasteboard")"#,
        ] {
            XCTAssertNotNil(Self.firstForbiddenPasteboardUse(in: bad, allowed: allowed), bad)
        }
        XCTAssertNil(
            Self.firstForbiddenPasteboardUse(
                in: #"try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL])"#,
                allowed: allowed))
        XCTAssertNil(
            Self.firstForbiddenPasteboardUse(
                in: Self.withoutComments("/// Never call `UIPasteboard.general.string`.\nlet x = 1"),
                allowed: allowed))
    }

    /// The first `UIPasteboard` in `code` that is not the start of an allowed call.
    private static func firstForbiddenPasteboardUse(in code: String, allowed: [String]) -> String? {
        var rest = Substring(code)
        while let range = rest.range(of: "UIPasteboard") {
            let here = rest[range.lowerBound...]
            if !allowed.contains(where: { here.hasPrefix($0) }) { return String(here.prefix(60)) }
            rest = rest[range.upperBound...]
        }
        return nil
    }

    /// Drops `//` comments (documentation may name the APIs that are forbidden).
    private static func withoutComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            // "://" inside a string literal is not a comment.
            var search = line.startIndex
            while let range = line.range(of: "//", range: search..<line.endIndex) {
                if range.lowerBound == line.startIndex || line[line.index(before: range.lowerBound)] != ":" {
                    return line[..<range.lowerBound]
                }
                search = range.upperBound
            }
            return line
        }.joined(separator: "\n")
    }

    private func sourceFiles() throws -> [URL] {
        // <package root>/Tests/StrybokTests/DeferredPrivacyTests.swift
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: Storage

    func testTheDefaultStoreIsUserDefaultsNotTheKeychain() {
        let configuration = StrybokConfiguration(apiBaseURL: apiBase, allowedHosts: [host])
        let context = DeferredLinkContext(configuration)
        XCTAssertTrue(
            context.store is UserDefaultsDeferredLinkStore,
            "app storage, so deleting the app resets it")
    }

    func testUserDefaultsStoreKeepsOnlyTheTwoValuesPerScope() {
        let store = UserDefaultsDeferredLinkStore()
        let scope = "test.\(UUID().uuidString)"
        let other = "test.\(UUID().uuidString)"
        let prefix = UserDefaultsDeferredLinkStore.prefix
        defer {
            for name in ["attempts", "done"] {
                UserDefaults.standard.removeObject(forKey: "\(prefix)\(scope).\(name)")
            }
        }
        XCTAssertEqual(store.attempts(scope: scope), 0)
        XCTAssertFalse(store.isDone(scope: scope))

        store.setAttempts(2, scope: scope)
        store.setDone(scope: scope)
        XCTAssertEqual(UserDefaultsDeferredLinkStore().attempts(scope: scope), 2)
        XCTAssertTrue(UserDefaultsDeferredLinkStore().isDone(scope: scope))
        XCTAssertEqual(store.attempts(scope: other), 0)
        XCTAssertFalse(store.isDone(scope: other))

        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(prefix + scope)
        }
        XCTAssertEqual(keys.sorted(), ["\(prefix)\(scope).attempts", "\(prefix)\(scope).done"])
    }

    func testTheScopeSeparatesHostsAndAppsWithoutNamingThem() {
        let scope = DeferredLinkContext.scope(apiBaseURL: apiBase, bundleId: testBundleId)
        XCTAssertEqual(
            scope,
            DeferredLinkContext.scope(
                apiBaseURL: url("HTTPS://API.strybok.com/"), bundleId: testBundleId))
        XCTAssertNotEqual(
            scope, DeferredLinkContext.scope(apiBaseURL: apiBase, bundleId: "com.example.other"))
        XCTAssertNotEqual(
            scope,
            DeferredLinkContext.scope(
                apiBaseURL: url("https://api.staging.example"), bundleId: testBundleId))
        XCTAssertNotEqual(
            scope,
            DeferredLinkContext.scope(apiBaseURL: url("https://api.strybok.com/v2"), bundleId: testBundleId))
        XCTAssertFalse(scope.contains("example"))
        XCTAssertFalse(scope.contains("strybok"))
    }

    /// Runs both flows through every kind of answer and checks that the store only ever
    /// saw the counter and the flag: not the pasted string, not the code, nothing from
    /// an answer.
    func testNothingButAttemptsAndDoneIsEverStored() async {
        let stores = [FakeDeferredStore(), FakeDeferredStore(), FakeDeferredStore()]
        let pasted = makeDeferred(store: stores[0])
        _ = await pasted.sdk.redeemPastedLink("my secret note")
        _ = await pasted.sdk.redeemPastedLink(pastedLink + "&token=s3cr3t")
        pasted.sdk.stop()

        let matched = makeDeferred(store: stores[1], matching: true)
        await matched.sdk.start()
        await waitForStatus(matched.sdk, .delivered)
        matched.sdk.stop()

        let refused = makeDeferred(
            api: DeferredAPI(redeem: { _ in .json("{}", statusCode: 404) }), store: stores[2])
        _ = await refused.sdk.redeemPastedLink(pastedLink)
        refused.sdk.stop()

        for store in stores {
            XCTAssertFalse(store.writes.value.isEmpty)
            for write in store.writes.value {
                XCTAssertTrue(
                    write.what == "done" || write.what.range(of: #"^attempts=[1-3]$"#, options: .regularExpression) != nil,
                    "unexpected write: \(write.what)")
                for text in [write.scope, write.what] {
                    for secret in [clickId, "invite", "secret", "s3cr3t", "link_d", host, testBundleId] {
                        XCTAssertFalse(text.contains(secret), "\(secret) must not be stored")
                    }
                }
            }
        }
    }

    func testResolvedLinkDescriptionAndStatusHoldNoCode() async {
        let fixture = makeDeferred()
        let received = collect(fixture.sdk)
        _ = await fixture.sdk.redeemPastedLink(pastedLink)
        await waitUntil("delivered") { received.value.count == 1 }
        let link = received.value[0]
        XCTAssertFalse(link.url.absoluteString.contains("strybok_click"))
        XCTAssertFalse(String(describing: link).contains(clickId))
        XCTAssertFalse(String(reflecting: link).contains(clickId))
        fixture.sdk.stop()
    }
}
