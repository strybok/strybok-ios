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
