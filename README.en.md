# UTUVO Type

![UTUVO Type — Liquid Glass popover beside the brand mark](docs/assets/hero-readme.png)


> Fully-local, deterministic-first voice input for macOS, living in the menu bar.
> Cloud is used only if you explicitly pick a cloud provider and
> supply your own credentials.

🇬🇧 English (this file)｜[中文](README.md)

License: [MIT](LICENSE). The "UTUVO Type" name and logo are not covered by the
MIT license — please keep attribution.

## System requirements

| | Minimum | Recommended |
|---|---|---|
| Chip | **Apple silicon** (M1 or later) — the local engine runs on MLX | Intel Macs can only use cloud or built-in speech |
| macOS | 14 Sonoma | 26 or later for the Liquid Glass UI |
| Memory | **8 GB**: Fast Dictate (Qwen3-ASR 0.6B, ~1 GB resident) | **16 GB**: local editor for Smart/Edit (Qwen3-4B 4-bit, ~3 GB); a local 27B for Deep needs **48 GB+**, otherwise use cloud |
| Disk | 1.5 GB (ASR model + venv) | +3 GB local editor; +30 GB if you want the 27B |
| Other | Python 3.10+ (`xcode-select --install` or `brew install python@3.12`) | Network for the one-time engine install |

On first launch the app checks your hardware and suggests a path (Apple silicon with 8 GB+ = fully local; less memory = Fast only; Intel = cloud). One click to apply, changeable any time.

## Install from the DMG (no clone needed)

1. Download `UTUVO-Type-<version>-macOS-arm64.dmg` from [Releases](https://github.com/mickyyang-1407/utuvo-type/releases/latest) (Developer ID signed, notarized by Apple).
2. Drag it to Applications, launch, click the UTUVO Type menu bar icon → Settings → General → **Install Local Engine**.
   The model is **not inside the DMG**: the button creates a Python venv and downloads Qwen3-ASR 0.6B (~1.2 GB, one time, resumable)
   into `~/Library/Application Support/UTUVO Type/engine/`. Cloud mode works before that.
3. Grant Microphone and Accessibility when asked, then press ⌥Space to dictate.

## Install from source (three steps)

```bash
git clone <repo-url> && cd utuvo-type
./scripts/bootstrap-runtime.sh   # creates a Python venv, installs deps, downloads the ASR model (~1.2 GB, one time)
./scripts/build-app.sh           # builds and signs dist/UTUVO Type.app
open "dist/UTUVO Type.app"
```

> Signing: `build-app.sh` signs with a **Developer ID Application** certificate by
> default (so TCC grants survive rebuilds). No Apple developer cert? Build anyway
> with `UTUVO_TYPE_ALLOW_ADHOC=1 ./scripts/build-app.sh` — adhoc builds must be
> re-granted microphone/accessibility permission after each rebuild.

`bootstrap-runtime.sh` is idempotent: it checks each step before acting,
resumes interrupted model downloads, and prints a next-step command on every
failure. It never downloads anything without you running it.

## First run

1. Click the orange UTUVO Type icon in the menu bar. On first use the app asks
   for **Microphone** and **Accessibility** permission and opens the matching
   System Settings pane:
   - Microphone — needed only while recording; audio stays on this machine in
     fully-local mode.
   - Accessibility — needed to read selected text and paste results back at
     the cursor. The app never captures the screen.
   Each native prompt is attempted once; missing permissions stay visible as a
   card with a button to reopen the right pane.
2. Open Settings → General to set your transcribe shortcut / push-to-talk key,
   language, microphone and audio options.
3. Hold modifiers with your shortcut for instant translation slots, or record
   a new hotkey by clicking its field and pressing any key.

## Fully-local mode (default)

The default install is local-only: no account, no API key, no paid requests.

- ASR: `mlx-community/Qwen3-ASR-0.6B-6bit`, served by `runtime/utuvo-type-asr`
  from `.models/` (gitignored).
- Text cleanup: a deterministic normalizer handles punctuation, fillers,
  numbers/dates and dictionary terms without any model; Smart/Edit modes use a
  local Qwen3-4B editor only when needed.
- No network required after setup.

## Optional cloud

Cloud formatting/transcription is an explicit opt-in adapter (Alibaba
Bailian/DashScope). Keys are read only from the macOS Keychain or
`UTUVO_TYPE_BAILIAN_API_KEY`/`DASHSCOPE_API_KEY`, and are never shown in UI,
logs, fixtures or git.

## Privacy & security notes

- In fully-local mode, audio never leaves the machine and there is no
  telemetry. See `PRIVACY.md` and `docs/SETUP.md`.
- The CLI relay (`utuvo-type-cli --toggle-transcription` etc.) uses
  `DistributedNotificationCenter`, so any local process can trigger its
  allow-listed commands. This matches the threat model of similar tools' CLIs: a local
  attacker already has code execution, and recording is always announced by an
  overlay plus a sound cue. No further hardening is planned; disclosed here.

## Development

```bash
./scripts/verify-scaffold.sh    # fixtures, secret hygiene, swift build/test
./scripts/run-benchmark.sh      # 30-case deterministic benchmark
swift test                      # core unit tests
```

Layout: `Sources/UTUVOTypeCore` (pure core), `Sources/UTUVOTypeApp`
(AppKit/SwiftUI menu bar app), `Sources/UTUVOBench` (benchmark runner),
`Tests/UTUVOTypeCoreTests`. See `ARCHITECTURE.md` and `docs/SETUP.md`.

## License

[MIT](LICENSE). The UTUVO Type name, logo and branding are excluded; keep
attribution when redistributing.

## Acknowledgements

The settings layout takes cues from the open-source [Handy](https://github.com/cjpais/Handy). Local ASR uses the MLX build of [Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-6bit).
