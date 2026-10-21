#!/bin/zsh
# 重建 0c 用的 .ort 模型與精簡版 ONNX Runtime（只含 0c 用到的 op、不含遙測）。
#
# 用法：android/ort/build-ort.sh [model|runtime|all]（預設 all）
#   model   ort/zc-d512-slim-w4.onnx → app/src/main/assets/zc/zc-d512-slim-w4.ort ＋ ort/required_operators.config
#   runtime ORT v1.31.0 原始碼依 required_operators.config 編 arm64 minimal libonnxruntime.so，
#           換進官方 onnxruntime-android-1.31.0.aar（沿用它的 Java 類別與 JNI）→ ort/onnxruntime-android-1.31.0-zc-minimal.aar
#
# 快取（原始碼、Python venv、建置目錄）放 ${ORT_CACHE:-~/Library/Caches/utuvo-type-ort}，第一次要下載約 1 GB。
# 轉 .ort 不是逐位元組可重現（同一份 .onnx 兩次轉出 sha 不同、op 清單相同）；重建後的驗收是
# :core:test 的 ZcRerankTest 與模擬器 ZcRerankOnDeviceTest.onDeviceScoresMatchOracle 對上 Python 標準分數。
# 說明：docs/ANDROID-APK-SIZE-2026-10-13.md §3。
set -euo pipefail

ORT_VERSION=1.31.0
ORT_COMMIT=402979ac1bef89dcd55add41eaa7277c407599eb   # v1.31.0
AAR_URL=https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$ORT_VERSION/onnxruntime-android-$ORT_VERSION.aar
AAR_SHA256=72683787a80d0608a3121b967d8e1239aef48286826661c953211626690540a7
NDK_VERSION=27.2.12479018

here=${0:A:h}
android=${here:h}
cache=${ORT_CACHE:-$HOME/Library/Caches/utuvo-type-ort}
mkdir -p $cache
what=${1:-all}

sdk=${ANDROID_HOME:-$(sed -n 's/^sdk.dir=//p' $android/local.properties 2>/dev/null)}
[[ -n $sdk && -d $sdk ]] || { echo "找不到 Android SDK（設 ANDROID_HOME 或 android/local.properties）" >&2; exit 1; }

venv=$cache/venv-$ORT_VERSION
py=$venv/bin/python
if [[ ! -x $py ]]; then
  python3 -m venv $venv
  $py -m pip install -q "onnxruntime==$ORT_VERSION" "onnx==1.23.2"
fi

build_model() {
  local tmp=$(mktemp -d)
  cp $here/zc-d512-slim-w4.onnx $tmp/
  $py -m onnxruntime.tools.convert_onnx_models_to_ort $tmp --optimization_style Fixed >/dev/null
  cp $tmp/zc-d512-slim-w4.ort $android/app/src/main/assets/zc/zc-d512-slim-w4.ort
  { echo "# Generated from ort/zc-d512-slim-w4.onnx (optimization style Fixed, level all) by ort/build-ort.sh"
    grep -v '^#' $tmp/required_operators.config; } > $here/required_operators.config
  rm -rf $tmp
  echo "模型 → app/src/main/assets/zc/zc-d512-slim-w4.ort"
  shasum -a 256 $android/app/src/main/assets/zc/zc-d512-slim-w4.ort
}

build_runtime() {
  local src=$cache/onnxruntime-$ORT_VERSION
  if [[ ! -d $src/.git ]]; then
    git clone --depth 1 -b v$ORT_VERSION https://github.com/microsoft/onnxruntime.git $src
  fi
  [[ $(git -C $src rev-parse HEAD) == $ORT_COMMIT ]] || { echo "ORT 原始碼不是 v$ORT_VERSION（$ORT_COMMIT）" >&2; exit 1; }
  local out=$cache/build-minimal
  # 跟官方 AAR 的差別：只含 0c 的 op（--include_ops_by_config）、只讀 .ort（--minimal_build）、
  # 不含遙測（--no_telemetry）、只出 arm64。NNAPI 要留：官方 JNI 會連結 OrtSessionOptionsAppendExecutionProvider_Nnapi。
  (cd $src && $py tools/ci_build/build.py --build_dir $out --config MinSizeRel \
    --android --android_sdk_path $sdk --android_ndk_path $sdk/ndk/$NDK_VERSION \
    --android_abi arm64-v8a --android_api 29 \
    --build_shared_lib --skip_tests --parallel --cmake_generator Ninja \
    --use_nnapi --no_telemetry --disable_ml_ops \
    --minimal_build extended --enable_reduced_operator_type_support \
    --include_ops_by_config $here/required_operators.config)
  local so=$out/MinSizeRel/libonnxruntime.so

  local aar=$cache/onnxruntime-android-$ORT_VERSION.aar
  [[ -f $aar ]] || curl -fsSL -o $aar $AAR_URL
  [[ $(shasum -a 256 $aar | cut -d' ' -f1) == $AAR_SHA256 ]] || { echo "官方 AAR sha256 不符" >&2; exit 1; }
  local stage=$(mktemp -d)
  (cd $stage && unzip -q $aar)
  rm -rf $stage/jni/{armeabi-v7a,x86,x86_64}
  cp $so $stage/jni/arm64-v8a/libonnxruntime.so
  local dest=$here/onnxruntime-android-$ORT_VERSION-zc-minimal.aar
  rm -f $dest
  (cd $stage && zip -q -r -X $dest .)
  rm -rf $stage
  echo "執行庫 → ort/${dest:t}"
  ls -l $so; shasum -a 256 $so $dest
}

case $what in
  model) build_model ;;
  runtime) build_runtime ;;
  all) build_model; build_runtime ;;
  *) echo "用法：$0 [model|runtime|all]" >&2; exit 1 ;;
esac
