# Issue #1 bootstrap evidence

Dated record of what was actually verified, where, and what remains CI-only.

## What this bootstrap adds

- `SetFlow.xcodeproj` with the shared `SetFlow` scheme (app + UI-test targets),
  bundle id `com.infinityball.setflow`, `TARGETED_DEVICE_FAMILY = 1` in every
  app-target build configuration, iOS 26.0 deployment target, Swift 6 language
  mode, and no `SUPPORTS_MACCATALYST`/iPad family anywhere in the project.
- `App/`: SwiftUI launch-only placeholder (`SetFlowApp` + `BootstrapHomeView`)
  wired to `Packages/SetFlowKit`.
- `Packages/SetFlowKit`: pure Swift 6 package (Foundation only) with
  swift-testing placeholder tests proving the Linux lane works.
- `UITests/SetFlowLaunchTests.swift`: simulator launch smoke test asserting the
  `bootstrap.home` accessibility identifier and home-screen copy.
- `Scripts/`: pinned toolchain selection (measured version/build/SDK match plus
  the platform-contract assertions), simulator selection/boot helpers with
  bounded subprocess timeouts and a bounded one-shot retry for known
  hosted-runner boot/enumeration wedges, and the CI entrypoint `Scripts/ci.sh`
  (phase-tracked provenance on every exit).
- `scripts/check_zero_network.sh`: empty-allowlist scan of `App/`, `UITests/`,
  and `Packages/*/Sources/` for network APIs (`.build` dirs excluded).
- `scripts/check_native_only.sh`: rejection gate for Flutter, React Native,
  Expo, Kotlin Multiplatform, .NET MAUI, and Unity manifests/fingerprints.
- `.github/workflows/ci.yml`: Linux package job (`swift:6.2-noble`) plus a
  macOS job with exact-head checkout, pinned-toolchain validation, and
  always-upload artifacts.

## Toolchain and platform contract enforcement

`toolchain.json` pins Xcode 26.0.1 (17A400) / iPhoneOS SDK 26.0 / Swift 6 mode /
deployment target 26.0, with `bundle_identifier = com.infinityball.setflow`,
`targeted_device_family = "1"`, and `native_ipad_support = false`, exactly as
the README and PLAN require.

`Scripts/select_xcode.py` validates the schema and those policy values before
selecting anything, then measures `xcodebuild -version` and
`xcrun --sdk iphoneos --show-sdk-version` for every installation under
`/Applications` and only accepts an actual version/build/SDK match; a missing
pin is a hard CI failure (`PinError`), never a silent fallback or a relaxed
prefix match. The workflow checks out
`github.event.pull_request.head.sha` explicitly, so CI tests the exact PR head
commit, not a synthetic merge ref.

`Scripts/ci.sh` adds an explicit `toolchain_contract` phase that parses
`toolchain.json` and asserts `bundle_identifier == com.infinityball.setflow`,
`targeted_device_family == "1"`, `native_ipad_support is False`, and
`minimum_sdk_major >= 26`. The Linux job runs the same assertions.

## iPhone-only, zero-network, and native-only enforcement

`Scripts/ci.sh` enforces iPhone-only policy twice: an `iphone_only_pregrep`
phase fails before compiling unless every `TARGETED_DEVICE_FAMILY` setting in
`SetFlow.xcodeproj` is exactly `1` (any `1,2` or `2` fails), and after the build
the `device_family_guard` phase converts the built `SetFlow.app/Info.plist` to
JSON and fails unless `UIDeviceFamily == [1]` and the built
`CFBundleIdentifier == com.infinityball.setflow`; the JSON is uploaded as
`app-info.json`.

The zero-network gate scans app sources, UI tests, and package sources against
an explicit EMPTY allowlist; any match on URLSession/Network.framework/CFNetwork/
POSIX socket vocabulary fails the run. The native-only gate rejects prohibited
cross-platform manifests and framework fingerprints in both CI lanes. A
signing-material gitignore probe asserts `*.p8`, `*.p12`, `*.mobileprovision`,
and `*.cer` cannot be committed.

All simulator subprocesses are bounded (30 s enumeration, 120 s boot, 180 s
bootstatus) with logs preserved in `build/ci-artifacts`, and the workflow uploads
artifacts with `if: always()` so failures keep their provenance
(`provenance.txt` records expected/actual SHA, phase, and exit status).

## Verification actually performed (Linux executor, no Swift/Xcode on host)

- `python3 -m unittest discover -s Scripts/tests` — 26 tests pass locally:
  bounded boot/timeout/exit-code behavior, simulator selection, exact Xcode pin
  selection, and the new bundle-ID / device-family / iPad-support / SDK-floor
  contract tests.
- `swift test` for `Packages/SetFlowKit` executed for real inside Docker
  (`swift:6.2-noble`), matching the CI Linux job image exactly.
- `bash -n Scripts/ci.sh`, `scripts/check_zero_network.sh`, and
  `scripts/check_native_only.sh` — syntax OK; all three gates run against the
  ported tree and PASS.
- pbxproj object-ID closure probe (defined == referenced, all 24-hex) — clean;
  `TARGETED_DEVICE_FAMILY = 1;` present in all four target configurations with
  zero iPad variants, and `com.infinityball.setflow` in both app configurations.
- Workflow YAML and `toolchain.json` parse; `git diff --check` clean.

## CI-pending claims (NOT claimed from this host)

The macOS Xcode/SDK pin measurement, simulator build, launch XCUITest, embedded
`Info.plist` `UIDeviceFamily == [1]` check, and built-app bundle-id check are
**CI-pending**: the authoritative evidence is the macOS CI run for this PR's
exact head SHA, retained in the `ios-ci-<sha>` artifact. Results are recorded on
the PR when they exist, never pre-declared.

## Explicit non-claims

- No physical-device, VoiceOver, or signed-archive evidence exists or is claimed.
- No TestFlight/upload path exists (issue #7 owns that).
- The simulator test proves launch + home-screen rendering only; product
  journeys arrive with issues #2–#6.
- Hosted `simctl` startup has known transient hangs; a red CI run at a proven
  unchanged tree is retried once before being reported as an environment blocker.
