#if canImport(UIKit) && os(iOS)
    import UIKit

    extension Strybok {
        /// Cold start with scenes: call from `scene(_:willConnectTo:options:)`, before
        /// ``start()``, so the Universal Link that launched the app becomes the launch link.
        ///
        /// - Returns: `true` when the options contained a Strybok link of this app.
        @MainActor
        @discardableResult
        public func handle(connectionOptions: UIScene.ConnectionOptions) -> Bool {
            var handled = false
            for userActivity in connectionOptions.userActivities {
                if handle(userActivity: userActivity) { handled = true }
            }
            return handled
        }
    }
#endif
