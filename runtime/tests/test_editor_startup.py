"""Isolated startup checks: no model, microphone, or network is used."""

import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "utuvo-type-editor.py"
spec = importlib.util.spec_from_file_location("utuvo_type_editor", SCRIPT)
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)


class EditorStartupTests(unittest.TestCase):
    def test_warmup_starts_server_without_reading_prompt(self):
        class NoInput:
            def read(self):
                raise AssertionError("warmup must not read transcript input")

        with patch.object(sys, "argv", [str(SCRIPT), "--warmup"]), \
             patch.object(sys, "stdin", NoInput()), \
             patch.object(sys, "stdout", io.StringIO()) as output, \
             patch.object(editor, "start_server") as start, \
             patch.object(editor, "format_prompt") as format_prompt:
            self.assertEqual(editor.main(), 0)
            start.assert_called_once_with()
            format_prompt.assert_not_called()
            self.assertEqual(output.getvalue(), "")

    def test_existing_pid_waits_until_server_is_healthy(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            pid_path = state / "server.pid"
            pid_path.write_text("12345", encoding="utf-8")
            healthy = [False, False, False, True]
            with patch.object(editor, "STATE_DIR", state), \
                 patch.object(editor, "PID_PATH", pid_path), \
                 patch.object(editor, "LOCK_PATH", state / "server.lock"), \
                 patch.object(editor, "server_is_healthy", side_effect=lambda: healthy.pop(0)), \
                 patch.object(editor, "pid_is_alive", return_value=True), \
                 patch.object(editor.subprocess, "Popen") as spawn, \
                 patch.object(editor.time, "sleep") as sleep:
                editor.start_server()
                spawn.assert_not_called()
                sleep.assert_called_once()
                self.assertEqual(healthy, [])


if __name__ == "__main__":
    unittest.main()
