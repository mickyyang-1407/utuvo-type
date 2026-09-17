#!/usr/bin/env python3
"""Loopback-only local Qwen3-ASR adapter for UTUVO Type."""

from __future__ import annotations

import json
import mimetypes
import os
from pathlib import Path
import fcntl
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


# 引擎家目錄（.runtime venv＋.models）：app 版由 UTUVO_TYPE_ENGINE_HOME 指定，repo 內直接跑就是 repo root。
ROOT = Path(os.environ.get("UTUVO_TYPE_ENGINE_HOME") or Path(__file__).resolve().parents[1])
PYTHON = ROOT / ".runtime" / "bin" / "python"
MODEL = ROOT / ".models" / "asr" / "Qwen3-ASR-0.6B-6bit"
STATE_DIR = ROOT / ".models" / "asr-server"
LOG_PATH = STATE_DIR / "server.log"
PID_PATH = STATE_DIR / "server.pid"
HOST = "127.0.0.1"
PORT = 18765
BASE_URL = f"http://{HOST}:{PORT}"
START_TIMEOUT = 120.0
HEALTH_TIMEOUT = 5.0


def server_is_healthy() -> bool:
    try:
        with urlopen(
            Request(f"{BASE_URL}/v1/models", method="GET"),
            timeout=HEALTH_TIMEOUT,
        ) as response:
            return 200 <= response.status < 300
    except (OSError, HTTPError, URLError):
        return False


def pid_is_alive() -> bool:
    try:
        pid = int(PID_PATH.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    status = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "stat="],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return bool(status) and "Z" not in status


def start_server() -> None:
    if server_is_healthy():
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / "startup.lock"
    with lock_path.open("a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            if server_is_healthy():
                return
            if not PYTHON.is_file() or not os.access(PYTHON, os.X_OK):
                raise RuntimeError(f"找不到本機 Python runtime：{PYTHON}")
            if not MODEL.is_dir():
                raise RuntimeError(f"找不到本機 ASR 模型：{MODEL}")

            (ROOT / ".models" / "hf-cache").mkdir(parents=True, exist_ok=True)
            if PID_PATH.exists() and not pid_is_alive():
                try:
                    PID_PATH.unlink()
                except OSError:
                    pass

            log = LOG_PATH.open("ab")
            environment = os.environ.copy()
            environment["HF_HOME"] = str(ROOT / ".models" / "hf-cache")
            environment["PYTHONUNBUFFERED"] = "1"
            process = subprocess.Popen(
                [
                    str(PYTHON),
                    "-m",
                    "mlx_audio.server",
                    "--host",
                    HOST,
                    "--port",
                    str(PORT),
                    "--log-dir",
                    str(STATE_DIR),
                ],
                cwd=ROOT,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
            PID_PATH.write_text(str(process.pid), encoding="utf-8")
            log.close()

            deadline = time.monotonic() + START_TIMEOUT
            while time.monotonic() < deadline:
                if server_is_healthy():
                    return
                if process.poll() is not None:
                    if server_is_healthy():
                        return
                    try:
                        PID_PATH.unlink()
                    except OSError:
                        pass
                    raise RuntimeError(
                        f"本機 ASR server 無法啟動（exit {process.returncode}）；請查看 {LOG_PATH}"
                    )
                time.sleep(0.25)

            raise TimeoutError(f"本機 ASR server 啟動逾時；請查看 {LOG_PATH}")
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def multipart_body(audio_path: Path) -> tuple[bytes, str]:
    boundary = f"----UTUVOType{uuid.uuid4().hex}"
    content_type = mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream"
    audio = audio_path.read_bytes()
    chunks = [
        f"--{boundary}\r\n".encode(),
        (
            f'Content-Disposition: form-data; name="file"; '
            f'filename="{audio_path.name}"\r\n'
        ).encode(),
        f"Content-Type: {content_type}\r\n\r\n".encode(),
        audio,
        b"\r\n",
    ]
    fields = [("model", str(MODEL)), ("response_format", "text")]
    # 語言由 app 設定傳入；auto＝省略欄位讓 Qwen3-ASR 自行偵測（可混語）。
    language = os.environ.get("UTUVO_TYPE_ASR_LANGUAGE", "Chinese")
    if language and language.lower() != "auto":
        fields.append(("language", language))
    for name, value in fields:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def transcribe(audio_path: Path) -> str:
    body, content_type = multipart_body(audio_path)
    request = Request(
        f"{BASE_URL}/v1/audio/transcriptions",
        data=body,
        headers={"Content-Type": content_type, "Accept": "text/plain, application/json"},
        method="POST",
    )
    with urlopen(request, timeout=120.0) as response:
        raw = response.read()
    text = raw.decode("utf-8").strip()
    if text.startswith("{"):
        value = json.loads(text)
        text = str(value.get("text", "")).strip()
    if not text:
        raise RuntimeError("本機 ASR 回傳空白文字")
    return convert_script(text)


def convert_script(text: str) -> str:
    """依 UTUVO_TYPE_OUTPUT_SCRIPT 轉換中文字形（app 設定「輸出文字」傳入）。

    traditional（預設）＝OpenCC s2twp（台灣用語＋詞級）；simplified＝t2s；as-is＝原樣。
    fail-open：opencc 不可用時保留原文，但必須在 stderr 留痕，不准無聲吞掉。
    """
    mode = os.environ.get("UTUVO_TYPE_OUTPUT_SCRIPT", "traditional")
    config = {"traditional": "s2twp", "simplified": "t2s"}.get(mode)
    if config is None:
        return text
    # 含假名字母（平假名／片假名，排除 ・ ー 這類也出現在中文譯名的符號）＝日文內容：
    # OpenCC s2t 會誤改日文漢字（国→國），整段跳過。混語內容以不誤改為優先。
    if any("\u3041" <= ch <= "\u3096" or "\u30a1" <= ch <= "\u30fa" for ch in text):
        return text
    try:
        from opencc import OpenCC
    except ImportError:
        print("[utuvo-type-asr] WARNING: opencc missing; text passed through unconverted", file=sys.stderr)
        return text
    cache = convert_script.__dict__
    if cache.get("_config") != config:
        cache["_cc"] = OpenCC(config)
        cache["_config"] = config
    return cache["_cc"].convert(text)


def convert_to_wav(audio_path: Path) -> tuple[Path, Path | None]:
    """mlx_audio expects a recognizable container; AudioCapture writes CAF."""
    if audio_path.suffix.lower() in {".wav", ".wave"}:
        return audio_path, None
    temporary_dir = Path(tempfile.mkdtemp(prefix="utuvo-type-asr-"))
    wav_path = temporary_dir / "input.wav"
    try:
        subprocess.run(
            [
                "/usr/bin/afconvert",
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
                str(audio_path),
                str(wav_path),
            ],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise RuntimeError(f"音訊轉 WAV 失敗：{error}") from error
    return wav_path, temporary_dir


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: utuvo-type-asr AUDIO_FILE", file=sys.stderr)
        return 64
    audio_path = Path(sys.argv[1]).expanduser()
    if not audio_path.is_file():
        print("audio file not found", file=sys.stderr)
        return 66
    try:
        start_server()
        prepared_audio, temporary_dir = convert_to_wav(audio_path)
        try:
            print(transcribe(prepared_audio))
        finally:
            if temporary_dir is not None:
                shutil.rmtree(temporary_dir, ignore_errors=True)
        return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, HTTPError, URLError) as error:
        print(f"本機 ASR 失敗：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
