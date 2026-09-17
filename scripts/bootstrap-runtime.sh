#!/usr/bin/env bash
# UTUVO Type 本機引擎一鍵安裝：建 venv、裝相依、下載 ASR 模型。
# 防呆原則：每一步先檢查再動作、失敗訊息附下一步指令、重跑安全（idempotent）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 引擎家目錄：venv 與模型放哪。從 repo 跑＝repo root；DMG／App 版由 app 傳
# UTUVO_TYPE_ENGINE_HOME（~/Library/Application Support/UTUVO Type/engine），
# 因為簽過名的 app bundle 不能寫、也不該被寫。
ENGINE_HOME="${UTUVO_TYPE_ENGINE_HOME:-$REPO_ROOT}"
export UTUVO_TYPE_ENGINE_HOME="$ENGINE_HOME"
mkdir -p "$ENGINE_HOME"
RUNTIME="$ENGINE_HOME/.runtime"
MODELS="$ENGINE_HOME/.models"
ASR_MODEL_DIR="$MODELS/asr/Qwen3-ASR-0.6B-6bit"
ASR_MODEL_REPO="${UTUVO_TYPE_ASR_MODEL_REPO:-mlx-community/Qwen3-ASR-0.6B-6bit}"

say() { printf '[bootstrap] %s\n' "$1"; }
die() { printf '[bootstrap] ERROR: %s\n' "$1" >&2; exit 1; }

# 0. 平台檢查：本機引擎需要 Apple Silicon（mlx 限定）。
if [ "$(uname -m)" != "arm64" ]; then
  die "本機引擎需要 Apple Silicon（偵測到 $(uname -m)）。Intel Mac 請在設定改用雲端路徑。"
fi

