# SJ fork of the Formbricks iOS SDK

This is SJ's (Framna) fork of [`formbricks/ios`](https://github.com/formbricks/ios), maintained so
the SJ app can embed the Formbricks survey WebView with the worst client-side security issues
fixed. The SDK's public API is unchanged from upstream.

- **Upstream base:** tag `2.0.0`.
- **Working branch:** `sj/hardening`.
- **Consumed by:** the SJ iOS app as a Swift Package dependency, pinned to a tag (e.g. `2.0.0-sj.1`).

## Deltas vs upstream `2.0.0`

All changes are in `Sources/FormbricksSDK/WebView/`.

1. **TLS certificate-validation bypass (critical) — `SurveyWebView.swift`.**
   The `WKNavigationDelegate` auth-challenge handler accepted any server trust
   (`URLCredential(trust:)` for any cert), disabling TLS validation and allowing MITM. Replaced with
   `completionHandler(.performDefaultHandling, nil)` so the system validates the chain.

2. **Remote WebView inspection in release builds — `SurveyWebView.swift`.**
   `webView.isInspectable = true` was set unconditionally (iOS 16.4+), exposing the survey's JS
   context and content to Safari Web Inspector in production. Now gated behind `#if DEBUG`.

3. **Unvalidated external-URL open — `SurveyWebView.swift` (`JsMessageHandler`).**
   `onOpenExternalURL` passed any JS-supplied string to `UIApplication.shared.open`. Now restricted
   to `http`/`https` schemes; other schemes are blocked and logged.

4. **HTML/JS template-literal injection — `FormbricksViewModel.swift`.**
   Survey JSON was interpolated into a JS backtick template literal, so survey-authored content
   containing a backtick, `${…}`, or `</script>` could break out and execute. The payload is now
   base64-encoded UTF-8 JSON in Swift (`WebViewData.getBase64EncodedJson`) and decoded in JS via
   `atob` + `TextDecoder` before `JSON.parse`.

## Updating from upstream

Fetch upstream, rebase `sj/hardening` onto the new release tag, re-run the iOS build, and cut a new
`<upstream>-sj.N` tag:

```
git fetch upstream --tags
git rebase <new-upstream-tag> sj/hardening
xcodebuild -scheme FormbricksSDK -destination 'generic/platform=iOS Simulator' build
git tag <new-upstream-tag>-sj.1 && git push origin sj/hardening --tags
```

Then bump the pinned version in the SJ app's Swift Package dependency.

## Testing helper (SJ addition)

`Formbricks.debugBypassDisplayFilters` (default `false`): when set to `true`, `SurveyManager`
skips all survey filtering (display-type, recontact, segment) and the display-percentage gate, so
any triggered survey shows every time. For engineering-mode/manual testing only — never enable in
production. Not present in upstream.

## Survey lifecycle callback (SJ addition)

`Formbricks.onSurveyEvent: ((FormbricksSurveyEvent) -> Void)?` — set by the host to observe survey
lifecycle. `FormbricksSurveyEvent` is `.displayed(surveyId:)` / `.responded(surveyId:)` /
`.closed(surveyId:)`, forwarded from the WebView JS events in `JsMessageHandler` on the main thread.
Purely additive; the SDK's internal routing is unchanged. Not present upstream.

## Presentation scrim (SJ change)

`PresentSurveyManager` now presents the survey host controller with a dim background
(`UIColor.black.withAlphaComponent(0.4)`) instead of `.clear`, so the overlay reads as a modal
(previously the full-screen transparent host blocked touches with no visible scrim). The WebView
stays clear on top, so `clickOutsideClose` still works.

## Per-trigger hidden fields (SJ addition)

`Formbricks.track(_:hiddenFields:completion:)` — optional `[String: String]` forwarded through
`SurveyManager`/`PresentSurveyManager` into the WebView payload as `hiddenFieldsRecord`, which the
survey renderer seeds into its response data and submits with every response (create and update).
Lets the host attach per-trigger context (e.g. train number, journey date) to responses. Each key
must be declared as a hidden field on the survey in Formbricks, or the backend drops it. Calling
`track` without the parameter is unchanged. Not present upstream.

## Eligibility query (SJ addition)

`Formbricks.hasEligibleSurvey(forAction:) -> Bool` — reports whether a survey would show for a code
action, WITHOUT presenting it (mirrors `track()`'s matching, ignores the display-percentage dice).
Lets the host offer an opt-in prompt only when a survey actually exists. Requires the workspace to be
loaded. Not present upstream.
