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
# SwiftPM Bundle.module resolves this sibling resource bundle in the packaged app.
cp -R "$BIN_DIR/UTUVOType_UTUVOTypeApp.bundle" "$APP/Contents/Resources/UTUVOType_UTUVOTypeApp.bundle"
cp "$REPO_ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# 內建引擎腳本：DMG／App 版沒有 repo，安裝卡跑的是這份；venv 與模型落在
# ~/Library/Application Support/UTUVO Type/engine（見 RuntimeBootstrap.engineHome）。
ENGINE="$APP/Contents/Resources/engine"
mkdir -p "$ENGINE/scripts" "$ENGINE/runtime"
cp "$REPO_ROOT/scripts/bootstrap-runtime.sh" "$ENGINE/scripts/bootstrap-runtime.sh"
cp "$REPO_ROOT/runtime/requirements.txt" "$REPO_ROOT/runtime/utuvo-type-asr" \
   "$REPO_ROOT/runtime/utuvo-type-asr.py" "$REPO_ROOT/runtime/utuvo-type-asr-server.py" \
   "$REPO_ROOT/runtime/utuvo-type-editor.py" "$ENGINE/runtime/"
chmod +x "$ENGINE/scripts/bootstrap-runtime.sh" "$ENGINE/runtime/utuvo-type-asr" "$ENGINE/runtime/"*.py
# 內建 Python（2026-09-24 Micky 核准）：沒有 Python 3.10+ 的 Mac 原本要從 GitHub 下載 25 MB，
# 實測兩次各約 2.5 與 10 分鐘（苑涵截圖就卡在這）。改成把官方 install_only 壓縮檔原封不動放進 App，
# 安裝時驗 SHA-256 後解壓——內容與原本從 GitHub 下載的一模一樣。版本固定，換版要一起改這三行。
PY_TARBALL="cpython-3.12.14-20260901-aarch64-apple-darwin-install_only.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only.tar.gz"
PY_SHA256="3ee3ee547cedfeb7c2b16b2b7156039f7b470bb8f857e226fd3d2eb11db83c76"
PY_CACHE="${UTUVO_TYPE_BUILD_CACHE:-$HOME/Library/Caches/UTUVOTypeBuild}"
mkdir -p "$PY_CACHE" "$ENGINE/python"
if [ "$(shasum -a 256 "$PY_CACHE/$PY_TARBALL" 2>/dev/null | cut -d' ' -f1)" != "$PY_SHA256" ]; then
  echo "[build-app] fetching bundled Python: $PY_TARBALL"
  curl -fL --retry 3 --max-time 3600 "$PY_URL" -o "$PY_CACHE/$PY_TARBALL.part"
  mv "$PY_CACHE/$PY_TARBALL.part" "$PY_CACHE/$PY_TARBALL"
fi
[ "$(shasum -a 256 "$PY_CACHE/$PY_TARBALL" | cut -d' ' -f1)" = "$PY_SHA256" ] \
  || { echo "[build-app] ERROR: bundled Python checksum mismatch" >&2; exit 1; }
cp "$PY_CACHE/$PY_TARBALL" "$ENGINE/python/$PY_TARBALL"
printf '%s  %s\n' "$PY_SHA256" "$PY_TARBALL" > "$ENGINE/python/SHA256"
cp "$REPO_ROOT/prompts/formatter-v1.txt" "$APP/Contents/Resources/formatter-v1.txt"
# App icon：iOS／macOS 共用的 Icon Composer 正本（scripts/make-icon.py）。actool 同時產出
# macOS 26+ 的 Liquid Glass（Assets.car，CFBundleIconName）與舊版 macOS 的 AppIcon.icns（CFBundleIconFile）。
ICON_TMP="$(mktemp -d)"
xcrun actool "$REPO_ROOT/assets/branding/AppIcon.icon" --compile "$ICON_TMP" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_TMP/partial.plist" --output-format human-readable-text >/dev/null
test -s "$ICON_TMP/Assets.car" && test -s "$ICON_TMP/AppIcon.icns"
cp "$ICON_TMP/Assets.car" "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_TMP"
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
  # iCloud 字典同步的 entitlement 只有在 app 裡有 Developer ID 描述檔時系統才放行
  # （沒有的話整支 app 會被擋下來，不是只少一個功能）。描述檔不進 repo：
  #   ~/Library/MobileDevice/Provisioning Profiles/UTUVO_Type_Developer_ID.provisionprofile
  # 沒有描述檔的機器照樣建得出可用的 app，只是沒有 iCloud 同步（匯出／匯入不受影響）。
  PROFILE="${UTUVO_TYPE_PROFILE:-$HOME/Library/MobileDevice/Provisioning Profiles/UTUVO_Type_Developer_ID.provisionprofile}"
  ENTITLEMENTS="$REPO_ROOT/App/UTUVOType-no-icloud.entitlements"
  rm -f "$APP/Contents/embedded.provisionprofile"
  if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="$REPO_ROOT/App/UTUVOType.entitlements"
    echo "[build-app] embedded provisioning profile: ${PROFILE}（iCloud 字典同步 on）"
  else
    echo "[build-app] WARNING: 找不到 Developer ID 描述檔，這次建置沒有 iCloud 字典同步（匯出／匯入仍可用）" >&2
  fi
  # 內建 Python 壓縮檔裡的 11 個 Mach-O（python3.12＋dylib）：公證會掃進 tar.gz 裡，未簽章＝整包 Invalid
  # （2026-09-24 實測 notary log：not signed with Developer ID／no secure timestamp／no hardened runtime）。
  # 解開 → 簽（python3.12 加 hardened runtime＋disable-library-validation，才載得了 pip 裝的 .so）→ 重壓，SHA-256 當場重算。
  PY_WORK="$(mktemp -d)"
  tar -xzf "$ENGINE/python/$PY_TARBALL" -C "$PY_WORK"
  while IFS= read -r macho; do
    if [ "$macho" = "$PY_WORK/python/bin/python3.12" ]; then
      codesign --force --timestamp --options runtime \
        --entitlements "$REPO_ROOT/App/python-runtime.entitlements" --sign "$SIGN_IDENTITY" "$macho"
    else
      codesign --force --timestamp --sign "$SIGN_IDENTITY" "$macho"
    fi
  done < <(find "$PY_WORK/python" -type f -exec file {} + | awk -F: '/Mach-O/{print $1}')
  (cd "$PY_WORK" && COPYFILE_DISABLE=1 tar -czf "$ENGINE/python/$PY_TARBALL" python)
  printf '%s  %s\n' "$(shasum -a 256 "$ENGINE/python/$PY_TARBALL" | cut -d' ' -f1)" "$PY_TARBALL" > "$ENGINE/python/SHA256"
  rm -rf "$PY_WORK"
  echo "[build-app] bundled Python re-signed with: $SIGN_IDENTITY"
  # --options runtime：hardened runtime 是 notarization 的硬性前提；
  # entitlements 宣告麥克風與（有描述檔時）iCloud 鍵值儲存，TCC 授權仍由系統把關。
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
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
  note "送 notarytool 審核（profile: ${NOTARY_PROFILE}），通常需數分鐘…"
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
