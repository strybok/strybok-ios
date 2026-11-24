# Strybok (iOS SDK)

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fstrybok%2Fstrybok-ios%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/strybok/strybok-ios) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fstrybok%2Fstrybok-ios%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/strybok/strybok-ios) [![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](./LICENSE)

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

It can also create links for a "Share" button:

```swift
let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    clientKey: "pk_…"  // publishable key from the dashboard, never a secret API key
))
let link = try await strybok.createLink(routePath: "/product/42", payload: ["productId": 42])
share(link.url)
```

Full guide, native setup and troubleshooting: [`docs/ios-sdk.md`](./docs/ios-sdk.md).
Behaviour shared by all SDKs: [`docs/sdk-contract.md`](./docs/sdk-contract.md).

- Verified by unit tests on macOS and the iOS Simulator only, **not on a physical device**.
- Deferred deep linking is not supported.

## Install

Swift Package Manager, in Xcode (_File → Add Package Dependencies…_ with the URL below) or in
`Package.swift`:

```swift
.package(url: "https://github.com/strybok/strybok-ios", from: "0.2.0"),
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
