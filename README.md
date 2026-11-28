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

Every link also has `campaign`: the link's campaign values with the `utm_*` parameters of the
tapped URL on top (`source`, `medium`, `campaign`, `term`, `content`; each `nil` when not set).
They are labels chosen by whoever shared the link, so use them for attribution only, for example
`link.campaign.source`.

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
- A link tapped before the app is installed is not restored by default: iOS has no automatic
  deferred deep linking. Two opt-in flows exist, each with a cost, see
  [Deferred links (optional)](#deferred-links-optional).

## Links without an API call

From 0.5.0, optional and off by default. When the owner switches them on in the dashboard, path
links (`https://my-app.strybok.link/product/42?id=7`) and Firebase long links
(`https://my-app.strybok.link/?link=…`) open the app without a link being created first. Pass the
payload keys of your application — `parameterLinks.payloadKeys` of the integration guide
(`GET /v1/apps/:appId/integration`, shown on the dashboard's setup screen):

```swift
let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    parameterLinks: try! ParameterLinks(payloadKeys: ["id", "lang"])
))
```

The link arrives through `links()` like any other; its `routePath` and `payload` are what the
service read, never the tapped path. Of the tapped URL only the path, the first value of each of
these keys and the `utm_*` values are sent (for a long link: the deep link's scheme, host and path
with its values of these keys, plus `apn` and `ibi`). Without the option the SDK sends exactly what
0.4.0 sent; deferred links always keep the single-slug rule. Invalid keys make
`ParameterLinks(payloadKeys:)` throw `StrybokConfigurationError`. **Unit-tested only, never run on
a device.** Details:
[`docs/ios-sdk.md`](./docs/ios-sdk.md#links-without-an-api-call).

## Deferred links (optional)

The App Store passes nothing from a link to a newly installed app. The SDK has two ways to get the
link back anyway. Both are **off by default**, each needs a switch in the dashboard **and** an
option in code, and **neither has run on a device, against the real pasteboard or the real
service** (unit tests with fakes; compiled for iOS). Apple's own mechanisms (custom product pages,
App Clips) are the first recommendation:
[`docs/ios.md`](./docs/ios.md#links-tapped-before-the-app-is-installed).

A restored link arrives through `links()` or your listener like any other, exactly once, with
`isDeferred == true`. `initialLink()` never returns it, no `app_open` is sent for it and nothing is
reported to `onError`.

### A. Pasted link

Dashboard: **Setup** → **iOS: links tapped before the app is installed** → **Copy and paste the
link**. Code: `StrybokConfiguration(…, deferredLinks: true)`, or `strybok.enableDeferredLinks()`
later (for example after a consent screen).

iOS visitors without the app then see a page with a **Copy link and get the app** button before
the App Store. In your app, show Apple's paste button on the first screen or in onboarding and
hand over what the person pasted:

```swift
// SwiftUI, iOS 16 or later. UIKit: `UIPasteControl`, see the guide.
PasteButton(payloadType: String.self) { strings in
    guard let text = strings.first else { return }
    Task {
        switch await strybok.redeemPastedLink(text) {
        case .delivered: break  // arrives through links() with isDeferred == true
        case .notOurs, .notFound, .alreadyHandled, .disabled: break  // carry on silently
        case .failed: break  // not reachable: the person can tap Paste again
        }
    }
}
```

**The SDK never reads the clipboard**: it has no call that returns pasteboard content (a test
scans the sources), you pass the string in, and of it only the single-use code is sent, with the
bundle identifier and the SDK version. Text that is not a link of your app with a valid code is
dropped without any request. `pasteboardMayContainLink()` (optional) tells you whether the
clipboard _probably_ holds a web address, using the system's pattern detection, which reads no
content and shows no banner. Do not paste automatically, and describe the step in your App Review
notes.

What it costs:

- **Every** iOS visitor without the app gets one extra page and one extra tap before the App
  Store.
- It only works if the person taps the copy button and later taps Paste in your app. Nobody
  publishes how many people do; expect a minority.
- It replaces whatever was on their clipboard, and Universal Clipboard may carry the link to their
  other devices.
- The code works once, for 24 hours.
- You have to build the paste step into your onboarding. Apple's paste button needs iOS 16.

### B. Probabilistic matching (not recommended)

The service guesses the link from the IP address, the device type and the language of the first
launch. Dashboard: **Not recommended: probabilistic matching** → **Match the first launch to a
recent tap**, plus **Allow probabilistic matching on iOS for this link** on each link. Code:
`StrybokConfiguration(…, deferredLinks: true, allowProbabilisticMatching: true)`.

After `start()` has finished (never as part of it) the SDK sends the bundle identifier, the device
family (`iphone`, `ipad`, `ipod`), the first preferred language and the SDK version — nothing
else. A matched link has `isDeferred` **and** `isProbabilisticMatch` set. **Check
`isProbabilisticMatch`**: such a link must never by itself sign anyone in, accept an invitation,
apply a personal discount or show personal content. When the paste flow is used too, call
`strybok.skipPastedLink()` when the person leaves the paste screen; the pasted link wins over a
guess.

What it costs — read all of it:

- **Apple forbids it.** The App Store Review Guidelines and the Apple Developer Program License
  Agreement do not allow deriving data from a device to identify it (fingerprinting), with or
  without the user's consent. The App Review and legal risk is the app owner's, not Strybok's.
- **A wrong match shows one person another person's link** — on shared Wi-Fi, in offices and
  universities, behind mobile carrier NAT. That is why it is opt-in per link: never allow
  invitations, links that grant access, or anything personal.
- **It does not work with iCloud Private Relay or a VPN**, when the person changes network between
  the tap and the first launch, for most iPads, or after the time window (15 minutes to 6 hours).
- **It changes your privacy obligations.** Strybok processes your visitors' IP addresses for it.
  Your privacy policy and App Store privacy labels must cover that, and you may need consent under
  GDPR/ePrivacy. Not legal advice.
- **Nobody knows how accurate it is.** Wrong matches cannot be measured.

State (`UserDefaults`, removed with the app): a counter of matching attempts (three launches at
most) and a "done" flag. Once either flow delivered a link or a pasted code got a definite answer,
neither does anything again in that installation. `strybok.deferredLinkStatus` /
`deferredLinkStatuses()` say where things stand, for development and QA.

Details, the UIKit sample, every result and status:
[`docs/ios-sdk.md`](./docs/ios-sdk.md#10-deferred-links-optional).

## Privacy manifest

From 0.4.0 the `Strybok` target ships `PrivacyInfo.xcprivacy`, so the SDK shows up in Xcode's
privacy report without any work on your side. What it declares, and why:

| Entry                                                                    | Why                                                                                                                                                                                                                    |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NSPrivacyTracking` `false`, no tracking domains                         | The SDK links no data with data from other companies and talks only to the API host you configure                                                                                                                      |
| Collected data: product interaction, not linked, not tracking, analytics | The `app_open` event (on by default): a random event id, the link id, the platform, the SDK version and the link's campaign labels, kept by the service for link analytics. Declared even with `reportAppOpens: false` |
| Required reason API: `UserDefaults`, reason `CA92.1`                     | With `deferredLinks` on, a counter and a flag are kept in `UserDefaults.standard`; only the app itself reads and writes them. Declared always, because the code is in the binary whether or not the option is used     |

Not declared, on purpose:

- **Resolving a link** sends the link's host and slug and its campaign parameters and gets an
  answer; the service keeps nothing about the person or the device for it, so in Apple's sense
  nothing is collected.
- **`createLink`** stores the link your app asks for (route, payload, preview texts). That is
  content your app chooses to send, not something the SDK gathers; if you put personal data in
  it, declaring that is yours.
- **Probabilistic matching** (`allowProbabilisticMatching`, off by default). With it on, the
  service identifies the device from its IP address, device family and language and keeps a
  keyed hash for up to six hours. We did not put that into the SDK's manifest: it would be
  false for every app that leaves the option off, a manifest cannot depend on an option, and no
  declaration makes fingerprinting acceptable under Apple's rules. **If you switch it on, your
  own app's privacy manifest, privacy labels and privacy policy must cover it** — in our
  reading at least the "Device ID" data type. That reading is ours, not Apple's.
- **Attestation** (`attestation`, off by default). The service keeps the App Attest key id of
  the installation. If you switch it on, consider declaring a device-level identifier in your
  own manifest.

The key names, the `UserDefaults` category and the reason code `CA92.1` were checked against
Apple's documentation on 2026-11-25. The manifest has **not been through an App Store Connect
upload**, and it describes the SDK only: your App Store privacy answers remain yours.

## Extra protection (App Attest)

The client key is public. You can ask Strybok to accept link requests only — or preferably — from
a genuine build of your app on a genuine device, proved with Apple's App Attest. It is optional
and off by default.

1. Dashboard: the application needs your Apple Team ID and bundle ID; then **Setup** → **Links
   from the app** → **Extra protection (optional)** → **Preferred** (start here) or **Required**.
2. Xcode: app target → **Signing & Capabilities** → **+ Capability** → **App Attest** (the
   `com.apple.developer.devicecheck.appattest-environment` entitlement).
3. SDK: `StrybokConfiguration(…, clientKey: "pk_…", attestation: true)`.

The proof is made only inside `createLink`, never in `start()` or for incoming links. Where it
cannot be made the request is sent without it and the server decides: the link is created, or
with **Required** `createLink` throws `.attestationRequired`. A token refused twice in a row is
`.attestationFailed(reason:)`.

Honest limits:

- iOS 14 or later on a **real device**. It does not work in the Simulator, on iOS 13, in most app
  extensions or on some Macs running iOS apps.
- **Never verified against Apple's real App Attest service or on a device.** It is covered by
  unit tests with a fake App Attest and a stub server and compiles for iOS; no real attestation
  has been made with it. Try it on your own device with **Preferred** before choosing
  **Required**.

Details: [`docs/ios-sdk.md`](./docs/ios-sdk.md) and
[`docs/link-creation-security.md`](./docs/link-creation-security.md).

## Install

Swift Package Manager, in Xcode (_File → Add Package Dependencies…_ with the URL below) or in
`Package.swift`:

```swift
.package(url: "https://github.com/strybok/strybok-ios", from: "0.5.0"),
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
