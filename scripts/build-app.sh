#!/usr/bin/env bash
# Build a launchable UTUVO Type.app without touching any other product.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build -c release --product utuvo-type
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$REPO_ROOT/dist/UTUVO Type.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/utuvo-type" "$APP/Contents/MacOS/utuvo-type"
cp "$REPO_ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# 內建引擎腳本：DMG／App 版沒有 repo，安裝卡跑的是這份；venv 與模型落在
# ~/Library/Application Support/UTUVO Type/engine（見 RuntimeBootstrap.engineHome）。
ENGINE="$APP/Contents/Resources/engine"
mkdir -p "$ENGINE/scripts" "$ENGINE/runtime"
cp "$REPO_ROOT/scripts/bootstrap-runtime.sh" "$ENGINE/scripts/bootstrap-runtime.sh"
cp "$REPO_ROOT/runtime/requirements.txt" "$REPO_ROOT/runtime/utuvo-type-asr" \
   "$REPO_ROOT/runtime/utuvo-type-asr.py" "$REPO_ROOT/runtime/utuvo-type-editor.py" "$ENGINE/runtime/"
chmod +x "$ENGINE/scripts/bootstrap-runtime.sh" "$ENGINE/runtime/utuvo-type-asr" "$ENGINE/runtime/"*.py
cp "$REPO_ROOT/prompts/formatter-v1.txt" "$APP/Contents/Resources/formatter-v1.txt"
cp "$REPO_ROOT/assets/branding/UTUVOType.icns" "$APP/Contents/Resources/UTUVOType.icns"
cp "$REPO_ROOT/assets/branding/utuvo-type-logo.png" "$APP/Contents/Resources/utuvo-type-logo.png"
chmod +x "$APP/Contents/MacOS/utuvo-type"

# Developer ID 簽名讓 code identity 跨 rebuild 穩定，TCC（麥克風／輔助使用）
# 授權才不會每次重裝就失效。adhoc linker-signed 每個 build 的 cdhash 都不同。
# 覆寫：UTUVO_TYPE_SIGN_IDENTITY=<identity>；明確要 adhoc：UTUVO_TYPE_ALLOW_ADHOC=1。
IDENTITIES="$(security find-identity -v -p codesigning || true)"
# 不用 `printf | awk '/.../{...; exit}'`：awk 早退會讓 printf 收 SIGPIPE，
# pipefail 下偶發炸掉整個 build。改成讀進變數後純字串匹配（無 pipe）。
SIGN_IDENTITY="${UTUVO_TYPE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  while IFS= read -r identity_line; do
    case "$identity_line" in
      *'"Developer ID Application: '*)
        SIGN_IDENTITY="${identity_line#*\"}"
        SIGN_IDENTITY="${SIGN_IDENTITY%%\"*}"
        break
        ;;
    esac
  done <<< "$IDENTITIES"
fi
if [ -n "$SIGN_IDENTITY" ] && [[ "$IDENTITIES" == *"$SIGN_IDENTITY"* ]]; then
  xattr -cr "$APP"
  # --options runtime：hardened runtime 是 notarization 的硬性前提；
  # entitlements 只宣告麥克風意圖，TCC 授權仍由系統把關。
  codesign --force --options runtime \
    --entitlements "$REPO_ROOT/App/UTUVOType.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict "$APP"
  echo "[build-app] signed (hardened runtime) with: $SIGN_IDENTITY"
elif [ "${UTUVO_TYPE_ALLOW_ADHOC:-0}" = "1" ]; then
  echo "[build-app] WARNING: adhoc build by request; TCC grants will not survive rebuilds" >&2
else
  echo "[build-app] ERROR: no Developer ID Application identity in keychain." >&2
  echo "[build-app] Set UTUVO_TYPE_SIGN_IDENTITY=<identity> or UTUVO_TYPE_ALLOW_ADHOC=1 to build unsigned." >&2
  exit 1
fi

# Notarization（opt-in）：需要先在 keychain 存好 notarytool profile——
#   xcrun notarytool profile 預設 "UTUVO Notary"（已存在 keychain，與 utuvo-qc 等姐妹產品共用）
# 用法：UTUVO_TYPE_NOTARIZE=1 ./scripts/build-app.sh
if [ "${UTUVO_TYPE_NOTARIZE:-0}" = "1" ]; then
  NOTARY_PROFILE="${UTUVO_TYPE_NOTARY_PROFILE:-UTUVO Notary}"
  ZIP="$REPO_ROOT/dist/UTUVOType-notarize.zip"
  note() { printf '[build-app] %s\n' "$1"; }
  # 只有用 Developer ID 簽的 app 才可能過 notarization；adhoc／unsigned 就別白送審。
  SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
  # 同上不管道：純字串匹配，免 grep -q 早退的 SIGPIPE 風險。
  if [[ "$SIGN_INFO" != *"Authority=Developer ID Application"* ]]; then
    echo "[build-app] ERROR: 目前不是 Developer ID 簽名，notarization 一定被拒；請用 Developer ID 重簽再送。" >&2
    exit 1
  fi
  ditto -c -k --keepParent "$APP" "$ZIP"
  note "送 notarytool 審核（profile: $NOTARY_PROFILE），通常需數分鐘…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    || { echo "[build-app] ERROR: notarytool submit 失敗；log ID 請用 xcrun notarytool log <id> 查。" >&2; exit 1; }
  xcrun stapler staple "$APP" || { echo "[build-app] ERROR: stapler staple 失敗。" >&2; exit 1; }
  spctl -a -vv -t exec "$APP" || {
    echo "[build-app] WARNING: spctl gate check 未通過（app 可能仍無法直接開啟）；請檢查 staple 狀態。" >&2
  }
  note "notarization 完成：$APP 已 staple。"
  rm -f "$ZIP"
fi

echo "[build-app] $APP"
