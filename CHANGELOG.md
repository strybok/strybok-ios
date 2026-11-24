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
