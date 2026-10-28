# Mac updater preparation — 2026-10-28

Status: source-only update. Implementation, isolated tests and Developer ID / notarized packages are complete. Mac 0.1.13 is not released or installed; current public downloads remain 0.1.12. Archive/feed signing and the real update round trip remain pending. Source publication does not depend on the separate Keychain authorization.

## Scope

Base: private main 542f573 / public main c4e8382: Kordan cleanup + final list layout + credential hardening. No ASR, model, prompt, cleanup policy, provider default, iOS or Android source changes. AppModel only gains a read-only update restart barrier.

Mac target: 0.1.13 (2026102802), Sparkle exact 2.10.0. Menu and Settings > General expose check/update preferences. Default checks and downloads enabled, normal quit installs. Update-requested relaunch waits for recording / processing and background cleanup; the actual termination request repeats the barrier to cover a newly started turn.

## Trust and publishing

- Feed: https://mickyyang-1407.github.io/utuvo-type/appcast.xml
- Keychain account: com.utuvo.type.updates; private signing key stays in Keychain, never exported.
- Public verification key is in App/Info.plist. It is public material.
- Signed feed required without failure expiration; archive verified before extraction; system profiling disabled.
- scripts/build-app.sh embeds/re-signs Sparkle including helper code and includes its complete upstream license. Existing Developer ID profile / Keychain entitlements remain.
- scripts/make-appcast.py reads the notarized release ZIP, verifies the signing account public key, signs archive and XML, verifies both, then writes the feed.
- Publish the exact GitHub release ZIP BEFORE pushing docs/appcast.xml. Never reformat signed XML. Keep CFBundleVersion strictly increasing.
- Existing Mac versions do not contain this updater: they need this installer once.

## Verification available

swift test exit 0 before adding updater tests (App target: 350, four existing skips). AppUpdaterTests: three passed after final source changes: busy deferral/exactly-once restart, new recording during preparation, real isolated AppModel background-cleanup barrier/new-turn refusal. All test contexts have isolated preferences/destination, synthetic text, no microphone or provider requests.

570 tracked Core / Mac cleanup+preferences / runtime / prompt / iOS / Android files match the approved baseline exactly, including symlink targets. No quality or speed improvement is claimed.

Developer ID and notarization outputs, package checks, original checkpoint, source scan and installation proof remain in the local task evidence directory. Follow the workspace handoff for the current completion state.

## Outstanding delivery gates

The first sign_update call waited for a macOS Keychain authorization prompt. Micky could not operate the Mac, so the owned signer and runner were stopped. No Keychain permission was changed. Source commits can be pushed independently; do not publish an unsigned feed or claim a working update round trip. Start a fresh signing invocation when the human can complete the system prompt; no password in chat.

Then verify good/tampered archive and feed; publish signed release/assets then signed feed; verify public bytes/signatures; perform a real update from a local signed/notarized bridge build 2026102801 to public build 2026102802. The bridge is local only and must not be released. Preserve installed settings and a recoverable old App backup.

Original private feature checkout and pre-existing dirty worktrees are out of scope; never reset or merge them. Public sync uses only the reviewed changed files because histories are independent.

## Controlled public export

Product code, packaging, tests and this handoff are identical in the two repositories. README retains each repository's existing introduction; only the same updater availability paragraph is added. The public download links, feature summary and Discussions link are preserved. No Android/iOS source, model configuration or cleanup setting changes are included.
