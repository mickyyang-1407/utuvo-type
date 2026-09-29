#!/bin/zsh
# 產出簽好章的 release APK（GitHub Releases 發佈用，不經 Play）。
#
#   android/scripts/build-release-apk.sh <輸出目錄>
#
# 簽章金鑰：~/Library/Application Support/UTUVO Type/Android Signing/upload-key.p12（PKCS12，不在 repo）；
# 密碼只從 macOS Keychain（service com.utuvo.type.android.upload-keystore）讀進環境變數交給 apksigner，
# 不印出、不寫檔。沒有金鑰或 Keychain 項目就直接失敗（開源 clone 的人照樣能 assembleRelease 自己簽）。
set -euo pipefail
cd "${0:A:h}/.."
out=${1:?用法：build-release-apk.sh <輸出目錄>}
: "${JAVA_HOME:=$HOME/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home}"
export JAVA_HOME
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
bt=$sdk/build-tools/36.1.0
ks="$HOME/Library/Application Support/UTUVO Type/Android Signing/upload-key.p12"
[[ -f $ks ]] || { echo "找不到簽章金鑰 $ks" >&2; exit 1; }

version=$(sed -nE 's/^ *versionName = "([^"]+)".*/\1/p' app/build.gradle.kts)
code=$(sed -nE 's/^ *versionCode = ([0-9]+).*/\1/p' app/build.gradle.kts)
[[ -n $version && -n $code ]] || { echo "讀不到 versionName/versionCode" >&2; exit 1; }

./gradlew :app:assembleRelease --console=plain -q
unsigned=app/build/outputs/apk/release/app-release-unsigned.apk
[[ -f $unsigned ]] || { echo "沒有產出 $unsigned" >&2; exit 1; }

mkdir -p "$out"
signed="$out/UTUVO-Type-$version-android.apk"
"$bt/zipalign" -f -p 4 "$unsigned" "$out/.aligned.apk"
UTUVO_KS_PASS=$(security find-generic-password -s com.utuvo.type.android.upload-keystore -w) \
  "$bt/apksigner" sign --v2-signing-enabled true --v3-signing-enabled true --ks "$ks" --ks-type PKCS12 --ks-pass env:UTUVO_KS_PASS \
  --out "$signed" "$out/.aligned.apk"
rm -f "$out/.aligned.apk" "$signed.idsig"
"$bt/apksigner" verify --verbose "$signed" | grep -E "Verified using v[23]|Verifies"
(cd "$out" && shasum -a 256 "${signed:t}" > "${signed:t}.sha256")
echo "版本 $version（versionCode $code）→ $signed"
cat "$signed.sha256"
