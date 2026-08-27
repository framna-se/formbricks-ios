# SJ fork of the Formbricks iOS SDK

This is SJ's (Framna) fork of [`formbricks/ios`](https://github.com/formbricks/ios), maintained so
the SJ app can drive the survey from Travel Mode: observe the survey lifecycle, ask whether a
survey exists before offering it, and attach per-journey context to the response. The SDK's
upstream public API is unchanged; everything here is additive.

- **Upstream base:** tag `2.1.0`.
- **Working branch:** `sj/hardening`.
- **Consumed by:** the SJ iOS app as a Swift Package dependency, pinned to a tag (e.g. `2.1.0-sj.1`).

The fork began as a set of WebView security fixes against `2.0.0`. Upstream `2.1.0` (PR #51) took
all of those, so they are no longer carried here — see *Security deltas* below for the one that
remains.

## Security deltas vs upstream `2.1.0`

1. **`https`-only external links — `WebView/SurveyWebView.swift` (`JsMessageHandler`).**
   Upstream's `isAllowedExternalURL` allows both `http` and `https` for links opened from survey
   content. The fork allows `https` only, so a tap in a survey can't hand the traveller to an
   unencrypted destination. Both callers go through that one predicate — the JS bridge
   (`onOpenExternalURL`) and the navigation delegate — so the narrowing covers both.

Upstream `2.1.0` carries the rest of what this fork used to patch: default TLS chain validation,
`isInspectable` gated behind `#if DEBUG`, an external-URL scheme allowlist, and a base64-encoded
WebView payload (no more JS template-literal injection). Don't re-add them.

## Updating from upstream

`main` mirrors upstream exactly; every SJ change is a commit on `sj/hardening` on top of the
upstream release tag. Fetch upstream, rebase, re-run the iOS build, and cut a new
`<upstream>-sj.N` tag:

```
git remote add upstream https://github.com/formbricks/ios.git   # once
git fetch upstream --tags
git rebase --onto <new-upstream-tag> <old-upstream-tag> sj/hardening
xcodebuild -scheme FormbricksSDK -destination 'generic/platform=iOS Simulator' build
git tag <new-upstream-tag>-sj.1 && git push origin sj/hardening --tags --force-with-lease
```

The branch is rebased, so the push rewrites history — the previous state stays reachable through
its `<upstream>-sj.N` tag, which is what the app is pinned to anyway. Nothing in the repo records
the version: the tag *is* the version (the podspec keeps upstream's number).

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

## Awaitable attribute sync (SJ addition)

`Formbricks.syncAttributes(_:completion:)` — sets user attributes and syncs them to the server
immediately, bypassing the 0.5 s debounced update queue. The completion fires after the server has
re-evaluated segment membership and the SDK has re-filtered surveys (or with `false` on
not-initialized / no userId / request failure), so `track()`/`hasEligibleSurvey` called from the
completion see fresh targeting state — the stock fire-and-forget `setAttribute` API gives no way to
know when that happens. Resolves the identity via the persisted userId or the one still queued for
first sync (`UserManager.pendingOrCurrentUserId`), so it works right after `setup` with a
config-provided userId. Requires an identified user. Not present upstream.

Interacts with upstream `2.1.0`'s interaction-based segment refresh: `syncUser`'s completion calls
`UpdateQueue.syncDidFinish()`, so a `syncAttributes` landing while a queue-driven sync is airborne
clears that sync's in-flight flag early. Upstream's own direct `syncUser` callers (the expiry timer,
`syncUserStateIfNeeded`) have the same shape, so this is upstream behaviour rather than a fork
regression — worth knowing if the two paths ever need to be serialised.

## Eligibility query (SJ addition)

`Formbricks.hasEligibleSurvey(forAction:) -> Bool` — reports whether a survey would show for a code
action, WITHOUT presenting it (mirrors `track()`'s matching, ignores the display-percentage dice).
Lets the host offer an opt-in prompt only when a survey actually exists. Requires the workspace to be
loaded. Not present upstream.
