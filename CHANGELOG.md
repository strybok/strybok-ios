## 0.5.0

- Links without an API call, optional and **off by default**: the new
  `StrybokConfiguration.parameterLinks` (`ParameterLinks(payloadKeys:)`, also an argument of the
  initialiser) delivers path links (`https://<host>/product/42?id=7`) and Firebase long links
  (`https://<host>/?link=…&apn=…&ibi=…`) as well. Take the keys from `parameterLinks.payloadKeys`
  of the integration guide (`GET /v1/apps/:appId/integration`).
- With the option a URL of an allowed host is also ours when its path is a route path (checked
  as received: never decoded or normalised; no `//`, no dot segments, nothing reserved such as
  `/.well-known/…` or `/favicon.ico`), or `/` (also an empty path) with a `link` parameter that
  is an `http(s)` deep link. Resolving then also sends the first value of each configured key
  (1–256 UTF-16 code units without control characters, re-encoded strictly), and for a long link
  the deep link rebuilt from its scheme, host and path with its own values of those keys, plus
  `apn` and `ibi`. Nothing else of the query and never the fragment.
- The delivered link's `routePath` and `payload` are the service's answer, never the tapped URL;
  `app_open` carries the `linkId` the service returned. `isStrybokLink(_:)`, `handle(_:)` and
  `resolve(_:)` follow the option.
- `ParameterLinks(payloadKeys:)` throws the new `StrybokConfigurationError` for more than 20
  keys, a key twice, a key that is not 1–40 characters of `A–Z a–z 0–9 _ . -`, a `utm_…` key, or
  `st`, `sd`, `si`, `strybok_click`. The keys of the integration guide always pass.
- Without the option every resolve request is exactly what 0.4.0 sent. Deferred links keep the
  single-slug rule with or without it: the pasted text of `redeemPastedLink(_:)` and the `url` of
  a redeem or match answer.
- The tests run every case of the shared test vectors of the SDK contract, a byte-identical copy
  declared as a resource of the test target: each lookup through `resolve(_:)` and the automatic
  flow, each configuration through `ParameterLinks(payloadKeys:)`. A few lookups are strings that
  Foundation cannot hold as a `URL` unchanged (a raw `é`, `"`, `|` or `[`, a lone or malformed
  `%`: from iOS 17 and macOS 14 it percent-encodes them, before that it refuses them), so an app
  can never hand them to the SDK; for those the rules are checked on the raw text.
- Not source-breaking: `parameterLinks:` is a new argument with a default.
- **Unit-tested only (macOS and the iOS Simulator), never run on a device** or against the
  production API.

## 0.4.0

- Campaign values. `ResolvedLink.campaign` is a `LinkCampaign` with the optional strings
  `source`, `medium`, `campaign`, `term` and `content` (plus `isEmpty`). It is never optional
  itself and is empty when the link has none. The values are the link's defaults, overridden by
  the `utm_*` parameters of the URL that was tapped; treat them as untrusted labels.
- Resolving now sends the five `utm_*` parameters of the tapped URL (`utm_source`, `utm_medium`,
  `utm_campaign`, `utm_term`, `utm_content`) when their value is 1–64 characters of
  `A-Z a-z 0-9 . _ ~ -`. Every other query parameter and the fragment are still never sent, and
  a URL without such a parameter produces exactly the request of 0.3.0.
- The `app_open` event carries the `campaign` that resolving returned; it is left out when empty.
- Not source-breaking: the new `campaign:` argument of `ResolvedLink.init` has a default.
- Deferred links, optional and **off by default**: restoring a link that was tapped before the app
  was installed. Two flows, each needing the owner's switch in the dashboard as well:
  - **Pasted link** — `StrybokConfiguration.deferredLinks` (also `enableDeferredLinks()` after
    start). The app shows a paste button (`UIPasteControl` / `PasteButton`) and calls
    `redeemPastedLink(_:)`, which answers `.delivered`, `.notOurs`, `.notFound`,
    `.alreadyHandled`, `.disabled` or `.failed`. The SDK never reads the clipboard; only the
    single-use code of the pasted link, the bundle identifier and the SDK version are sent.
    `pasteboardMayContainLink()` uses the system's pattern detection only (iOS 14+).
  - **Probabilistic matching** — additionally `StrybokConfiguration.allowProbabilisticMatching`.
    **Forbidden by Apple's rules (fingerprinting) and not recommended**; a match can be another
    person's link. After `start()` has finished the SDK sends the bundle identifier, the device
    family, the first preferred language and the SDK version, nothing else. `skipPastedLink()`
    lets matching start when the person did not paste.
