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
# ASR 模型依記憶體選（2026-09-24 Micky 核准）：16 GB 以上用 1.7B（60 段實測＋字典熱詞：字錯率 15.5% → 11.1%），
# 否則 0.6B。名稱清單與 runtime/utuvo-type-asr.py、RuntimeBootstrap.swift 一致（測試會對）。
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
if [ -n "${UTUVO_TYPE_ASR_MODEL_REPO:-}" ]; then
  ASR_MODEL_REPO="$UTUVO_TYPE_ASR_MODEL_REPO"
elif [ "$MEM_GB" -ge 16 ]; then
  ASR_MODEL_REPO="mlx-community/Qwen3-ASR-1.7B-8bit"
else
  ASR_MODEL_REPO="mlx-community/Qwen3-ASR-0.6B-6bit"
fi
ASR_MODEL_DIR="$MODELS/asr/${ASR_MODEL_REPO##*/}"
case "$ASR_MODEL_REPO" in *1.7B*) ASR_MODEL_SIZE="約 2.5 GB"; NEED_GB=6 ;; *) ASR_MODEL_SIZE="約 860 MB"; NEED_GB=4 ;; esac

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
  # App 版內建官方 install_only 壓縮檔（build-app.sh 放進 engine/python/，附 SHA-256）：驗過就直接解壓，不上 GitHub。
  local bundled
  bundled="$(ls "$REPO_ROOT/python/"cpython-*-install_only.tar.gz 2>/dev/null | head -1 || true)"
  if [ -n "$bundled" ] && [ -f "$REPO_ROOT/python/SHA256" ]; then
    if [ "$(shasum -a 256 "$bundled" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$REPO_ROOT/python/SHA256")" ]; then
      say "使用 App 內建的 Python 3.12（不需下載）→ $ENGINE_HOME/python"
      rm -rf "$ENGINE_HOME/python"
      tar -xzf "$bundled" -C "$ENGINE_HOME" || die "解壓內建 Python 失敗；請重新下載 DMG"
      python_ok "$ENGINE_HOME/python/bin/python3" && return 0
      say "內建 Python 無法執行，改從網路下載"
    else
      say "內建 Python 檢查碼不符，改從網路下載"
    fi
  fi
  # astral-sh/python-build-standalone：install_only 版，解開就是 python/{bin,lib}，約 23 MB。
  say "找不到 Python 3.10+，下載獨立版 CPython 3.12（約 23 MB）→ $ENGINE_HOME/python"
  local api url tmp
  api="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
  url="$(curl -fsSL --max-time 30 "$api" \
        | grep -o 'https://github.com/[^"]*cpython-3\.12[^"]*aarch64-apple-darwin-install_only\.tar\.gz' \
        | head -1 || true)"
  [ -n "$url" ] || die "查不到獨立版 Python 下載網址；請檢查網路，或自行安裝：brew install python@3.12"
  tmp="$(mktemp -d)"
  # --progress-bar 用 \r 不換行：app 只看得到同一行（2026-09-24 苑涵實機截圖就停在這）。改成靜音下載＋完成後印大小。
  # 2026-09-24 無 Python 模擬：GitHub 下載 25 MB 花 147 s，整段零輸出。背景下載、每 3 秒印一行；120 秒沒進度就停。
  curl -fsSL --connect-timeout 20 --max-time 900 "$url" -o "$tmp/python.tar.gz" &
  local curl_pid=$! last=-1 still=0 now
  while kill -0 "$curl_pid" 2>/dev/null; do
    sleep 3
    now=$(stat -f %z "$tmp/python.tar.gz" 2>/dev/null || echo 0)
    if [ "$now" = "$last" ]; then still=$((still + 3)); else still=0; last=$now; fi
    if [ "$still" -ge "${UTUVO_TYPE_STALL_SECONDS:-120}" ]; then
      kill "$curl_pid" 2>/dev/null || true
      die "下載 Python 停住 ${still} 秒沒有進度；請檢查網路後按「重試安裝」"
    fi
    say "Python 下載中：$(( now / 1000000 )) / 約 25 MB"
  done
  wait "$curl_pid" || die "下載獨立版 Python 失敗；請檢查網路後重跑，或自行安裝：brew install python@3.12"
  say "Python 下載完成（$(( $(stat -f %z "$tmp/python.tar.gz") / 1000000 )) MB），解壓中…"
  rm -rf "$ENGINE_HOME/python"
  tar -xzf "$tmp/python.tar.gz" -C "$ENGINE_HOME" || die "解壓獨立版 Python 失敗"
  rm -rf "$tmp"
  python_ok "$ENGINE_HOME/python/bin/python3" || die "獨立版 Python 無法執行；請自行安裝：brew install python@3.12"
}
if [ ! -x "$RUNTIME/bin/python" ]; then
  say "第 1／4 步：準備 Python 環境"
  # App 內建 Python 優先（每台 Mac 同一版，不受使用者自己的 conda／brew 影響）。
  if ls "$REPO_ROOT/python/"cpython-*-install_only.tar.gz >/dev/null 2>&1 && ! python_ok "$ENGINE_HOME/python/bin/python3"; then
    install_standalone_python
  fi
  if ! PY="$(find_python)"; then
    install_standalone_python
    PY="$ENGINE_HOME/python/bin/python3"
  fi
  PYVER="$("$PY" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
  say "建立 Python 環境（python $PYVER：$PY）→ $RUNTIME"
  say "引擎家目錄：$ENGINE_HOME"
  "$PY" -m venv "$RUNTIME"
