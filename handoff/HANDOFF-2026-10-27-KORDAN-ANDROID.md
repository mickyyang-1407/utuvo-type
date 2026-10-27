# Android Kordan-era rollback — 0.3.4 (versionCode10)

2026-10-27, follow-up to the Mac0.1.11 / iOS TestFlight42 rollback. Micky explicitly asked Android too.

The entire Android tree is restored to the accepted Kordan PR/build36 point (the PR itself was iOS; Android uses its corresponding baseline), with only the previously audited Android credential-safety delta reapplied and version metadata advanced. Reversing that exact security delta yields the original Android tree except versionCode/versionName. Original Claude relaxed candidate checks and background correction delivery are restored; later RequestSnapshot/final-delivery coordinator/common strict gates and inline numbered-list expansion are removed. Model, provider, prompt and preferences are unchanged.

Security retained: CloudLlm error bodies are not logged, key-bearing HTTP connections reject redirects, custom endpoints are validated before persistence, unsafe legacy endpoint removal, and secret.xml/smart.xml are excluded from backup/device transfer. No new security logic or cross-family review verdict is claimed in this rollback.

Validation: Core409 + App291 = 700 JVM tests, zero failures/errors/skips; R8 Release, zipalign and APKv3 signature verified, same signing certificate as0.3.3. aapt2 confirms packaged0.3.4/10, non-debuggable, allowBackup=false and actual data-extraction rules. Fresh owned API36 AVD installed/started the signed release APK without startup crash; no real microphone, key, user data, physical phone or Play upload. Two public assets are checked by HTTP/SHA256. Complete lint has known6 NewApi errors on unchanged files; it was not rerun or fixed in this rollback, Android10/11 not physically validated.

Original semantic risks and punctuation/list behavior are intentionally retained; no new real-user quality or latency measurement is asserted. Mac0.1.11 and iOS42 source/versions remain unchanged. GitHub latest stays Macv0.1.11; Android download links explicitly point to [android-v0.3.4](https://github.com/mickyyang-1407/utuvo-type/releases/tag/android-v0.3.4). Install APK over the existing app with the same signer; do not uninstall first.

Both independent repositories use forward main commits with controlled file export and original pre-push+PII scans. Existing feature branch/dirty worktrees are preserved. Future changes should start from the rollback main, not old performance/integration branches.
