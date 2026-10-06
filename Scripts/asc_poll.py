import datetime as dt
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import jwt
import release_evidence

start_time = release_evidence.parse_asc_date(Path("build/upload-started.txt").read_text().strip())
p8_path = Path(os.environ["WV_P8_PATH"])
key_id = os.environ["WV_KEY_ID"]
issuer_id = os.environ["WV_ISSUER_ID"]
bundle_id = os.environ["WV_BUNDLE_ID"]
wanted_version = os.environ["WV_BUILD_NUMBER"]

key_bytes = p8_path.read_text(encoding="utf-8")


def auth_token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "aud": "appstoreconnect-v1", "iat": now, "exp": now + 600},
        key_bytes,
        algorithm="ES256",
        headers={"kid": key_id},
    )


def asc_get(path: str) -> dict:
    url = "https://api.appstoreconnect.apple.com" + path
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + auth_token()})
    with urllib.request.urlopen(request, timeout=30) as resp:
        return json.load(resp)


print(f"Querying App Store Connect for bundle {bundle_id}...")
apps_payload = asc_get(f"/v1/apps?filter[bundleId]={bundle_id}")
apps = apps_payload.get("data", [])
if not apps:
    sys.exit(f"No App Store Connect app record found for bundle identifier {bundle_id}")
app_id = apps[0]["id"]
print(f"App Store Connect app ID: {app_id}")

deadline = time.time() + 20 * 60
poll_interval = 30

while time.time() < deadline:
    query = f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=15"
    payload = asc_get(query)
    builds = payload.get("data", [])
    selected = release_evidence.select_processed(builds, wanted_version, start_time)
    if selected is not None:
        build_id = selected["id"]
        attrs = selected.get("attributes", {})
        state = attrs.get("processingState")
        uploaded = attrs.get("uploadedDate")
        print("=== TestFlight Build Processed Successfully ===")
        print(f"Build ID: {build_id}")
        print(f"App ID: {app_id}")
        print(f"Version/Build: {wanted_version}")
        print(f"Uploaded Date: {uploaded}")
        print(f"Processing State: {state}")
        url = f"https://appstoreconnect.apple.com/apps/{app_id}/testflight/ios"
        print(f"TestFlight URL: {url}")
        evidence = {"app_id": app_id, "build_id": build_id,
                    "build_number": wanted_version, "processing_state": state,
                    "uploaded_date": uploaded, "testflight_url": url,
                    "source_sha": os.environ["GITHUB_SHA"],
                    "run_id": os.environ["GITHUB_RUN_ID"],
                    "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"]}
        Path("build/testflight.json").write_text(json.dumps(evidence, indent=2) + "\n")
        sys.exit(0)
    print(f"Waiting for build {wanted_version} to finish processing... sleeping {poll_interval}s")
    time.sleep(poll_interval)

sys.exit(f"Timed out after 20 minutes waiting for build {wanted_version} to process")