else
  say "第 1／4 步：Python 環境已存在，跳過"
fi

# 2. 相依套件
# 2026-09-24 實機（苑涵 0.1.5）：這步約 560 MB、在 1 MB/s 的網路要 10 分鐘，原本 --quiet 整段沒有任何輸出，
# 使用者以為卡死。改成每個套件一行（app 顯示最後一行），並設逾時與重試。
say "第 2／4 步：下載並安裝相依套件（約 560 MB，網路慢時需要 10 分鐘以上）"
"$RUNTIME/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
# --only-binary=:all：DMG 使用者沒有編譯器（或沒同意 Xcode license），任何要從源碼編的套件都該在這裡
# 直接紅、講清楚，而不是跑進 clang 之後噴 25 行 setuptools 警告。
"$RUNTIME/bin/python" -m pip install --disable-pip-version-check --progress-bar off --timeout 30 --retries 5 \
  --only-binary=:all: -r "$REPO_ROOT/runtime/requirements.txt" \
  || die "pip 安裝失敗。若上面出現「No matching distribution」或 clang／Xcode license 字樣＝某套件沒有預編 wheel，請回報版本；若是逾時／連線錯誤請檢查網路後重跑"
"$RUNTIME/bin/python" - <<'EOF' || die "相依驗證失敗：本機 ASR server 的 import 不過；請重跑本腳本"
# 除了 mlx_audio 本體，也要驗 server 進程真正會 import 的東西（uvicorn／fastapi／webrtcvad→pkg_resources）；
# 只驗 mlx_audio 會綠燈但 server 起不來（2026-09-17 模擬 DMG 使用者抓到）。
import mlx_audio, opencc, uvicorn, fastapi, webrtcvad, pkg_resources
import mlx_audio.server
print("[bootstrap] deps ok: mlx_audio server stack importable")
EOF

# 3. ASR 模型（約 1.2 GB，一次性）
# 完成標記：下載中斷的半套模型不能被當成已安裝（舊版 0.6B 沒有標記，有 config.json 就視為完整）。
if [ -f "$ASR_MODEL_DIR/.complete" ] || { [ "${ASR_MODEL_REPO##*/}" = "Qwen3-ASR-0.6B-6bit" ] && [ -f "$ASR_MODEL_DIR/config.json" ]; }; then
  say "第 3／4 步：語音辨識模型 ${ASR_MODEL_REPO##*/} 已存在，跳過下載"
else
  FREE_GB=$(df -g "$ENGINE_HOME" | awk 'NR==2{print $4}')
  [ "$FREE_GB" -ge "$NEED_GB" ] || die "磁碟剩餘 ${FREE_GB} GB，不足 ${NEED_GB} GB；請清出空間後重跑"
  say "第 3／4 步：下載語音辨識模型 $ASR_MODEL_REPO（${ASR_MODEL_SIZE}，支援斷點續傳）"
  mkdir -p "$MODELS/hf-cache"
  # 進度條（tqdm 用 \r 不換行）在 app 裡永遠只看到同一行＝看起來卡住；改成每 3 秒印一行已下載 MB。
  # 不用 xet：2026-09-24 Studio 實測 xet 316 s、一般 HTTP 100 s，而且 xet 下載中磁碟上看不到進度。
  # 180 秒完全沒進度＝網路卡住：明確失敗，重按安裝會從斷點續傳（不是無限等）。
  HF_HOME="$MODELS/hf-cache" HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_PROGRESS_BARS=1 \
    "$RUNTIME/bin/python" - "$ASR_MODEL_REPO" "$ASR_MODEL_DIR" <<'EOF' \
    || die "模型下載失敗或停住；請檢查網路後按「重試安裝」（會從斷點續傳）"
import os, sys, threading, time
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download
repo, dest = sys.argv[1], sys.argv[2]
stall_seconds = float(os.environ.get("UTUVO_TYPE_STALL_SECONDS", "180"))
total = 0
def downloaded() -> int:
    size = 0
    for root in (Path(dest), Path(os.environ["HF_HOME"])):
        if root.exists():
            size += sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    return size
done = threading.Event()
def report():
    last, last_change = -1, time.monotonic()
    while not done.wait(3):
        now = downloaded()
        if now != last:
            last, last_change = now, time.monotonic()
        elif time.monotonic() - last_change > stall_seconds:
            print(f"[bootstrap] ERROR: 模型下載 {int(stall_seconds)} 秒沒有進度（網路卡住）", flush=True)
            os._exit(3)
        mb = now // 1_000_000
        if total:
            print(f"[bootstrap] 模型下載中：{mb} / {total // 1_000_000} MB（{min(99, now * 100 // total)}%）", flush=True)
        else:
            print(f"[bootstrap] 模型下載中：{mb} MB", flush=True)
threading.Thread(target=report, daemon=True).start()   # 先起 watchdog：連查檔案清單都卡住也要能停
try:
    info = HfApi().model_info(repo, files_metadata=True)
    total = sum((f.size or 0) for f in info.siblings)
except Exception:
    total = 0
snapshot_download(repo_id=repo, local_dir=dest)
done.set()
Path(dest, ".complete").write_text(repo + "\n", encoding="utf-8")
print(f"[bootstrap] model ready: {dest}", flush=True)
EOF
fi

# 4. 端到端自檢：合成一句中文語音跑完整條 ASR 路徑。
say "第 4／4 步：端到端自檢（合成語音 → 本機 ASR → 繁體輸出）"
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
