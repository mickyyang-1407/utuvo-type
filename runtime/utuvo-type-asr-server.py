#!/usr/bin/env python3
"""Loopback-only resident Qwen3-ASR server for UTUVO Type.

Replaces ``python -m mlx_audio.server`` for the local route (2026-09-24). The upstream
server's ``context`` form field never reaches Qwen3-ASR (the model reads biasing text from
``system_prompt``); verified by sending identical audio with and without it. This server
passes the user's vocabulary as ``hotwords`` and bounds output length.

Measured on 60 zh-TW clips (5 voices x 12 domain sentences): Qwen3-ASR-0.6B CER 26.0% -> 15.3%,
domain-term hits 7/60 -> 30/60 with hotwords. Long audio is chunked at 30 s and max_tokens is
capped from duration: uncapped 1.7B looped to 12,528 characters on a 177 s recording.
"""


import argparse
import re
import tempfile
import threading
import wave
from pathlib import Path

SERVER_ID = "utuvo-asr-2"
CHUNK_SECONDS = 30.0
MAX_HOTWORDS = 80


def parse_hotwords(raw: str | None) -> list[str]:
    """Newline- or comma-separated terms, trimmed, de-duplicated, capped."""
    if not raw:
        return []
    seen: set[str] = set()
    out: list[str] = []
    for part in raw.replace(",", "\n").splitlines():
        term = part.strip()
        if term and term not in seen and len(term) <= 60:
            seen.add(term)
            out.append(term)
        if len(out) >= MAX_HOTWORDS:
            break
    return out


def token_cap(duration_seconds: float) -> int:
    """Roughly 8 tokens per second of speech, never below 256: dictation cannot need more,
    and a repetition loop stops early instead of running for minutes."""
    return max(256, int(duration_seconds * 8) + 64)


LOOP = re.compile(r"(.{1,8}?)(?:\s*\1){7,}", re.S)


def looks_looping(text: str, duration_seconds: float) -> bool:
    """Decoder stuck in a loop: the same 1–8 character unit 8+ times in a row, or far more text
    than anyone can speak (~12 characters per second). 2026-09-24: Qwen3-ASR-0.6B with an 80-term
    hotword list looped on 1 of 60 clips ("T O T O …") while the other 59 improved."""
    compact = text.strip()
    return bool(LOOP.search(compact)) or len(compact) > max(80, duration_seconds * 12)


def wav_seconds(path: str) -> float:
    """The wrapper always sends 16 kHz WAV (afconvert); anything unreadable counts as one chunk."""
    try:
        with wave.open(path, "rb") as audio:
            return audio.getnframes() / float(audio.getframerate() or 1)
    except (wave.Error, OSError, EOFError):
        return CHUNK_SECONDS


def build_app(model_path: str):
    from fastapi import FastAPI, File, Form, UploadFile
    from fastapi.responses import JSONResponse, PlainTextResponse
    from mlx_audio.stt.utils import load_model

    app = FastAPI()
    lock = threading.Lock()
    model = load_model(model_path)

    @app.get("/v1/models")
    def models():
        return JSONResponse({"server": SERVER_ID, "data": [{"id": model_path}]})

    @app.post("/v1/audio/transcriptions")
    def transcribe(file: UploadFile = File(...), language: str | None = Form(None),
                   hotwords: str | None = Form(None)):
        suffix = Path(file.filename or "audio.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
            tmp.write(file.file.read())
            tmp.flush()
            duration = wav_seconds(tmp.name)
            # max_tokens 是整段總上限（不是每個 chunk）：用整段長度算，長段落才不會被截掉尾巴。
            kwargs = dict(chunk_duration=CHUNK_SECONDS, max_tokens=token_cap(duration))
            if language and language.lower() != "auto":
                kwargs["language"] = language
            terms = parse_hotwords(hotwords)
            if terms:
                kwargs["hotwords"] = terms
            with lock:
                text = model.generate(tmp.name, **kwargs).text.strip()
                if terms and looks_looping(text, duration):
                    # 熱詞偶爾讓模型卡進迴圈：這一段改用不帶熱詞重跑，寧可少認一個專名也不要亂碼。
                    kwargs.pop("hotwords", None)
                    text = model.generate(tmp.name, **kwargs).text.strip()
        return PlainTextResponse(text)

    return app


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit("loopback only")
    import uvicorn
    uvicorn.run(build_app(args.model), host=args.host, port=args.port, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