# 1. Python 3.10+：先找系統／brew 的，找不到就下載獨立版 CPython 到引擎家目錄
#    （macOS 內建 /usr/bin/python3 是 3.9，DMG 使用者多半沒裝 brew——不能叫他們先去裝東西）。
python_ok() {
  [ -x "$1" ] || return 1
  case "$("$1" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null)" in
    3.1[0-9]|3.[2-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}
find_python() {
  local cand
  for cand in "$ENGINE_HOME/python/bin/python3" \
              "$(command -v python3.13 || true)" "$(command -v python3.12 || true)" \
              "$(command -v python3.11 || true)" "$(command -v python3.10 || true)" \
              "$(command -v python3 || true)"; do
    [ -n "$cand" ] && python_ok "$cand" && { printf '%s' "$cand"; return 0; }
  done
  return 1
}
install_standalone_python() {
  # astral-sh/python-build-standalone：install_only 版，解開就是 python/{bin,lib}，約 23 MB。
  say "找不到 Python 3.10+，下載獨立版 CPython 3.12（約 23 MB）→ $ENGINE_HOME/python"
  local api url tmp
  api="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
  url="$(curl -fsSL --max-time 30 "$api" \
        | grep -o 'https://github.com/[^"]*cpython-3\.12[^"]*aarch64-apple-darwin-install_only\.tar\.gz' \
        | head -1 || true)"
  [ -n "$url" ] || die "查不到獨立版 Python 下載網址；請檢查網路，或自行安裝：brew install python@3.12"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar --max-time 600 "$url" -o "$tmp/python.tar.gz" \
    || die "下載獨立版 Python 失敗；請檢查網路後重跑，或自行安裝：brew install python@3.12"
  rm -rf "$ENGINE_HOME/python"
  tar -xzf "$tmp/python.tar.gz" -C "$ENGINE_HOME" || die "解壓獨立版 Python 失敗"
  rm -rf "$tmp"
  python_ok "$ENGINE_HOME/python/bin/python3" || die "獨立版 Python 無法執行；請自行安裝：brew install python@3.12"
}
if [ ! -x "$RUNTIME/bin/python" ]; then
  if ! PY="$(find_python)"; then
    install_standalone_python
    PY="$ENGINE_HOME/python/bin/python3"
  fi
  PYVER="$("$PY" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
  say "建立 venv（python $PYVER：$PY）→ $RUNTIME"
  say "引擎家目錄：$ENGINE_HOME"
  "$PY" -m venv "$RUNTIME"
else
  say "venv 已存在，跳過建立"
fi

# 2. 相依套件
say "安裝相依套件（requirements.txt）"
"$RUNTIME/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
# --only-binary=:all：DMG 使用者沒有編譯器（或沒同意 Xcode license），任何要從源碼編的套件都該在這裡
# 直接紅、講清楚，而不是跑進 clang 之後噴 25 行 setuptools 警告。
"$RUNTIME/bin/python" -m pip install --quiet --only-binary=:all: -r "$REPO_ROOT/runtime/requirements.txt" \
  || die "pip 安裝失敗。若上面出現「No matching distribution」或 clang／Xcode license 字樣＝某套件沒有預編 wheel，請回報版本；若是逾時／連線錯誤請檢查網路後重跑"
"$RUNTIME/bin/python" - <<'EOF' || die "相依驗證失敗：本機 ASR server 的 import 不過；請重跑本腳本"
# 除了 mlx_audio 本體，也要驗 server 進程真正會 import 的東西（uvicorn／fastapi／webrtcvad→pkg_resources）；
# 只驗 mlx_audio 會綠燈但 server 起不來（2026-09-17 模擬 DMG 使用者抓到）。
import mlx_audio, opencc, uvicorn, fastapi, webrtcvad, pkg_resources
import mlx_audio.server
print("[bootstrap] deps ok: mlx_audio server stack importable")
EOF

# 3. ASR 模型（約 1.2 GB，一次性）
if [ -d "$ASR_MODEL_DIR" ] && [ -n "$(ls -A "$ASR_MODEL_DIR" 2>/dev/null)" ]; then
  say "ASR 模型已存在，跳過下載"
else
  FREE_GB=$(df -g "$ENGINE_HOME" | awk 'NR==2{print $4}')
  [ "$FREE_GB" -ge 4 ] || die "磁碟剩餘 ${FREE_GB} GB，不足 4 GB；請清出空間後重跑"
  say "下載 ASR 模型 $ASR_MODEL_REPO（約 1.2 GB，支援斷點續傳）"
  mkdir -p "$MODELS/hf-cache"
  HF_HOME="$MODELS/hf-cache" "$RUNTIME/bin/python" - "$ASR_MODEL_REPO" "$ASR_MODEL_DIR" <<'EOF' \
    || die "模型下載失敗；請檢查網路後重跑本腳本（會從斷點續傳）"
import sys
from huggingface_hub import snapshot_download
repo, dest = sys.argv[1], sys.argv[2]
snapshot_download(repo_id=repo, local_dir=dest)
print(f"[bootstrap] model ready: {dest}")
EOF
fi

# 4. 端到端自檢：合成一句中文語音跑完整條 ASR 路徑。
say "端到端自檢（合成語音 → 本機 ASR → 繁體輸出）"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT
if [ -x /usr/bin/say ]; then
  /usr/bin/say -v Meijia "本機引擎安裝完成" -o "$SMOKE_DIR/smoke.aiff" 2>/dev/null || true
fi
if [ -f "$SMOKE_DIR/smoke.aiff" ]; then
  OUT="$("$REPO_ROOT/runtime/utuvo-type-asr" "$SMOKE_DIR/smoke.aiff")" \
    || die "自檢失敗：ASR wrapper 執行錯誤；請看 $MODELS/asr-server/server.log"
  say "自檢輸出：$OUT"
else
  say "略過語音自檢（無中文語音合成聲音）；改驗 server 啟動"
fi

say "完成。開啟 UTUVO Type.app 按快捷鍵即可聽寫（完全本機，不需網路）。"
