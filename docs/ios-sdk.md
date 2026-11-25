# iOS SDK integration (Swift)

The `Strybok` Swift package takes the Universal Links iOS hands to your app, asks the Strybok API
which in-app route a link stands for, and gives your app each link exactly once. It follows the
[SDK contract](./sdk-contract.md) shared by all Strybok SDKs.

> **Status:** covered by unit tests that run on macOS and on the iOS Simulator. **Not yet verified
> on a physical device** (see the [manual test plan](./manual-test-plan.md)).
>
> A link tapped before the app is installed is **not restored by default**: the App Store passes
> nothing to a newly installed app, so there is no automatic deferred deep linking on iOS. Two
> opt-in flows exist, each with a cost — a link the person copies and pastes into the app, and
> probabilistic matching, which Apple's rules forbid and we advise against. See
> [Deferred links (optional)](#10-deferred-links-optional). Neither has run on a device.

Requirements: iOS 13 or later, Swift 6 toolchain (Xcode 16 or later). No third-party dependencies.

## 1. Prerequisites

1. Create an application in Strybok with your Team ID and bundle identifier.
2. Read its setup data: `GET /v1/apps/:appId/integration` returns the managed hostname (for
   example `my-app.strybok.link`).
3. Add the **Associated Domains** capability with `applinks:my-app.strybok.link` and check the
   association file, as described in [iOS Universal Links setup](./ios.md). Without it iOS never
   opens the app for your links, and the SDK has nothing to receive.

## 2. Add the package

The SDK is a Swift package in its own repository, `https://github.com/strybok/strybok-ios`.

- **Xcode:** _File → Add Package Dependencies…_, paste `https://github.com/strybok/strybok-ios`
  into the search field, choose the version rule, and add the `Strybok` library to your app
  target.
- **Package.swift:**

  ```swift
  dependencies: [
      .package(url: "https://github.com/strybok/strybok-ios", from: "0.4.0"),
  ],
  targets: [
      .target(
          name: "MyApp",
          dependencies: [.product(name: "Strybok", package: "strybok-ios")]
      ),
  ]
  ```

Alternatively use a local clone: in Xcode _Add Package Dependencies… → Add Local…_ and choose
the cloned directory, or in `Package.swift` write `.package(path: "../strybok-ios")` (the path to
your clone) in place of the `url:` line. The package name in `.product(...)` is the name of that
directory.

## 3. Create one instance

```swift
import Strybok

let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    onError: { error in print("Strybok: \(error)") }
))
```

Keep it for the lifetime of the app (a global, or a property of your app delegate / `App`).
`Strybok` is `Sendable`; every method may be called from any thread.

| Option           | Default    | Meaning                                                               |
| ---------------- | ---------- | --------------------------------------------------------------------- |
| `apiBaseURL`     | required   | Base URL of the API. A path prefix is preserved.                      |
| `allowedHosts`   | required   | Your link hostnames. URLs on any other host are ignored.              |
| `timeout`        | `5`        | Seconds allowed for one resolve attempt.                              |
| `maxRetries`     | `2`        | Extra attempts after a timeout, network error or 5xx.                 |
| `retryDelay`     | `0.4`      | Seconds before the first retry; doubles for each further retry.       |
| `dedupeWindow`   | `2`        | The identical URL received again within this many seconds is dropped. |
| `reportAppOpens` | `true`     | Send a best-effort `app_open` event after a link was resolved.        |
| `onError`        | `nil`      | Receives errors for your links that could not be resolved.            |
| `clientKey`      | `nil`      | Publishable key `pk_…`. Only needed for `createLink` (section 6).     |
| `linkSource`     | `nil`      | Extra source of URLs, for tests (section 9).                          |
| `transport`      | URLSession | HTTP transport, replaceable for tests (section 9).                    |

## 4. Forward URLs and receive links

iOS has no global stream of incoming URLs: the system calls _your_ delegate, and you pass the URL
on with `handle`. The SDK then filters, de-duplicates, resolves and delivers.

- `handle(_ url: URL)` / `handle(userActivity:)` / `handle(connectionOptions:)` — give the SDK
  what iOS gave you. They return `true` when the URL is a Strybok link of this app. URLs that are
  not yours are ignored, so it is safe to forward everything.
- `start()` — begins resolving. URLs forwarded **before** `start()` are kept; the first of them
  is the launch link, and `start()` returns once it has been resolved or has failed.
- `links()` — an `AsyncStream<ResolvedLink>`. Links resolved while nobody was listening
  (typically the cold-start link) are queued and handed to the first subscription.
- `addListener { link in … }` — the same as a callback; returns a token with `cancel()`. The
  callback runs on an arbitrary thread.
- `initialLink()` — the launch link, at most once, removed from the queue. Use it if you want to
  choose the first screen before showing any UI. Using it together with `links()` never
  navigates twice.

### UIKit with scenes

```swift
import Strybok
import UIKit

let strybok = Strybok(configuration: /* see section 3 */)

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var linkTask: Task<Void, Never>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Cold start: the Universal Link that launched the app is in the options.
        strybok.handle(connectionOptions: connectionOptions)

        linkTask = Task { @MainActor [weak self] in
            await strybok.start()
            for await link in strybok.links() {
                self?.open(link)
            }
        }
    }

    // App already running (foreground or background).
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        strybok.handle(userActivity: userActivity)
    }

    @MainActor
    private func open(_ link: ResolvedLink) {
        // Map routePath onto a screen you know; see section 7.
    }
}
```

Without scenes, forward from the app delegate instead; iOS calls it for cold starts too:

```swift
func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
) -> Bool {
    strybok.handle(userActivity: userActivity)
}
```

### SwiftUI

```swift
import Strybok
import SwiftUI

@main
struct MyApp: App {
    private let strybok = Strybok(configuration: /* see section 3 */)
    @State private var route: String?

    var body: some Scene {
        WindowGroup {
            ContentView(route: $route)
                .onOpenURL { url in strybok.handle(url) }
                .task {
                    await strybok.start()
                    for await link in strybok.links() {
                        route = link.routePath  // validate first, see section 7
                    }
                }
        }
    }
}
```

`.task` needs iOS 15; on iOS 13–14 start the loop from `.onAppear` in a `Task` you keep.
SwiftUI passes Universal Links to `onOpenURL`. If your app receives them through
`.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` instead, forward that with
`handle(userActivity:)`. Forwarding from both is harmless: the duplicate is dropped.

In SwiftUI the launch URL may reach `onOpenURL` after `start()` has returned. It is still
delivered exactly once through `links()`; only `initialLink()` returns `nil` in that case, so
prefer `links()` in SwiftUI apps.

### Campaign values

Every `ResolvedLink` has `campaign`: a `LinkCampaign` with the optional strings `source`,
`medium`, `campaign`, `term` and `content`. It is never optional itself; a value that is not set
is `nil`, and `campaign.isEmpty` is true when there are none.

```swift
for await link in strybok.links() {
    if let source = link.campaign.source {  // "instagram"
        analytics.log("link_opened", ["source": source])
    }
    router.open(link.routePath, payload: link.payload)
}
```

- **Where the values come from.** A link can have default values, set per link in the dashboard
  ("Campaign (optional)" in the link form). The `utm_source`, `utm_medium`, `utm_campaign`,
  `utm_term` and `utm_content` parameters of the URL that was tapped override them one by one:
  if the link's default source is `newsletter`,
  `https://my-app.strybok.link/invite777?utm_source=instagram` arrives with the source
  `instagram` and the link's other defaults. A parameter can replace a default but
  not clear it.
- **Which values are accepted.** 1–64 characters of letters, digits, `.`, `_`, `~` and `-`.
  Anything else (a space, `+`, letters outside ASCII) is dropped as if the parameter were absent,
  without an error: write `spring_sale`, not `spring sale`.
- **They are untrusted labels.** Whoever shares a link can put any `utm_*` values on it. Use them
  for attribution, never to grant anything or to decide what the user may see.
- **What is sent.** Of the tapped URL's query only these five parameters are sent when resolving,
  and the resolved values are reported with the `app_open` event (section "Analytics and
  privacy"); every other parameter and the fragment stay on the device. In the dashboard, a link's analytics has a "Campaigns" breakdown of opens
  by source, medium and campaign.

### Resolving a URL yourself

```swift
func preview(_ url: URL) async {
    do {
        let link = try await strybok.resolve(url)
        print(link.routePath, link.payload["invitationId"]?.stringValue ?? "")
    } catch {
        print(error.localizedDescription)  // `error` is a StrybokError; `error.url` is the link
    }
}
```

`resolve` does not deliver the link to `links()` and does not count as an app open.

### Shutting down

`stop()` ends the instance for good: nothing more is delivered (including a link that was still
resolving), every `links()` stream finishes, and `resolve` and `createLink` throw `.cancelled`. Apps normally
never call it.

## 5. Errors

`resolve(_:)` throws `StrybokError` (typed throws); `onError` receives the same type. These
errors carry the `url` that was being handled. (`url` is optional because errors of `createLink`,
section 6, have none.)

| Case               | Meaning                                                                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `.unsupportedLink` | Not `https`, host not in `allowedHosts`, or not a single-slug path. Thrown before any network call; ignored silently for forwarded URLs. |
| `.linkNotFound`    | Unknown, disabled or expired link (404).                                                                                                 |
| `.timeout`         | No answer in time, after all retries.                                                                                                    |
| `.network`         | The request could not be completed after all retries (for example offline). Carries the underlying error.                                |
| `.server`          | Unexpected status code, or a malformed response (`statusCode` 200).                                                                      |
| `.cancelled`       | `stop()` was called or the calling task was cancelled. Swift-specific; never passed to `onError`.                                        |

A failed link never breaks later links. Inside a closure (for example `Task { … }`) Swift infers
`any Error` in a plain `catch`; write `catch let error as StrybokError` there.

## 6. Create a link to share

A "Share" button can ask Strybok for a short link to the screen the user is looking at:

```swift
let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    clientKey: "pk_…"
))

func shareProduct() async {
    do {
        let link = try await strybok.createLink(
            routePath: "/product/42",
            payload: ["productId": 42],  // optional, like title, description and imageURL
            title: "Red shoes",
            description: "Look at these",
            imageURL: URL(string: "https://cdn.example.com/shoes.png")
        )
        share(link.url)  // also: link.slug, link.routePath, link.linkId
    } catch .rateLimited(let retryAfter) {
        showMessage("Try again in \(Int(retryAfter ?? 60)) s")
    } catch {
        showMessage("Could not create the link: \(error.localizedDescription)")
    }
}
```

Before it works, switch the feature on in the dashboard: open the application, go to **Links
from the app**, enable it and list the **route patterns** the app may create links for (for
example `/product/*`). The dashboard then shows the **publishable key**, which starts with
`pk_`; pass it as `clientKey`. This key is safe to ship in the app because it can only create
links for those patterns. Never put a secret API key (`lb_…`) in an app; `createLink` does not
accept one.

`createLink` runs only when you call it. It is not part of `start()`, needs no `allowedHosts`,
and works before or without `start()`. Asking again with the same content returns the same link,
so the SDK retries timeouts, network errors and 5xx answers with the usual `timeout`,
`maxRetries` and `retryDelay`.

It throws a `StrybokError` whose `url` is `nil`; these errors never go to `onError`:

| Case                                | Meaning                                                                                        | What to do                         |
| ----------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------- |
| `.unauthorized`                     | No `clientKey`, or the key is wrong, was replaced, or the feature is switched off.             | Fix the key or the dashboard.      |
| `.routeNotAllowed(routePath:)`      | The route is not covered by the route patterns.                                                | Add a pattern or change the route. |
| `.validation(message:issues:)`      | The arguments were rejected by the SDK or the server; `issues` is the server's list, if any.   | Fix the arguments.                 |
| `.rateLimited(retryAfter:)`         | Too many requests, or the daily limit of new links is reached. `retryAfter` seconds, if known. | Let the user try again later.      |
| `.network` / `.timeout` / `.server` | No usable answer after all retries.                                                            | Let the user try again later.      |
| `.cancelled`                        | The calling task was cancelled, or `stop()` was called.                                        | Nothing.                           |
| `.attestationRequired`              | The owner only accepts apps that proved they are genuine, and this request carried no proof.   | See "Extra protection" below.      |
| `.attestationFailed(reason:)`       | The proof was refused twice in a row. `reason` is the server's, if any.                        | See "Extra protection" below.      |

Do not put personal data in a route or payload: whoever receives the link can read them. A
custom `StrybokTransport` should fill `StrybokHTTPResponse.headers`, otherwise `retryAfter` is
always `nil`. The full rules are in the [SDK contract](./sdk-contract.md#creating-links).

### Extra protection (App Attest)

The client key is public, so anyone can copy it out of your app. You can ask Strybok to accept
link requests only — or preferably — from a genuine build of your app on a genuine device. On
iOS the proof is Apple's **App Attest**. What this does and does not protect against is
explained in [Keeping link creation from your app safe](./link-creation-security.md); read it
before you switch anything to **Required**.

To enable it:

1. In the dashboard, make sure the application has your **Apple Team ID** and **bundle ID**, then
   open **Setup** → **Links from the app** → **Extra protection (optional)** and choose
   **Preferred** (start here) or **Required**. While you develop, tick **Accept development
   builds (iOS)**; untick it before you rely on the protection.
2. In Xcode, select the app target → **Signing & Capabilities** → **+ Capability** → **App
   Attest**. This adds the `com.apple.developer.devicecheck.appattest-environment` entitlement
   (`development` for builds run from Xcode; TestFlight and App Store builds always use
   `production`).
3. Switch the option on in the SDK. It is off by default:

   ```swift
   let strybok = Strybok(configuration: StrybokConfiguration(
       apiBaseURL: URL(string: "https://api.strybok.com")!,
       allowedHosts: ["my-app.strybok.link"],
       clientKey: "pk_…",
       attestation: true
   ))
   ```

Nothing else changes in your code. The proof is made **only inside `createLink`**, the first time
you call it: never in `start()`, never for incoming links, never in the background. The SDK
creates an App Attest key, has Apple attest it, registers it with Strybok and receives a session
token that it sends with `createLink`. The token is kept in memory (about an hour); the key's
identifier is kept in the Keychain, separately for each client key and API address, so later
launches only sign a fresh challenge. Several `createLink` calls at once share one proof. The
first share after a launch therefore makes two more requests, and the very first one on a device
also contacts Apple.

When the device or build **cannot** produce the proof, the SDK does not fail by itself: it sends
the request without it and reports what the server answers. With **Off** or **Preferred** the
link is created (in **Preferred** from the small shared allowance); with **Required** `createLink`
throws `.attestationRequired`. After a failed attempt the SDK waits a minute before trying to
attest again.

```swift
do {
    let link = try await strybok.createLink(routePath: "/product/42")
    share(link.url)
} catch .attestationRequired {
    showMessage("Sharing is not available on this device")  // expected in the Simulator
} catch {
    showMessage("Could not create the link: \(error.localizedDescription)")
}
```

The limits, plainly:

- **iOS 14 or later, on a real device.** App Attest does not exist on iOS 13 and does **not work
  in the Simulator**; it is also unavailable in most **app extensions** (a share extension, for
  example) and on some Macs running iOS apps. In all these places requests go out without proof.
  With **Required**, `createLink` cannot work there at all.
- **Not verified against Apple's real service or on a device.** This flow is covered by unit
  tests with a fake App Attest and a stub server, and it compiles for iOS. Nobody has run it on a
  physical device yet, so no real attestation has been made with it or accepted by the Strybok
  server. Test on your own device with **Preferred** before you choose **Required**.
- `.attestationRequired` also appears when the owner chose **Required** and `attestation` is not
  switched on in the app, or the build lacks the App Attest capability.
- `.attestationFailed` means the server refused a freshly made token; retrying does not help.
  Check the Team ID, the bundle ID and **Accept development builds** in the dashboard.
- A copied client key is much less useful with this, but it is not a guarantee: see
  [the limits](./link-creation-security.md#the-limits).

With `attestation` on, `createLink` additionally sends the App Attest key identifier, the
attestation or assertion Apple's framework produced, and the server's challenge. The key
identifier is random for each installation; the SDK still reads no device identifier.

## 7. Treat routes as untrusted input

`routePath`, `payload` and `campaign` are data chosen by whoever created or shared the link.
Match the route against routes your app knows before navigating, never execute payload contents,
and treat campaign values as labels only. `payload` is a
`[String: JSONValue]`; read it with `stringValue`, `intValue`, `boolValue`, `arrayValue`,
`objectValue`.

If a link needs a signed-in user, remember the route and open it after login instead of dropping
it.

## 8. Analytics and privacy

After a link is delivered the SDK sends one best-effort `app_open` event
(`POST /v1/public/events`) with a random event id, the link id, the platform (`ios`), the SDK
version and the link's campaign values when it has any — no device identifiers. It never delays navigation and every failure is ignored. Turn it
off with `reportAppOpens: false`.

Only the link's host and slug are sent to `resolve`, plus the five `utm_*` campaign parameters of
the tapped URL when their value passes the character rule
([Campaign values](#campaign-values)). Every other query parameter and the fragment stay on the
device (you still get them in `ResolvedLink.url`).

From 0.4.0 the package ships a privacy manifest (`PrivacyInfo.xcprivacy`, a resource of the
`Strybok` target), so Xcode's privacy report includes the SDK without anything from you. It
declares:

- no tracking and no tracking domains;
- one collected data type, **product interaction**, not linked to the user, not used for
  tracking, purpose analytics — the `app_open` event above (declared even if you switch
  `reportAppOpens` off: a manifest cannot depend on an option);
- one "required reason" API, **`UserDefaults`** with reason `CA92.1` (information only the app
  itself reads and writes) — the counter and the flag of deferred links.

The key names and the reason code were checked against Apple's documentation on 2026-11-25; the
manifest has **not been through an App Store Connect upload**. Your App Store privacy answers
are still yours to give: the manifest describes the SDK, not your app.

With `deferredLinks` on ([section 10](#10-deferred-links-optional)) the SDK additionally sends
the code found in a link the person pasted, with the bundle identifier and the SDK version, and
keeps a counter and a flag in `UserDefaults`. It never reads the clipboard.

**What the manifest does not cover.** With `allowProbabilisticMatching` also on, the SDK sends
the bundle identifier, the device family and the first preferred language, and the service uses
the connection's IP address to recognise the device — the one case in which the sentence "no
device identifiers, no fingerprint" does not hold. That is not declared in the SDK's manifest,
because the option is off by default and declaring it would be false for every app that leaves
it off; no entry would make it acceptable to Apple either, whose rules forbid it. If you switch
it on, your own app's privacy manifest, App Store privacy labels and privacy policy must cover
it (our reading: at least "Device ID"; this is not legal advice). The same goes for
`attestation`: with it on, the service keeps the App Attest key id of the installation, which
you may have to declare as a device-level identifier.

## 9. Testing your integration

The `StrybokTesting` library (same package; add it to your **test** target) provides
`FakeLinkSource` and `StubTransport`, so tests need neither a device nor a network:

```swift
import Strybok
import StrybokTesting
import XCTest

final class DeepLinkTests: XCTestCase {
    func testInviteLinkOpensTheInvitation() async {
        let source = FakeLinkSource(launchURL: URL(string: "https://my-app.strybok.link/abc")!)
        let transport = StubTransport { _ in
            .json(#"{"linkId":"l1","appId":"a1","routePath":"/invite/abc123","payload":{}}"#)
        }
        let strybok = Strybok(configuration: StrybokConfiguration(
            apiBaseURL: URL(string: "https://api.strybok.com")!,
            allowedHosts: ["my-app.strybok.link"],
            reportAppOpens: false,
            linkSource: source,
            transport: transport
        ))

        let launch = await strybok.initialLink()
        XCTAssertEqual(launch?.routePath, "/invite/abc123")

        source.emit(URL(string: "https://my-app.strybok.link/other")!)  // a later tap
        strybok.stop()
    }
}
```

You can also skip `FakeLinkSource` and call `strybok.handle(url)` directly, exactly like the app
does. The SDK's own tests are in its `Tests` directory; run them in the SDK directory (a clone of
`https://github.com/strybok/strybok-ios`):

```sh
swift build
swift test
```

For an end-to-end check on a device follow section 3 of [iOS Universal Links setup](./ios.md).
In the Simulator you can open a link with `xcrun simctl openurl booted https://my-app.strybok.link/abc`
(the association must still be valid for iOS to route it to the app).

## 10. Deferred links (optional)

A person taps a link, does not have the app, installs it from the App Store and opens it. By
default **nothing happens** then: the App Store passes nothing from a link to a newly installed
app, so iOS has no equivalent of Android's install referrer. The SDK offers two opt-in ways to get
the link back. Both are off by default, each must be switched on **twice** — by the owner in the
dashboard and by you in code — and each has a cost. What the service does on its side, and
Apple's own mechanisms that we recommend first (custom product pages, App Clips), are in
[iOS Universal Links setup](./ios.md#links-tapped-before-the-app-is-installed).

> **Nothing in this section has run on a device, against the real pasteboard or against the real
> service.** It is covered by unit tests with fakes and compiles for iOS.

|                    | A. Pasted link                                                | B. Probabilistic matching                                                                  |
| ------------------ | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Dashboard          | **Copy and paste the link**                                   | **Match the first launch to a recent tap**, plus **Allow probabilistic matching** per link |
| Code               | `deferredLinks: true`                                         | `deferredLinks: true, allowProbabilisticMatching: true`                                    |
| The person does    | Taps "Copy link and get the app", later taps Paste in the app | Nothing                                                                                    |
| The link they get  | Exactly the one they copied                                   | A guess; it can be someone else's                                                          |
| Apple's rules      | Uses Apple's paste button as intended                         | **Forbidden** (fingerprinting)                                                             |
| Our recommendation | Fine, if you accept the extra step                            | **Do not use it**                                                                          |

A restored link arrives like any other — through `links()` or your listener, exactly once, queued
until a listener attaches — with `isDeferred == true`. It is never returned by `initialLink()`
(it can arrive seconds after your first screen), no `app_open` event is sent for it, and nothing
about deferred links is ever passed to `onError`: most people who install an app never tapped a
link.

### A. Pasted link

**Enable it.** Dashboard: your application → **Setup** → **iOS: links tapped before the app is
installed** → **Copy and paste the link** (needs the iOS bundle ID). Code:

```swift
let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    deferredLinks: true
))
```

or later, for example after a consent screen: `strybok.enableDeferredLinks()`.

**What happens.** Instead of going straight to the App Store, iOS visitors without the app see a
page with a **Copy link and get the app** button. It copies
`https://my-app.strybok.link/<slug>?strybok_click=dc_…` — the link plus a code that works once,
for 24 hours — and opens the App Store. In your app the person taps a paste button and you hand
what they pasted to the SDK:

```swift
let result = await strybok.redeemPastedLink(pastedText)
```

| Result            | Meaning                                                                                                   | What to do                                         |
| ----------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `.delivered`      | The link is on its way to `links()` / your listener, with `isDeferred`                                    | Nothing; navigate when it arrives                  |
| `.notOurs`        | Not a link of your app with a valid code. **No request was made** and the text was dropped                | Carry on silently — people paste all kinds of text |
| `.notFound`       | The service refused the code: unknown, older than 24 hours, already used, another app's                   | Carry on; hide the paste button                    |
| `.alreadyHandled` | A deferred link was already delivered or refused in this installation; no request                         | Hide the paste button                              |
| `.disabled`       | `deferredLinks` is off                                                                                    | —                                                  |
| `.failed`         | The service could not be reached or was busy (Paste can be tapped again), or its answer could not be used | Let the person try again                           |

**The SDK never reads the clipboard.** It contains no call that returns pasteboard content (a
test scans its sources for that); you pass the string in. Of that string only the code is sent,
together with the bundle identifier and the SDK version. The pasted text itself is not stored,
logged or sent, and a pasted link is delivered even if a normal link was delivered earlier in the
same launch — pasting was the person's own action.

**The paste step.** Use Apple's paste button: tapping it is the person's consent, so no "Allow
Paste" alert appears. It needs iOS 16; on iOS 13–15 use a paste action of your own (the system
then asks the person) or leave the feature out. The SDK ships no UI. Put the button on the first
screen or in onboarding with a sentence that says what it does, for example "Came from a link? Tap
Paste to continue where you left off." **Do not paste automatically**, and describe the step in
your App Review notes.

SwiftUI (iOS 16 or later):

```swift
struct ContinueFromLinkView: View {
    let strybok: Strybok
    @State private var showButton = false

    var body: some View {
        VStack(spacing: 12) {
            if showButton {
                Text("Came from a link? Tap Paste to continue where you left off.")
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task {
                        let result = await strybok.redeemPastedLink(text)
                        if result != .failed { showButton = false }
                    }
                }
            }
        }
        // Optional: show the button only when the clipboard probably holds a web address.
        .task { showButton = await strybok.pasteboardMayContainLink() }
        // The person moved on without pasting (only matters with probabilistic matching).
        .onDisappear { strybok.skipPastedLink() }
    }
}
```

UIKit (iOS 16 or later):

```swift
final class WelcomeViewController: UIViewController {
    var strybok: Strybok!

    override func viewDidLoad() {
        super.viewDidLoad()
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        let pasteControl = UIPasteControl(configuration: UIPasteControl.Configuration())
        pasteControl.target = self  // calls `paste(itemProviders:)` below
        view.addSubview(pasteControl)  // lay it out next to your explanation
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [strybok] object, _ in
            guard let text = object as? String, let strybok else { return }
            Task { _ = await strybok.redeemPastedLink(text) }
        }
    }
}
```

`pasteboardMayContainLink()` is optional. It uses the system's pattern detection
(`UIPasteboard.general.detectedPatterns(for:)` with `\.probableWebURL`, iOS 15 or later; the
equivalent `detectPatterns(for:completionHandler:)` on iOS 14), which Apple documents as working
"without notifying the user": it reads no content and shows no banner. It only answers "probably
a web address" — it cannot know whether the address is yours — and returns `false` when
`deferredLinks` is off, once a deferred link was handled, below iOS 14 and on macOS.

**What it costs:**

- **Every** iOS visitor without the app gets one extra page and one extra tap before the App
  Store, whether or not they would ever paste.
- It only works if the person taps the copy button and later taps Paste in your app — two
  deliberate steps. Nobody publishes how many people complete them; expect a minority.
- It replaces whatever was on their clipboard, and Apple's Universal Clipboard may carry the link
  to their other devices.
- The code works once, for 24 hours. A person who copies something else in between gets nothing.
- You have to build the paste step into your onboarding and describe it in your App Review notes.

### B. Probabilistic matching (not recommended)

> **Apple forbids this.** The App Store Review Guidelines and the Apple Developer Program License
> Agreement do not allow deriving data from a device to identify it (fingerprinting), with or
> without the user's consent. If you enable it, the App Review and legal risk is yours, not
> Strybok's. We advise against it; it exists because some owners want the choice.

**Enable it.** All of these are needed:

1. The server has a matching secret (the dashboard says so if not).
2. Dashboard: **Setup** → **iOS: links tapped before the app is installed** → **Not recommended:
   probabilistic matching** → **Match the first launch to a recent tap**, confirm the warning and
   choose how long a tap is kept (15 minutes, 1 hour or 6 hours).
3. On **each** link that may be matched: **Allow probabilistic matching on iOS for this link**.
   Links your app creates with `createLink` can never be matched.
4. Code — a second, separate option, so it cannot be switched on by accident:

```swift
let strybok = Strybok(configuration: StrybokConfiguration(
    apiBaseURL: URL(string: "https://api.strybok.com")!,
    allowedHosts: ["my-app.strybok.link"],
    deferredLinks: true,
    allowProbabilisticMatching: true
))
```

**What happens.** When an iOS visitor of an allowed link is sent to the App Store, the service
keeps a keyed hash of their IP address, device type and language for the time the owner chose.
Once `start()` has finished — never as part of it, and at most once per launch — the SDK sends
the bundle identifier, the device family (`iphone`, `ipad` or `ipod`), the first preferred
language and the SDK version, **and nothing else**; the service takes the address from the
connection. If exactly one recent tap fits, that link is delivered with `isDeferred` **and**
`isProbabilisticMatch` set. A normal link that arrives first wins and the guess is dropped.

**Check `isProbabilisticMatch` before acting on a link.** A matched link may belong to someone
else. It must never by itself sign anyone in, accept an invitation, apply a personal discount or
show personal content:

```swift
for await link in strybok.links() {
    if link.isProbabilisticMatch {
        router.openPublicScreenOnly(link.routePath)  // a guess: nothing personal
    } else {
        router.open(link.routePath, payload: link.payload)
    }
}
```

**With the paste button.** If both flows are on, the pasted link wins. When the clipboard
probably holds a web address the SDK waits (`deferredLinkStatus == .awaitingPaste`) and matches
only after `redeemPastedLink` answered `.notOurs` or you called `strybok.skipPastedLink()` —
call it when the person leaves the screen with the paste button, otherwise matching never starts
in that launch.

**What it costs — read all of it:**

- **Apple forbids it** (above). The App Review and legal risk is the app owner's.
- **A wrong match shows one person another person's link.** People behind one address — shared
  Wi-Fi, offices, universities, mobile carrier NAT — look the same. If two taps fit, the service
  refuses and nobody gets a link. If only one fits but a different person opens the app first,
  that person gets the link and its payload. This is why it is opt-in per link: never allow
  invitations, links that grant access, or anything personal.
- **It often does not work at all:** not with iCloud Private Relay or a VPN (the browser and the
  app come from different addresses), not when the person changes network between the tap and the
  first launch, not for most iPads (their Safari says it is a Mac), and not after the time window.
- **It changes your privacy obligations.** Strybok processes your visitors' IP addresses for this
  (the address is not stored; the keyed hash is, for the window the owner chose). Your privacy
  policy and your App Store privacy labels must cover it, and you may need consent under
  GDPR/ePrivacy — the SDK supports a consent step by doing nothing until `deferredLinks` is on
  (`enableDeferredLinks()`). This is not legal advice. See
  privacy.
- **Nobody knows how accurate it is.** Figures quoted by other vendors are unsourced. The link
  analytics show how many taps were kept, matched and refused as ambiguous; they cannot show how
  many matches were the wrong person.

### Once per installation, and the status

The SDK keeps two values in `UserDefaults`, per API host and bundle identifier: a counter of
matching attempts and a "done" flag. They are removed when the app is deleted, so a reinstall
starts again. Nothing else is stored — not the pasted text, not the code, nothing from an answer.

- Once either flow delivered a link, or the service gave a definite answer to a pasted code,
  neither flow does anything again in that installation.
- A matching check that could not reach the service is repeated on a later launch, three launches
  at most. The counter is written before the request, so an app that is killed during the check
  has used one attempt; "done" is written before the link is handed to your app, so a crash
  afterwards cannot deliver it twice. A deferred link may be lost; it is never delivered twice.

For development and QA, `strybok.deferredLinkStatus` (or the stream
`strybok.deferredLinkStatuses()`) says where things stand. Do not build app behaviour on it.

| Status            | Meaning                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------- |
| `.disabled`       | `deferredLinks` is off                                                                                            |
| `.checking`       | The matching check of this launch has not finished (it begins after `start()`)                                    |
| `.awaitingPaste`  | Waiting for `redeemPastedLink` or `skipPastedLink()`; also the resting state when only the pasted-link flow is on |
| `.pending`        | This launch could not reach the service; a later launch tries again                                               |
| `.notFirstLaunch` | A deferred link was delivered or refused in an earlier launch                                                     |
| `.unavailable`    | Matching is impossible here: not an iPhone, iPad or iPod touch, or no usable bundle identifier or language        |
| `.notFound`       | The pasted code was refused, or nothing matched (or more than one tap did)                                        |
| `.superseded`     | A normal link of this app arrived first; the guess was dropped                                                    |
| `.delivered`      | A deferred link was handed to `links()` / your listener                                                           |
| `.failed`         | Three launches could not finish the check, or the service's answer could not be used                              |
| `.noReferrer`     | Android only; never reported by this SDK                                                                          |

## Troubleshooting

| Symptom                                                     | Check                                                                                                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Link opens Safari or the App Store instead of the app       | The association is not active: see [iOS Universal Links setup](./ios.md). The SDK is not involved yet at this point.                                   |
| App opens but nothing happens                               | Is the delegate method forwarding to `handle`? Does `handle` return `true` (host in `allowedHosts`)? Was `start()` called? What does `onError` say?    |
| Works when running, not on cold start                       | With scenes the launch link arrives only in `scene(_:willConnectTo:options:)`; call `handle(connectionOptions:)` there.                                |
| Cold-start link is lost                                     | A `links()` stream was created but never iterated, or `initialLink()` was called and its result ignored.                                               |
| Screen opens twice                                          | You navigate from the SDK **and** from your own Universal Link handling. Let only the SDK's links drive navigation.                                    |
| UI updated from a background thread                         | `addListener` and `onError` callbacks run on arbitrary threads; hop to the main actor, or iterate `links()` from a main-actor task.                    |
| Nothing happens after installing from a link                | Expected by default. The opt-in flows and their limits are in [Deferred links (optional)](#10-deferred-links-optional); `deferredLinkStatus` says why. |
| Works on tap in Notes/Messages, not from Instagram/Telegram | In-app browsers often do not hand links to apps. Users get the fallback page with a manual button.                                                     |
