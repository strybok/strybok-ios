import Foundation

/// An extra source of incoming URLs, besides the ones the app forwards with
/// ``Strybok/handle(_:)``.
///
/// iOS has no global URL stream, so apps normally do not need this: they forward URLs
/// from their scene delegate or SwiftUI `onOpenURL`. A `LinkSource` exists so the SDK
/// can be driven without a device (see `FakeLinkSource` in `StrybokTesting`) and for
/// custom integrations that already own a stream of URLs.
public protocol LinkSource: Sendable {
    /// The URL that launched the app (cold start), or `nil`.
    func launchURL() async -> URL?

    /// URLs received while the app is running. Called once by ``Strybok/start()``,
    /// before `launchURL()`. Implementations may also replay the launch URL here;
    /// the SDK de-duplicates it.
    func urls() -> AsyncStream<URL>
}
