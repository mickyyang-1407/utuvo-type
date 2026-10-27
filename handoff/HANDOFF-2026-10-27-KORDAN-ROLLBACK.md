# Kordan cleanup rollback — Mac 0.1.11 / iOS TestFlight42

2026-10-27. Micky explicitly chose the original behavior after day-to-day testing.

Mac 0.1.11 (2026102701) restores the Mac App and shared Core at the accepted Kordan PR/build36 point, except the audited SecretStore protection. Kordan's PR itself was iOS; the Mac source here is the corresponding Mac baseline, not code newly written by Kordan. Claude's original provider-specific candidate checks and background correction flow are restored. Later strict/common gates, inline-list expansion and experimental short-sentence cloud skip are absent. Models, prompts, provider choices and user preferences are unchanged.

The complete iOS and shared Core trees match the verified `ios-testflight-0.3.3-42-kordan` tag. Default main now contains that iOS source, rather than leaving it only in an iOS-only tag. No new iOS upload or App Store submission. Android was unchanged at the initial Mac checkpoint; the subsequent Android0.3.4 rollback is now complete, see [Android handoff](HANDOFF-2026-10-27-KORDAN-ANDROID.md).

Credential protection stays in place: audited macOS SecretStore and its migration tests, hardened signing/profile gates, iOS no-redirect sessions and endpoint validation, clipboard key cleanup, Android credential transport/log/backup protections. Handoff files remain outside Pages docs/.

Validation: Swift Core 622 tests (1 export-only skip), Mac App 347 tests (2 hardware skips, 2 unsigned Keychain-entitlement skips), zero failures. The unchanged SecretStore previously passed its signed production fixture. Developer ID, team/entitlement, App and DMG notarization/staple, Gatekeeper, mounted DMG and extracted ZIP signatures/version are verified. Three public assets are checked against local SHA256. Normal Mac replacement retains old App backup and settings; no microphone or real cloud request is used for validation.

Known original limitations are intentionally retained. The earlier replay showed a relaxed Mac candidate check accepting `不要刪除備份` -> `刪除備份。`; restoring this baseline does not repair that original semantic risk. Original iOS typo/contrast limitations also remain. There is no new real-user quality or speed measurement, and this release does not claim universal correctness.

[Mac download](https://github.com/mickyyang-1407/utuvo-type/releases/tag/v0.1.11). Release tag points to the tested packaging source; later main commits may contain documentation only. Other collaborators' feature branches and dirty worktrees are preserved. Do not merge old performance/strict-gate branches back into this baseline without reviewing the behavior against this rollback decision.
