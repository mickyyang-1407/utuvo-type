# UTUVO Type — setup and permission contract

UTUVO Type is the visible app name for the independent `utuvo-type` product
line. It is a launchable menu-bar App. On the first menu-bar click it starts a
guided permission flow; benchmark and deterministic paths remain available
without provider credentials.

## macOS permissions

- Microphone: required only while recording. Audio is held in memory and in a
  per-session temporary CAF file for a configured local ASR process. After a
  successful transcription, Type copies that recording into its own History
  directory according to the retention policy; the temporary source file is
  then deleted. The app shows an actionable failure if access is denied.
- Accessibility: required for paste-back and the explicit Edit Selection
  workflow. Read the selected text and, only when enabled, a bounded field
  range through Accessibility APIs; do not capture the screen. Type uses an
  explicit System Settings hand-off rather than repeatedly calling the native
  "control this computer" prompt.
- Input Monitoring: the current Carbon global hotkey path does not request it.
  If a future replacement needs it, permission must be requested explicitly.

On first use, the App requests microphone permission, shows the macOS
Accessibility trust prompt when needed, and opens the relevant System Settings
privacy pane. This onboarding attempt is one-shot: after it has been attempted,
opening the menu bar does not repeatedly call the native trust prompt. If either
permission is still missing, the menu popover keeps a clear permission card with
a button to reopen the correct pane. The App must explain why each permission
is needed and continue in a local-only mode when cloud or context permissions
are absent.

The General settings page covers the audio controls: microphone/input endpoint, input channel,
output endpoint, mute while recording, audio feedback, and transcription
language. Endpoint changes apply to the next recording session.

## No-cost local setup

The installed default is local-only; no Bailian account, API key, or paid API
request is required.

- runtime/utuvo-type-asr uses the downloaded Qwen3-ASR 0.6B 6-bit model.
- runtime/utuvo-type-editor.py uses the downloaded Qwen3 4B 4-bit model.
- Both servers bind to loopback only (127.0.0.1), keep model weights under
  .models/, and are started on demand.
- The first request can be slower while weights load. Later requests reuse the
  warm process.
- Fast Dictate uses ASR plus deterministic normalization only. Smart Dictate
  and Edit Selection may use the small editor; Deep does not use 27B unless a
  user explicitly configures a Deep model.

The app's local adapter fields are prefilled for this product checkout. If the
app is moved to another path, update the two command fields in Settings:

    Qwen3-ASR command: /path/to/utuvo-type/runtime/utuvo-type-asr
    ASR arguments:     {audio}
    小型 editor command: /path/to/utuvo-type/runtime/utuvo-type-editor.py

## Shortcut policy

The shortcut is user-configurable and defaults to `⌥Space` (changed from
`F14` on 2026-08-22 — most laptops and mechanical keyboards do not expose
F13–F19). If `⌥Space` is taken by another app (Gemini / ChatGPT / Raycast /
Alfred and friends), the app automatically tries `⌥\`` as a fallback and
shows a conflict card in the menu bar that names the suspect and offers a
retry. The fallback is not persisted; once the suspect releases the
shortcut, pressing Retry brings back `⌥Space`. The app never edits other apps'
shortcut configuration. A global registration failure is shown as a status
message and menu actions remain available.

`Push to Talk` is an independent toggle. When enabled, pressing and holding the
configured shortcut records and releasing it stops the recording and continues
to paste the result. When disabled, the same shortcut toggles start/stop. The
settings recorder accepts F13/F1–F20, letters, numbers, and modifier keys.
F13–F20 are delivered through Carbon when available and have NSEvent and
CGEvent tap fallbacks. The app does not edit any other app's shortcut configuration.

Separate actions are available for Fast, Smart, Edit Selection, and Deep; the
live overlay shows progress and Escape cancels active capture or formatting.
Voice Activity Detection can finish a non-push-to-talk capture after sustained
silence.

## Settings parity surfaces

The settings window uses a sidebar with General, History, Models,
Advanced, and About, plus Type-specific Quick path, Local runtime, Dictionary,
Shortcuts & thresholds, and Cloud optional pages. History and recordings are
stored under `~/Library/Application Support/UTUVO Type/`, not in any other app's
other UTUVO product directory.

Advanced → Output provides three output controls: paste method,
clipboard handling, and optional auto-submit. Clipboard is the compatible default;
Accessibility direct insertion is available for fields that expose a writable
selected-text AX attribute and automatically falls back to Clipboard when they do
not.

## Secrets and settings

- Bailian credentials belong in macOS Keychain (`com.utuvo.type.bailian` / `api-key`)
  or a repo-external environment variable. Never paste them into chat, logs,
  fixtures, prompts, or Git.
- A future local `routing.json` is user-owned and ignored by Git; only the
  redacted `config/*.example.json` files are tracked here.
- Formatter provider errors preserve raw ASR and immediately paste deterministic
  fallback text; the user must not record again just to recover text. If an
  Edit Selection provider fails, the original selection is left untouched.
