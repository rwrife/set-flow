import datetime as dt
import json
import plistlib
import unittest
from unittest.mock import patch

from Scripts import release_evidence


class ReleaseEvidenceTests(unittest.TestCase):
    def test_contract_rejects_wrong_family_and_bundle(self):
        good = {"bundle_identifier": "com.infinityball.setflow",
                "targeted_device_family": "1", "native_ipad_support": False,
                "minimum_sdk_major": 26, "xcode_version": "26.0.1",
                "xcode_build": "17A400", "iphoneos_sdk": "26.0"}
        release_evidence.check_contract(good)
        for key, value in [("bundle_identifier", "com.other.setflow"),
                           ("targeted_device_family", "1,2"),
                           ("native_ipad_support", True), ("minimum_sdk_major", 25)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release_evidence.check_contract({**good, key: value})

    def test_archive_metadata_must_be_iphone_only_exact_bundle_and_build(self):
        valid = {"UIDeviceFamily": [1], "CFBundleIdentifier": "com.infinityball.setflow",
                 "CFBundleVersion": "24.1", "CFBundleShortVersionString": "0.1.0"}
        release_evidence.check_archive(valid, "24.1", "0.1.0")
        for key, value in [("UIDeviceFamily", [1, 2]),
                           ("CFBundleIdentifier", "com.other.app"),
                           ("CFBundleVersion", "24.0"),
                           ("CFBundleShortVersionString", "0.2.0")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release_evidence.check_archive({**valid, key: value}, "24.1", "0.1.0")

    def test_processed_build_filters_stale_and_requires_valid(self):
        start = dt.datetime(2026, 10, 6, tzinfo=dt.timezone.utc)
        stale = {"id": "old", "attributes": {"version": "24.1",
                 "processingState": "VALID", "uploadedDate": "2026-10-05T10:00:00Z"}}
        wrong_number = {"id": "wrong", "attributes": {"version": "23.1",
                 "processingState": "VALID", "uploadedDate": "2026-10-06T10:00:00Z"}}
        fresh = {"id": "12345", "attributes": {"version": "24.1",
                 "processingState": "VALID", "uploadedDate": "2026-10-06T10:00:00Z"}}
        self.assertIsNone(release_evidence.select_processed([stale, wrong_number], "24.1", start))
        self.assertEqual(release_evidence.select_processed([stale, wrong_number, fresh], "24.1", start)["id"], "12345")
        for state in ("PROCESSING", "VALID", "FAILED", "INVALID"):
            with self.subTest(state=state):
                candidate = {**fresh, "attributes": {**fresh["attributes"], "processingState": state}}
                if state == "PROCESSING":
                    self.assertIsNone(release_evidence.select_processed([candidate], "24.1", start))
                elif state == "VALID":
                    self.assertEqual(release_evidence.select_processed([candidate], "24.1", start)["id"], "12345")
                else:
                    with self.assertRaises(ValueError):
                        release_evidence.select_processed([candidate], "24.1", start)

    def test_privacy_report_is_static_zero_network_without_sensitive_content(self):
        report = release_evidence.privacy_report()
        self.assertEqual(report["network_allowlist"], [])
        self.assertEqual(report["requested_permissions"], [])
        self.assertEqual(report["data_storage"], "on-device; user-initiated file export")


if __name__ == "__main__":
    unittest.main()
