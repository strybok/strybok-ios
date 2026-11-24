import Foundation
import Strybok

/// In-memory `LinkSource` to simulate incoming links in unit and UI tests.
public final class FakeLinkSource: LinkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var launch: URL?
    private var subscribers: [Int: AsyncStream<URL>.Continuation] = [:]
    private var nextID = 0
    private let replayLaunchURLOnStream: Bool

    /// - Parameters:
    ///   - launchURL: URL reported as the one that launched the app.
    ///   - replayLaunchURLOnStream: Mimics platforms that also emit the launch URL on
    ///     the stream.
    public init(launchURL: URL? = nil, replayLaunchURLOnStream: Bool = false) {
        self.launch = launchURL
        self.replayLaunchURLOnStream = replayLaunchURLOnStream
    }

    /// Whether the SDK is currently subscribed.
    public var hasSubscribers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !subscribers.isEmpty
    }

    /// Simulates the OS delivering `url` to the running app.
    public func emit(_ url: URL) {
        lock.lock()
        let targets = Array(subscribers.values)
        lock.unlock()
        for target in targets { target.yield(url) }
    }

    public func launchURL() async -> URL? {
        lock.withLock { launch }
    }

    public func urls() -> AsyncStream<URL> {
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        lock.lock()
        nextID += 1
        let id = nextID
        subscribers[id] = continuation
        let replay = replayLaunchURLOnStream ? launch : nil
        lock.unlock()
        if let replay { continuation.yield(replay) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers[id] = nil
            self.lock.unlock()
        }
        return stream
    }
}
