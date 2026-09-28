import json
import tempfile
import unittest
from pathlib import Path

from Scripts.select_xcode import PinError, load_pins, select_xcode


VALID = {
    "xcode_version": "26.0.1",
    "xcode_build": "17A400",
    "iphoneos_sdk": "26.0",
    "minimum_sdk_major": 26,
    "deployment_target": "26.0",
    "swift_language_mode": "6",
    "bundle_identifier": "com.infinityball.setflow",
    "targeted_device_family": "1",
    "native_ipad_support": False,
}


class PinTests(unittest.TestCase):
    def write_pins(self, value):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "toolchain.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        self.addCleanup(directory.cleanup)
        return path

    def test_rejects_missing_pin(self):
        pins = dict(VALID)
        del pins["xcode_build"]
        with self.assertRaisesRegex(PinError, "xcode_build"):
            load_pins(self.write_pins(pins))

    def test_rejects_bad_pin_type(self):
        pins = dict(VALID, minimum_sdk_major="26")
        with self.assertRaisesRegex(PinError, "minimum_sdk_major"):
            load_pins(self.write_pins(pins))

    def test_rejects_sdk_below_supported_major(self):
        pins = dict(VALID, iphoneos_sdk="25.4")
        with self.assertRaisesRegex(PinError, "below minimum"):
            load_pins(self.write_pins(pins))

    def test_selects_only_exact_actual_versions(self):
        installations = {
            Path("/Applications/Xcode_26.0.app"): ("26.0", "17A300", "26.0"),
            Path("/Applications/Xcode_26.0.1.app"): ("26.0.1", "17A400", "26.0"),
        }
        selected = select_xcode(VALID, installations)
        self.assertEqual(selected, Path("/Applications/Xcode_26.0.1.app"))

    def test_multiple_exact_installations_choose_deterministically(self):
        installations = {
            Path("/Applications/Xcode_26.0.app"): ("26.0.1", "17A400", "26.0"),
            Path("/Applications/Xcode.app"): ("26.0.1", "17A400", "26.0"),
        }
        self.assertEqual(select_xcode(VALID, installations), Path("/Applications/Xcode.app"))

    def test_rejects_matching_name_with_wrong_actual_build(self):
        installations = {
            Path("/Applications/Xcode_26.0.1.app"): ("26.0.1", "17A401", "26.0")
        }
        with self.assertRaisesRegex(PinError, "No installed Xcode"):
            select_xcode(VALID, installations)

    def test_rejects_foreign_bundle_identifier(self):
        pins = dict(VALID, bundle_identifier="com.example.other")
        with self.assertRaisesRegex(PinError, "bundle_identifier"):
            load_pins(self.write_pins(pins))

    def test_rejects_ipad_device_family(self):
        pins = dict(VALID, targeted_device_family="1,2")
        with self.assertRaisesRegex(PinError, "targeted_device_family"):
            load_pins(self.write_pins(pins))

    def test_rejects_native_ipad_support(self):
        pins = dict(VALID, native_ipad_support=True)
        with self.assertRaisesRegex(PinError, "native_ipad_support"):
            load_pins(self.write_pins(pins))

    def test_rejects_bundle_id_prefix_drift(self):
        pins = dict(VALID, bundle_identifier="com.infinitybal.setflow")
        with self.assertRaisesRegex(PinError, "bundle_identifier"):
            load_pins(self.write_pins(pins))

    def test_accepts_the_repository_toolchain_file(self):
        repo_pins = Path(__file__).resolve().parents[2] / "toolchain.json"
        pins = load_pins(repo_pins)
        self.assertEqual(pins["bundle_identifier"], "com.infinityball.setflow")
        self.assertEqual(pins["targeted_device_family"], "1")
        self.assertIs(pins["native_ipad_support"], False)
        self.assertGreaterEqual(pins["minimum_sdk_major"], 26)


if __name__ == "__main__":
    unittest.main()
