#!/bin/zsh
# 在接上的裝置／模擬器上跑全部 instrumentation 測試。
#
# 為什麼不直接 ./gradlew connectedDebugAndroidTest：鍵盤 UI 測試需要 UTUVO Type 是「已啟用」的輸入法，
# 而從測試程序裡 `ime enable` 對停用中的輸入法一律回 unrecognized IME ID（2026-09-29 模擬器實測；
# 電腦端 adb 下同一句就成功，重裝 APK 也會保留啟用狀態）。所以先裝 APK、從電腦端啟用，再跑測試。
#
# 用法：ANDROID_SERIAL=emulator-5554 android/scripts/run-device-tests.sh [gradle 參數…]
#   例：… run-device-tests.sh -Pandroid.testInstrumentationRunnerArguments.class=com.utuvo.type.PredictionUiParityTest
set -euo pipefail
cd "${0:A:h}/.."
: "${JAVA_HOME:=$HOME/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home}"
export JAVA_HOME
adb=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
ime=com.utuvo.type/.UTUVOImeService

./gradlew :app:installDebug --console=plain -q
"$adb" shell ime enable "$ime"
"$adb" shell ime set "$ime"
# 無視窗模擬器會自己轉橫；測試是以直向寫的。
"$adb" shell settings put system accelerometer_rotation 0
"$adb" shell settings put system user_rotation 0
rm -rf app/build/outputs/androidTest-results
./gradlew :app:connectedDebugAndroidTest -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true --console=plain "$@"
