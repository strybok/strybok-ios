# iOS SDK integration (Swift)

The `Strybok` Swift package takes the Universal Links iOS hands to your app, asks the Strybok API
which in-app route a link stands for, and gives your app each link exactly once. It follows the
[SDK contract](./sdk-contract.md) shared by all Strybok SDKs.

> **Status:** covered by unit tests that run on macOS and on the iOS Simulator. **Not yet verified
> on a physical device** (see the [manual test plan](./manual-test-plan.md)).
>
> Deferred deep linking is **not supported**: a link tapped before the app is installed is not
> restored after installation.

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
      .package(url: "https://github.com/strybok/strybok-ios", from: "0.3.0"),
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

`routePath` and `payload` are data chosen by whoever created the link. Match the route against
routes your app knows before navigating, and never execute payload contents. `payload` is a
`[String: JSONValue]`; read it with `stringValue`, `intValue`, `boolValue`, `arrayValue`,
`objectValue`.

If a link needs a signed-in user, remember the route and open it after login instead of dropping
it.

## 8. Analytics and privacy

After a link is delivered the SDK sends one best-effort `app_open` event
(`POST /v1/public/events`) with a random event id, the link id, the platform (`ios`) and the SDK
version — no device identifiers. It never delays navigation and every failure is ignored. Turn it
off with `reportAppOpens: false`.

Only the link's host and slug are sent to `resolve`; query parameters and fragments stay on the
device (you still get them in `ResolvedLink.url`).

The SDK itself does not read or store any data that needs a privacy manifest entry; the package
ships no `PrivacyInfo.xcprivacy`. Check your own App Store privacy answers for the `app_open`
event.

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

## Troubleshooting

| Symptom                                                     | Check                                                                                                                                               |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Link opens Safari or the App Store instead of the app       | The association is not active: see [iOS Universal Links setup](./ios.md). The SDK is not involved yet at this point.                                |
| App opens but nothing happens                               | Is the delegate method forwarding to `handle`? Does `handle` return `true` (host in `allowedHosts`)? Was `start()` called? What does `onError` say? |
| Works when running, not on cold start                       | With scenes the launch link arrives only in `scene(_:willConnectTo:options:)`; call `handle(connectionOptions:)` there.                             |
| Cold-start link is lost                                     | A `links()` stream was created but never iterated, or `initialLink()` was called and its result ignored.                                            |
| Screen opens twice                                          | You navigate from the SDK **and** from your own Universal Link handling. Let only the SDK's links drive navigation.                                 |
| UI updated from a background thread                         | `addListener` and `onError` callbacks run on arbitrary threads; hop to the main actor, or iterate `links()` from a main-actor task.                 |
| Works on tap in Notes/Messages, not from Instagram/Telegram | In-app browsers often do not hand links to apps. Users get the fallback page with a manual button.                                                  |
