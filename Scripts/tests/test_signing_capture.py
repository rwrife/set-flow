import tempfile
import unittest
from pathlib import Path
from Scripts import signing_capture


class SigningCaptureTests(unittest.TestCase):
    def test_raw_output_never_leaves_runner_capture(self):
        with tempfile.TemporaryDirectory() as root:
            summary = Path(root) / "summary.json"
            command = ["python3", "-c", "print('SECRET-PARTIAL error: your account has reached the maximum number of certificates'); raise SystemExit(65)"]
            code = signing_capture.capture(command, summary)
            self.assertEqual(code, 65)
            self.assertNotIn("SECRET", summary.read_text())
            self.assertIn("certificate_limit", summary.read_text())
            self.assertEqual(list(Path(root).iterdir()), [summary])

    def test_success_exit_and_summary(self):
        with tempfile.TemporaryDirectory() as root:
            summary = Path(root) / "summary.json"
            self.assertEqual(signing_capture.capture(["python3", "-c", "print('private text')"], summary), 0)
            self.assertNotIn("private text", summary.read_text())
