import datetime as dt
from typing import Any, Dict, List, Optional


def check_contract(pins: Dict[str, Any]) -> None:
    if pins.get("bundle_identifier") != "com.infinityball.setflow":
        raise ValueError(f"Unexpected bundle_identifier: {pins.get('bundle_identifier')}")
    if str(pins.get("targeted_device_family")) != "1":
        raise ValueError(f"Unexpected targeted_device_family: {pins.get('targeted_device_family')}")
    if pins.get("native_ipad_support") is not False:
        raise ValueError(f"native_ipad_support must be false: {pins.get('native_ipad_support')}")
    min_sdk = pins.get("minimum_sdk_major")
    if not isinstance(min_sdk, int) or min_sdk < 26:
        raise ValueError(f"minimum_sdk_major must be int >= 26: {min_sdk}")


def check_archive(info: Dict[str, Any], expected_build: str, expected_version: str) -> None:
    family = info.get("UIDeviceFamily")
    if family != [1]:
        raise ValueError(f"Archive UIDeviceFamily must be [1], got {family!r}")
    bid = info.get("CFBundleIdentifier")
    if bid != "com.infinityball.setflow":
        raise ValueError(f"Archive CFBundleIdentifier must be com.infinityball.setflow, got {bid!r}")
    build = info.get("CFBundleVersion")
    if build != expected_build:
        raise ValueError(f"Archive CFBundleVersion must be {expected_build}, got {build!r}")
    ver = info.get("CFBundleShortVersionString")
    if ver != expected_version:
        raise ValueError(f"Archive CFBundleShortVersionString must be {expected_version}, got {ver!r}")


def parse_asc_date(date_str: str) -> dt.datetime:
    clean = date_str.replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(clean)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def select_processed(builds: List[Dict[str, Any]], expected_version: str, start_time: dt.datetime) -> Optional[Dict[str, Any]]:
    for b in builds:
        attrs = b.get("attributes", {})
        if attrs.get("version") != expected_version:
            continue
        uploaded = attrs.get("uploadedDate")
        if not uploaded:
            continue
        try:
            uploaded_dt = parse_asc_date(uploaded)
        except Exception:
            continue
        if uploaded_dt < start_time:
            continue
        state = attrs.get("processingState")
        if state == "VALID":
            return b
        if state == "PROCESSING":
            return None
        raise ValueError(f"Terminal failed processing state: {state}")
    return None


def privacy_report() -> Dict[str, Any]:
    return {
        "network_allowlist": [],
        "requested_permissions": [],
        "data_storage": "on-device; user-initiated file export",
        "medical_claims": "none (everyday strength log only)",
        "diagnostics": "none; zero telemetry; zero external analytics",
    }
