"""Pure checks for the resident ASR server and wrapper: no model, microphone, or network."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = load("utuvo_type_asr_server", "utuvo-type-asr-server.py")
wrapper = load("utuvo_type_asr", "utuvo-type-asr.py")


class HotwordTests(unittest.TestCase):
    def test_parses_newlines_and_commas_dedups_and_caps(self):
        self.assertEqual(server.parse_hotwords("Atmos\nADM, Atmos\n\n 母帶 "), ["Atmos", "ADM", "母帶"])
        self.assertEqual(server.parse_hotwords(None), [])
        many = "\n".join(f"term{i}" for i in range(500))
        self.assertEqual(len(server.parse_hotwords(many)), server.MAX_HOTWORDS)
        self.assertEqual(server.parse_hotwords("x" * 61), [], "absurdly long entries are not vocabulary")


class LoopGuardTests(unittest.TestCase):
    def test_detects_decoder_loops_but_not_normal_speech(self):
        self.assertTrue(server.looks_looping("有 T O V O " + "T O " * 40, 5.0))
        self.assertTrue(server.looks_looping("好" * 200, 5.0))
        for normal in ["明天下午我們在錄音室對 Atmos 母帶，記得帶 ADM 檔案。",
                       "哈哈哈哈好啊",  # 4 repeats is ordinary speech
                       "我覺得這次的混音方向還要再想一下。" * 3]:
            self.assertFalse(server.looks_looping(normal, 20.0), normal)


class TokenCapTests(unittest.TestCase):
    def test_cap_is_for_the_whole_recording(self):
        # 2026-09-24: capping per 30 s chunk cut a 177 s recording from 12 sentences to 9.
        self.assertGreaterEqual(server.token_cap(177), 177 * 8)
        self.assertEqual(server.token_cap(2), 256)

    def test_wav_duration(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            with wave.open(tmp.name, "wb") as out:
                out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
                out.writeframes(b"\0\0" * 16000 * 3)
            self.assertAlmostEqual(server.wav_seconds(tmp.name), 3.0)
        self.assertEqual(server.wav_seconds("/nonexistent.wav"), server.CHUNK_SECONDS)


class WrapperTests(unittest.TestCase):
    def test_only_utuvo_asr_servers_are_replaced(self):
        def fake_ps(args, **_):
            class R: stdout = {"11": "/x/.runtime/bin/python -m mlx_audio.server --port 18765",
                               "12": "/x/.runtime/bin/python /x/runtime/utuvo-type-asr-server.py --model m",
                               "13": "/Applications/Other.app/Contents/MacOS/other"}[args[2]]
            return R()
        with patch.object(wrapper.subprocess, "run", side_effect=fake_ps):
            self.assertTrue(wrapper.is_type_asr_process(11))
            self.assertTrue(wrapper.is_type_asr_process(12))
            self.assertFalse(wrapper.is_type_asr_process(13), "never kill an unrelated process on the port")

    def test_hotwords_are_sent_only_when_configured(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            tmp.write(b"RIFF"); tmp.flush()
            with patch.dict(wrapper.os.environ, {"UTUVO_TYPE_ASR_HOTWORDS": "Atmos\nADM"}):
                body, _ = wrapper.multipart_body(Path(tmp.name))
            self.assertIn(b'name="hotwords"', body)
            self.assertIn("Atmos\nADM".encode(), body)
            with patch.dict(wrapper.os.environ, {"UTUVO_TYPE_ASR_HOTWORDS": ""}):
                body, _ = wrapper.multipart_body(Path(tmp.name))
            self.assertNotIn(b'name="hotwords"', body)


class ModelChoiceTests(unittest.TestCase):
    def test_prefers_complete_bigger_model_and_ignores_partial_downloads(self):
        with tempfile.TemporaryDirectory() as home:
            asr = Path(home)
            big, small = asr / "Qwen3-ASR-1.7B-8bit", asr / "Qwen3-ASR-0.6B-6bit"
            big.mkdir(); small.mkdir()
            (big / "config.json").write_text("{}"); (small / "config.json").write_text("{}")
            with patch.object(wrapper, "ASR_DIR", asr):
                self.assertEqual(wrapper.choose_model(), small, "1.7B without .complete is a partial download")
                (big / ".complete").write_text("done")
                self.assertEqual(wrapper.choose_model(), big)


if __name__ == "__main__":
    unittest.main()
