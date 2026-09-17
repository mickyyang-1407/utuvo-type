#!/usr/bin/env python3
"""Loopback-only local formatter for UTUVO Type.

The first request starts an mlx-lm server and waits for it to load the small
editor model. Later requests reuse that warm process. The wrapper deliberately
accepts the prompt on stdin so transcript/context text never appears in the
process list or command history.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


# 引擎家目錄（.runtime venv＋.models）：app 版由 UTUVO_TYPE_ENGINE_HOME 指定，repo 內直接跑就是 repo root。
ROOT = Path(os.environ.get("UTUVO_TYPE_ENGINE_HOME") or Path(__file__).resolve().parents[1])
PYTHON = ROOT / ".runtime" / "bin" / "python"
MODEL = ROOT / ".models" / "editor" / "Qwen3-4B-Instruct-2507-4bit"
STATE_DIR = ROOT / ".models" / "editor-server"
LOG_PATH = STATE_DIR / "server.log"
PID_PATH = STATE_DIR / "server.pid"
HOST = "127.0.0.1"
PORT = 18766
BASE_URL = f"http://{HOST}:{PORT}"
HEALTH_TIMEOUT = 120.0
HEALTH_REQUEST_TIMEOUT = 5.0
MAX_TOKENS = 512


def request_json(
    path: str,
    payload: dict | None = None,
    timeout: float = HEALTH_REQUEST_TIMEOUT,
) -> dict:
    body = None
    headers = {"Accept": "application/json"}
    method = "GET"
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    request = Request(
        f"{BASE_URL}{path}",
        data=body,
        headers=headers,
        method=method,
    )
    with urlopen(request, timeout=timeout) as response:
        raw = response.read()
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("editor server returned a non-object response")
    return value


def server_is_healthy() -> bool:
    try:
        value = request_json("/health")
        return value.get("status") == "ok"
    except (OSError, ValueError, HTTPError, URLError, json.JSONDecodeError):
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
    if PID_PATH.exists() and pid_is_alive():
        # A live PID from our own server is enough for the warm path. The
        # request below has its own timeout and uses the loopback endpoint.
        return
    if server_is_healthy():
        return
    if not PYTHON.is_file():
        raise RuntimeError(f"找不到本機 Python runtime：{PYTHON}")
    if not MODEL.is_dir():
        raise RuntimeError(f"找不到本機 editor 模型：{MODEL}")

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if PID_PATH.exists() and not pid_is_alive():
        try:
            PID_PATH.unlink()
        except OSError:
            pass

    log = LOG_PATH.open("ab")
    environment = os.environ.copy()
    environment["HF_HOME"] = str(ROOT / ".models" / "hf-cache")
    environment["PYTHONUNBUFFERED"] = "1"
    command = [
        str(PYTHON),
        "-m",
        "mlx_lm.server",
        "--model",
        str(MODEL),
        "--host",
        HOST,
        "--port",
        str(PORT),
        "--temp",
        "0",
        "--max-tokens",
        str(MAX_TOKENS),
        "--chat-template-args",
        '{"enable_thinking":false}',
    ]
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    PID_PATH.write_text(str(process.pid), encoding="utf-8")
    log.close()

    deadline = time.monotonic() + HEALTH_TIMEOUT
    while time.monotonic() < deadline:
        if server_is_healthy():
            return
        if process.poll() is not None:
            # Another UTUVO Type request may have won the startup race.
            if server_is_healthy():
                try:
                    PID_PATH.unlink()
                except OSError:
                    pass
                return
            try:
                PID_PATH.unlink()
            except OSError:
                pass
            raise RuntimeError(
                f"本機 editor server 無法啟動（exit {process.returncode}）；請查看 {LOG_PATH}"
            )
        time.sleep(0.25)

    raise TimeoutError(f"本機 editor server 啟動逾時；請查看 {LOG_PATH}")


def strip_reasoning(text: str) -> str:
    result = text
    while "<think>" in result and "</think>" in result:
        start = result.find("<think>")
        end = result.find("</think>", start) + len("</think>")
        result = result[:start] + result[end:]
    return result.replace("<think>", "").replace("</think>", "").strip()


def format_prompt(prompt: str) -> str:
    response = request_json(
        "/v1/chat/completions",
        {
            "model": str(MODEL),
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "temperature": 0.0,
            "max_tokens": MAX_TOKENS,
            "chat_template_kwargs": {"enable_thinking": False},
        },
        timeout=180.0,
    )
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("editor server returned no choices")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise ValueError("editor server returned no message")
    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        # mlx_lm 新版（2026-09 實測）會把整段輸出塞進 `reasoning`、把 `content` 設成
        # null——即使 enable_thinking=False。只讀 content 會讓 Smart 的本機 editor
        # 每次都失敗、靜默退化成 Fast。實測 reasoning 裡就是整理後的結果，收下它。
        fallback = message.get("reasoning")
        if isinstance(fallback, str) and fallback.strip():
            content = fallback
        else:
            raise ValueError("editor server returned no content")
    result = strip_reasoning(content)
    if not result:
        raise ValueError("editor server returned empty content")
    return convert_script(result)


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
        print("[utuvo-type-editor] WARNING: opencc missing; text passed through unconverted", file=sys.stderr)
        return text
    cache = convert_script.__dict__
    if cache.get("_config") != config:
        cache["_cc"] = OpenCC(config)
        cache["_config"] = config
    return cache["_cc"].convert(text)


def main() -> int:
    prompt = sys.stdin.read()
    if not prompt.strip():
        print("editor prompt 不可為空", file=sys.stderr)
        return 2
    try:
        start_server()
        sys.stdout.write(format_prompt(prompt))
        sys.stdout.write("\n")
        sys.stdout.flush()
        return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, HTTPError, URLError) as error:
        print(f"本機 editor 失敗：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
