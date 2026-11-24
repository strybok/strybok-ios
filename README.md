# Strybok (iOS SDK)

Swift package that takes the Universal Links your app receives, resolves them through the Strybok
API to an in-app route and payload, and delivers each link exactly once — on cold start, from the
background and in the foreground. No third-party dependencies. iOS 13+.

```swift
import Strybok

let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"]
))

// iOS has no global URL stream: forward what the OS gives you
// (scene delegate, app delegate or SwiftUI `.onOpenURL`).
strybok.handle(url)

await strybok.start()
for await link in strybok.links() {
    router.open(link.routePath, payload: link.payload)
}
```

Full guide, native setup and troubleshooting: [`docs/ios-sdk.md`](./docs/ios-sdk.md).
Behaviour shared by all SDKs: [`docs/sdk-contract.md`](./docs/sdk-contract.md).

- Verified by unit tests on macOS and the iOS Simulator only, **not on a physical device**.
- Deferred deep linking is not supported.

## Install

Swift Package Manager, in Xcode (_File → Add Package Dependencies…_ with the URL below) or in
`Package.swift`:

```swift
.package(url: "https://github.com/strybok/strybok-ios", from: "0.1.0"),
```

and add the product to your target: `.product(name: "Strybok", package: "strybok-ios")`. A local
clone works too: `.package(path: "../strybok-ios")`.

## Build and test

In the SDK directory:

```sh
swift build
swift test
```

## Licence

Apache 2.0, see [LICENSE](./LICENSE).
