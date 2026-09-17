#!/usr/bin/env bash
# 打包 GitHub Release 用的 DMG＋zip＋SHA256SUMS。
# 前提：dist/UTUVO Type.app 已由 build-app.sh 用 Developer ID 簽好（建議 UTUVO_TYPE_NOTARIZE=1 先公證 app）。
# DMG 也會送公證＋staple（UTUVO_TYPE_NOTARIZE=1 時）；profile 預設 "UTUVO Notary"。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo '本機引擎只支援 Apple Silicon；請在 arm64 上打包。' >&2; exit 1; }

APP="$PWD/dist/UTUVO Type.app"
[[ -d "$APP" ]] || { echo "找不到 $APP，先跑 scripts/build-app.sh" >&2; exit 1; }
codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STEM="UTUVO-Type-$VERSION-macOS-arm64"
OUT="$PWD/release/$VERSION"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/utuvo-type-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# zip（app-only）
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$STEM.zip"

# DMG：app＋Applications 捷徑
mkdir -p "$WORK/content"
ditto "$APP" "$WORK/content/UTUVO Type.app"
ln -s /Applications "$WORK/content/Applications"
hdiutil create -quiet -volname 'UTUVO Type' -srcfolder "$WORK/content" -format UDZO -imagekey zlib-level=9 -ov "$OUT/$STEM.dmg"
SIGN_ID=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -1)
codesign --force --sign "$SIGN_ID" "$OUT/$STEM.dmg"

if [[ "${UTUVO_TYPE_NOTARIZE:-0}" == 1 ]]; then
  PROFILE="${UTUVO_TYPE_NOTARY_PROFILE:-UTUVO Notary}"
  xcrun notarytool submit "$OUT/$STEM.dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$OUT/$STEM.dmg"
  spctl -a -vv -t open --context context:primary-signature "$OUT/$STEM.dmg" || echo '[package] WARNING: spctl 未通過' >&2
fi

( cd "$OUT" && shasum -a 256 "$STEM.dmg" "$STEM.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt )
echo "[package] $OUT"
