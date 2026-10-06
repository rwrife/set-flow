#!/usr/bin/env python3
"""Contain xcodebuild signing logs on the runner; emit only fixed categories.

Xcode may echo fragments of private keys or provisioning data. Never publish
raw archive/export logs in job output or artifacts. This wrapper captures to a
mode-600 temporary file, maps known errors to fixed labels and deletes it.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

CATEGORIES = (
    ("maximum number of certificates", "certificate_limit"),
    ("No profiles for", "provisioning_profile_missing"),
    ("No signing certificate", "signing_certificate_missing"),
    ("failed to upload", "upload_failure"),
    ("error: ", "build_or_export_error"),
    ("** ARCHIVE SUCCEEDED **", "archive_succeeded"),
    ("** EXPORT SUCCEEDED **", "export_succeeded"),
)


def capture(command: list[str], summary: Path) -> int:
    fd, path = tempfile.mkstemp(prefix="setflow-signing-", dir=os.environ.get("RUNNER_TEMP"))
    try:
        with os.fdopen(fd, "wb") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=False)
        data = Path(path).read_bytes().decode("utf-8", errors="replace")
        labels = sorted({label for text, label in CATEGORIES if text.lower() in data.lower()})
        if result.returncode != 0 and not labels:
            labels = ["unknown_failure"]
        summary.write_text(json.dumps({"exit_code": result.returncode, "categories": labels}, sort_keys=True) + "\n")
        print(f"signing_capture exit={result.returncode} categories={','.join(labels) or 'none'}")
        return result.returncode
    finally:
        Path(path).unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        raise SystemExit("usage: signing_capture.py <summary.json> -- <command> [args...]")
    raise SystemExit(capture(sys.argv[3:], Path(sys.argv[1])))
