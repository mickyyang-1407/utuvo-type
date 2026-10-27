# List presentation only on Kordan baseline

2026-10-27. Micky asked to restore only the prior list feature while keeping everything else on the accepted Kordan baseline.

Versions: iOS0.3.3(43) internal TestFlight build, Mac0.1.12(2026102702), Android0.3.5(versionCode11). Mac and Android GitHub releases are public; the internal iOS build follows the same source and its actual availability must be checked in TestFlight. No App Store or Play review submission.

Only deterministic list layout is added after existing candidate checks. Explicit complete1…N markers support Arabic labels and mixed 第一個／二、三、 forms. No item spelling is guessed: the reported 普價／總普 remain as provided unless the existing Kordan cleanup changes them. Values, negation and emphasis remain. Existing paragraph policy is unchanged; only rendered complete lists get an iOS newline exception in ordinary text fields, respecting autoList and single-line/search/URL field rules.

The Mac SmartCleanup.swift and both Core CleanupFidelity files are unchanged. iOS SmartCleanup outside finalize is byte-identical; Android SmartCleanup outside its3-line presentation helper is byte-identical. Mac/Android keep unformatted validation inputs, model requests receive the original transcript. Models, prompts, provider choices, timeouts, concurrency, ASR, transcript refresh and performance features remain at the rollback baseline. Previously audited credential protections stay in place.

Tests: SwiftCore/Mac134 (133 initial +1 new exact-recording case), iOS81, Android703, all zero failures.25 shared layout fixtures include exact recording text, values/negation/emphasis, decimals/versions, non-lists and idempotence. Actual model requests are mocked; no user audio or live cloud generation. Android signed R8 APK starts in an owned API36 AVD; packaged backup rules/same release signer verified. Mac App/DMG notarization, staple, Gatekeeper and ZIP/DMG contents verified. Real phone/host formatting and new subjective quality or latency are not asserted.

Mac release: https://github.com/mickyyang-1407/utuvo-type/releases/tag/v0.1.12
Android APK: https://github.com/mickyyang-1407/utuvo-type/releases/tag/android-v0.3.5
Source tag for iOS: ios-testflight-0.3.3-43-list. Release tags point to tested code plus exact scanner metadata only; later main commits may update documentation.

One existing Xcode object ID was flagged as IBAN after the build-number change. Full project parity was proven after reversing only42→43. The first allowance mistakenly used Git SHA1; it was removed and replaced with the required exact fileSHA256. Both main pushes then passed the original scanner with PII enabled. No hook or scanning rule was relaxed; product code was unchanged after packaging.

Known original semantic issues remain because the gates are deliberately unchanged. The previous Kordan-era source/release tags remain available. Start future work from the newmain; keep old performance/integration branches isolated so they do not reintroduce the changes Micky rejected. Existing collaboration branch and dirty worktrees are preserved.
