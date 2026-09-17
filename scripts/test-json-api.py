#!/usr/bin/env python3
"""Exercise the real backend protocol with isolated history and fake osascript.

No test reads or writes the user's clipboard contents or real history. Native
change-count polling still runs, but every AppleScript operation is intercepted.
"""

import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "zig-out/bin/clipz"


class JsonApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="api-test-", dir=ROOT / ".zig-cache")
        self.home = Path(self.temp.name)
        self.history = self.home / ".clipz_history.json"
        self.process = None
        self.selector = selectors.DefaultSelector()
        self.buffer = b""
        self.messages = []
        fake = self.home / "osascript"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "script = sys.argv[2]\n"
            "home = pathlib.Path(os.environ['HOME'])\n"
            "restored = home / 'alias-restored'\n"
            "if 'clipboard info' in script:\n"
            "    if (home / 'fail-capture').exists():\n"
            "        sys.exit(1)\n"
            "    fmt = os.environ.get('CLIPZ_TEST_FORMAT', 'text')\n"
            "    if fmt == 'file' and restored.exists():\n"
            "        fmt = 'alias' if 'clipboard info for alias' in script else 'text'\n"
            "    print(fmt)\n"
            "elif 'return POSIX path of (get the clipboard as alias)' in script:\n"
            "    print(home / 'teachers.csv')\n"
            "elif 'return POSIX path of (get the clipboard as «class furl»)' in script:\n"
            "    if restored.exists():\n"
            "        sys.exit(1)\n"
            "    print(home / 'teachers.csv')\n"
            "elif 'on run argv' in script:\n"
            "    signatures = {'PNG': b'\\x89PNG\\r\\n\\x1a\\n',"
            " 'JPEG': b'\\xff\\xd8\\xff', 'TIFF': b'II\\x2a\\x00'}\n"
            "    pathlib.Path(sys.argv[3]).write_bytes(signatures[sys.argv[4]] + b'test image')\n"
            "    print('success')\n"
            "elif 'return \"success\"' in script:\n"
            "    if 'as alias)' in script:\n"
            "        restored.touch()\n"
            "    print('success')\n"
            "else:\n"
            "    if restored.exists():\n"
            "        sys.exit(1)\n"
            "    print('captured-on-startup')\n"
        )
        fake.chmod(0o700)

    def tearDown(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
        self.selector.close()
        self.temp.cleanup()

    def start(self, image_format=None):
        if self.process is not None:
            self.assertIsNotNone(self.process.poll(), "Previous backend must exit before restart")
            self.selector.unregister(self.process.stdout)
            self.process.stdin.close()
            self.process.stdout.close()
            self.buffer = b""
        env = dict(os.environ, HOME=str(self.home))
        env["PATH"] = str(self.home) + os.pathsep + env["PATH"]
        if image_format is not None:
            env["CLIPZ_TEST_FORMAT"] = image_format
        else:
            env.pop("CLIPZ_TEST_FORMAT", None)
        self.process = subprocess.Popen(
            [str(BACKEND), "--json-api", "--low-power"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.assertEqual(self.read_message()["type"], "ready")

    def read_message(self):
        deadline = time.monotonic() + 10
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "Timed out waiting for a JSON frame")
            self.assertTrue(self.selector.select(remaining), "Backend did not respond")
            data = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(data, f"Backend closed stdout; exit={self.process.poll()}")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        message = json.loads(line)
        self.messages.append(message)
        return message

    def wait_for(self, predicate):
        for _ in range(100):
            message = self.read_message()
            if predicate(message):
                return message
        self.fail("Too many messages without the expected response")

    def send(self, command):
        self.process.stdin.write((command + "\n").encode())
        self.process.stdin.flush()

    def quit(self):
        self.send("quit")
        self.assertEqual(self.process.wait(timeout=10), 0)

    def seed(self, entries):
        self.history.write_text(json.dumps({"version": 4, "next_id": 10, "entries": entries}))

    @staticmethod
    def entry(entry_id, content, kind="text"):
        return {"id": entry_id, "content": content, "timestamp": 1, "type": kind, "pinned": False}

    def test_startup_capture_and_quit_flush_pending_selection(self):
        self.seed([self.entry(1, "saved-before-startup")])
        self.start()
        entries = self.wait_for(
            lambda m: m["type"] == "entries"
            and any(e["content"] == "captured-on-startup" for e in m["data"])
        )
        self.assertTrue(entries["data"][0]["isCurrent"])
        # Selection happens within the 30-second batch window. Quit must flush it.
        self.send("select-entry-id:1")
        self.wait_for(lambda m: m["type"] == "select-success")
        self.quit()
        saved = json.loads(self.history.read_text())
        self.assertEqual(saved["entries"][-1]["id"], 1)
        self.assertEqual(len(saved["entries"]), 2)

    def test_missing_image_reports_error_not_success(self):
        self.seed([self.entry(1, str(self.home / "missing.png"), "image")])
        self.start()
        self.wait_for(lambda m: m["type"] == "entries")
        self.send("select-entry-id:1")
        failure = self.wait_for(lambda m: m["type"] in ("error", "select-success"))
        self.assertEqual(failure["type"], "error")
        self.assertEqual(failure["source"], "restore")
        self.assertIn("missing", failure["message"])
        self.quit()

    def test_file_selection_is_recaptured_as_alias_without_false_error(self):
        (self.home / "teachers.csv").write_text("test file\n")
        self.start("file")
        first = self.wait_for(lambda m: m["type"] in ("entries", "error"))
        self.assertEqual(first["type"], "entries")
        entry = first["data"][0]
        self.assertEqual(entry["type"], "file")
        self.send(f"select-entry-id:{entry['id']}")
        selected = self.wait_for(lambda m: m["type"] in ("select-success", "error"))
        self.assertEqual(selected["type"], "select-success")
        self.quit()

        # The restored clipboard advertises alias, not Finder's file URL.
        self.start("file")
        recaptured = self.wait_for(lambda m: m["type"] in ("entries", "error"))
        self.assertEqual(recaptured["type"], "entries")
        self.assertEqual(len(recaptured["data"]), 1)
        self.assertEqual(recaptured["data"][0]["id"], entry["id"])
        self.assertTrue(recaptured["data"][0]["isCurrent"])
        self.quit()

    def test_capture_warning_resolves_after_successful_retry(self):
        failure_flag = self.home / "fail-capture"
        failure_flag.touch()
        self.start()
        failure = self.wait_for(lambda m: m["type"] == "error")
        self.assertEqual(failure["source"], "capture")
        self.assertIn("capture", failure["message"])
        failure_flag.unlink()
        recovered = self.wait_for(lambda m: m["type"] == "error-resolved")
        self.assertEqual(recovered["source"], "capture")
        self.assertTrue(any(m["type"] == "entries" for m in self.messages))
        self.quit()

    def test_corrupt_history_is_preserved_and_reported(self):
        damaged = b'{"entries": broken'
        self.history.write_bytes(damaged)
        self.start()
        failure = self.wait_for(lambda m: m["type"] == "error")
        self.assertIn("preserved", failure["message"])
        self.wait_for(lambda m: m["type"] == "entries")
        self.quit()
        backups = list(self.home.glob(".clipz_history.json.corrupt*"))
        self.assertTrue(backups)
        self.assertEqual(backups[0].read_bytes(), damaged)
        self.assertEqual(json.loads(self.history.read_text())["version"], 4)

    def check_image_capture(self, image_format, extension, signature):
        self.start(image_format)
        entries = self.wait_for(lambda m: m["type"] == "entries" and len(m["data"]) > 0)
        entry = entries["data"][0]
        self.assertEqual(entry["type"], "image")
        path = Path(entry["content"])
        self.assertEqual(path.parent, self.home / "Library/Application Support/Clipz/images")
        self.assertEqual(path.suffix, extension)
        self.assertTrue(path.read_bytes().startswith(signature))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.quit()
        self.assertEqual(json.loads(self.history.read_text())["entries"][0]["content"], str(path))

        # Startup recaptures identical bytes into a fresh file. Dedup must reuse
        # the existing ID and delete only the new, unreferenced capture.
        self.start(image_format)
        reloaded = self.wait_for(
            lambda m: m["type"] == "entries" and any(e["isCurrent"] for e in m["data"])
        )
        self.assertEqual(len(reloaded["data"]), 1)
        self.assertEqual(reloaded["data"][0]["id"], entry["id"])
        self.assertEqual(reloaded["data"][0]["content"], str(path))
        self.quit()
        self.assertEqual(list(path.parent.iterdir()), [path])

    def test_png_capture_is_durable_and_deduplicates_on_restart(self):
        self.check_image_capture("PNG", ".png", b"\x89PNG\r\n\x1a\n")

    def test_jpeg_capture_preserves_encoding(self):
        self.check_image_capture("JPEG", ".jpg", b"\xff\xd8\xff")

    def test_tiff_capture_preserves_encoding(self):
        self.check_image_capture("TIFF", ".tiff", b"II\x2a\x00")


if __name__ == "__main__":
    unittest.main()