- `ResolvedLink.isDeferred` and `ResolvedLink.isProbabilisticMatch` (both `false` for links that
  arrive the normal way; new defaulted arguments of `ResolvedLink.init`). Check
  `isProbabilisticMatch` before doing anything personal with a link.
- `deferredLinkStatus` and `deferredLinkStatuses()` (`DeferredLinkStatus`) for development and QA.
  Deferred links are never returned by `initialLink()`, send no `app_open` and report nothing to
  `onError`. State (`attempts`, `done`) is kept in `UserDefaults` per API host and bundle
  identifier, so deleting the app resets it.
- Privacy manifest: the `Strybok` target now ships `PrivacyInfo.xcprivacy` as a resource. It
  declares no tracking, no tracking domains, one collected data type (product interaction, not
  linked, analytics — the `app_open` event) and the `UserDefaults` required-reason API with
  reason `CA92.1`. Probabilistic matching and attestation are deliberately not in it: an app that
  switches either on declares the consequences in its own manifest (see the README). Checked
  against Apple's documentation, not against an App Store Connect upload.
- With both options off the SDK behaves exactly as before: no request, nothing stored.
- **Deferred links have not run on a device, against the real pasteboard or against the real
  service**: covered by unit tests with fakes, and compiled for iOS.

## 0.3.0

- Optional attestation for `createLink`, off by default: `StrybokConfiguration.attestation`
  (also an `attestation:` argument of its initialiser). When it is on, `createLink` proves with
  Apple's App Attest (`DCAppAttestService`, iOS 14+, real devices) that the request comes from a
  genuine build of the app, and sends the resulting session token as `X-Strybok-Attestation`.
  It runs only inside `createLink`, never from `start()` or for incoming links. The token is
  kept in memory, the App Attest key identifier in the Keychain (separately for each client key
  and API address), and concurrent calls share one attestation.
- Where App Attest is unavailable (Simulator, iOS 13, most extensions, any App Attest or
  attestation-endpoint failure) the request is sent without a token and the server's answer is
  reported; the SDK then waits a minute before trying to attest again.
- New `StrybokError` cases, thrown by `createLink` only: `.attestationRequired` (HTTP 401
  `ATTESTATION_REQUIRED`, also when `attestation` is off) and `.attestationFailed(reason:)` (HTTP
  401 `ATTESTATION_INVALID` after one automatic re-attestation and retry). Other 401 answers are
  still `.unauthorized`. **Source-breaking** for an exhaustive `switch` over `StrybokError`.
- **Not verified against Apple's real App Attest service or on a physical device**: covered by
  unit tests with a fake App Attest and a stub server, and compiled for iOS.
- Supported platforms are unchanged (iOS 13, macOS 10.15); on iOS 13 attestation is simply
  unavailable.

## 0.2.0

- `createLink(routePath:payload:title:description:imageURL:)` asks the service for a short link
  to a screen of the app (a "Share" button) and returns a `CreatedLink` (`url`, `slug`,
  `routePath`, `linkId`). It needs the new `clientKey` configuration option: the application's
  publishable key (`pk_…`) from the dashboard, never a secret API key.
- New `StrybokError` cases, thrown by `createLink` only: `.unauthorized`, `.routeNotAllowed`,
  `.rateLimited(retryAfter:)` and `.validation(message:issues:)`.
- `timeout`, `maxRetries` and `retryDelay` apply to `createLink` as well.
- `StrybokHTTPResponse` has `headers` (empty by default) so a transport can pass on
  `Retry-After`; `URLSessionTransport` fills them in.
- **Source-breaking:** errors of `createLink` are not about an incoming link, so
  `StrybokError.url` is now `URL?`, and so is the `url` of `.network`, `.timeout`, `.server` and
  `.cancelled`. It is still always set for errors of `resolve` and `onError`. An exhaustive
  `switch` over `StrybokError` needs the new cases.

## 0.1.0

- Initial version: `Strybok` with `start`, `handle(_:)`, `handle(userActivity:)`,
  `handle(connectionOptions:)`, `links()`, `addListener`, `initialLink`, `resolve`, `stop`;
  host allowlist; duplicate-delivery protection; timeout and retry; typed `StrybokError`;
  best-effort `app_open` events; replaceable `LinkSource` and `StrybokTransport`;
  `StrybokTesting` product with `FakeLinkSource` and `StubTransport`.
