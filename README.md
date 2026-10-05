# Set Flow

Local-first iPhone workout circuit runner with deterministic set queues, large rest-timer controls, and private progress logs for everyday training.

## Motivation
Many workout apps are overloaded with subscriptions, social feeds, and cloud lock-in. Set Flow focuses on one job: run a strength session cleanly with fast controls, clear timing, and private records you own.

## Target users
- People training with simple routines (bodyweight, dumbbells, barbells, kettlebells, bands)
- Lifters who want local logs and exportable history
- Users who need high-contrast, glove/sweaty-hand friendly controls

## Concrete use cases
- Build a 3-day routine with ordered exercises and target sets/reps/load notes
- Run a session with a one-tap next-set queue and visible rest timer
- Log left/right asymmetry notes for unilateral movements
- Review weekly volume and completion consistency per exercise
- Export training history to JSON/CSV for backup or analysis

## Intended end-to-end workflow
1. Create one or more routines with exercise cards and ordered set blocks.
2. Start a session and select the active routine.
3. Complete each set via large controls; rest timer starts automatically.
4. Add optional notes (RPE, side asymmetry, pain-free range comments).
5. Finish the session and view derived summaries.
6. Export backup when needed; restore on the same or a new device.

## MVP feature list
- Routine builder with deterministic set ordering
- Session runner with persistent queue and large controls
- Rest timer with haptic/audio options
- Local exercise/session log with versioned schema
- Per-exercise weekly volume + adherence summary
- JSON backup/restore and CSV export
- Accessibility-first UI baseline (Dynamic Type, VoiceOver labels, contrast)
- Future iPhone Duo seam (`SessionWorkspaceLayout`) documented for dual-screen migration

## Non-goals (MVP)
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity
- No Android app
- No native iPad app (iPhone compatibility mode only unless explicitly requested later)
- No social feed, leaderboards, or cloud account system
- No camera-based form analysis or medical/clinical recommendations
- No wearable-sync dependency for core logging

## Platform and implementation contract
- Native Swift app (SwiftUI/UIKit) only.
- iPhone-only scope.
- `TARGETED_DEVICE_FAMILY = 1` in all app-target configurations.
- iOS SDK requirement: iOS 26 or newer.
- Bundle identifier: `com.infinityball.setflow`.
- App Store Connect bundle registration status: `CREATED com.infinityball.setflow`.

## iPhone Duo design target and migration path
Current build shape is a standard iPhone app with native iPad support disabled by default. Dual-screen APIs are not required for MVP. When Apple ships stable dual-screen APIs, migrate `SessionWorkspaceLayout` so one pane can remain a persistent timer/control surface while the second pane shows exercise detail/history without losing session state.

## Privacy, permissions, and data storage
- Local-first by default; no account required.
- Primary data store is on-device only.
- Export/backup is user-initiated.
- Notification permission is not requested in the current app; the rest timer is in-app only. No location, contacts, camera, microphone or Health access.
- Health/wellness boundary: this app logs workouts only; it does not diagnose, treat, or provide medical advice.
- Data & Privacy (home navigation) uses the system document picker for user-initiated JSON backup, restore and CSV export; no account or network sync. A backup/export sent elsewhere is readable by its recipient. Local workout data remains in Application Support until explicitly reset or the app is removed.

## Portable data contract
- Backup JSON v2 (current) and v1 (previous) are supported. Sorted JSON keys, lowercase UUIDs, timestamps in integer Unix **milliseconds**, load in integer **thousandths** with `kilograms`/`pounds` unit. V1 entries lacking `kind` decode as completed; v1 does not include timer anchors. V2 preserves rest-timer anchors. Unsupported versions and broken references are rejected before writing.
- Restore previews counts of new, existing and conflicting **records** (exercise, routine, session, entry, timer; blocks live inside routines). Add refuses matching IDs; Replace deletes all current workouts before importing the archive, in one SQLite transaction. The preview expires if local data changes. Always keep a separate backup before replacing.
- CSV export generates two separate UTF-8 files with CRLF rows. Sessions columns: `session_id,routine_id,started_at_ms,completed_at_ms,abandoned_at_ms,note`. Sets columns: `entry_id,session_id,exercise_id,block_id,sequence,kind,completed_at_ms,repetitions,load_thousandths,load_unit,side,asymmetry_note`. Empty fields mean not recorded; time and load units do not depend on device locale. Text is quoted and leading spreadsheet formula characters are prefixed with an apostrophe.
- Delete all local data is an independently confirmed destructive action; it removes exercises, routines, recorded sessions/entries and timer anchors. Files you previously exported outside the app are **not** deleted by the app.

## Signing, TestFlight, and App Store release plan
- GitHub Actions secrets configured by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`.
- Planned CI/release path: build with iOS 26+ SDK, archive/sign with App Store Connect API key flow, upload to TestFlight, and gate release on real device/simulator evidence.
- `ASC_TEAM_ID` is the App Store Connect team identifier used for signing/provisioning selection.

## Current status
Native iPhone foundation, the local domain layer, the deterministic session runtime, the accessible routine editor + session runner UI, and private history with explainable summaries are implemented: a SwiftUI app target, shared Xcode scheme, `SetFlowKit` models, GRDB/SQLite routine CRUD, append-oriented session logging with durable abandonment and undo, the pure deterministic set-queue engine, an anchor-based durable rest timer with monotonic persistence, versioned migration fixtures, a routine editor with large controls and reordering, a session runner exposing current exercise, target, logged result, next-set preview, and the durable rest timer (VoiceOver labels/values, Dynamic Type-friendly system fonts, large touch targets), the documented `SessionWorkspaceLayout` iPhone Duo design seam, a History screen deriving weekly volume, completion consistency, session completion, and side-specific (never diagnostic) facts from documented formulas with on-screen explanations and timezone/DST-safe week grouping, launch + full-session-loop + history-journey UI tests, and pinned Linux/macOS CI lanes. JSON backup/restore with validation and preview, CSV exports, confirmed reset and privacy settings are implemented and covered by package tests; issue #7 tracks native release/packaging evidence.

The app remains local-first and zero-network. CI enforces the exact `com.infinityball.setflow` bundle ID, iPhone-only family `1`, disabled native iPad support, iOS 26+ SDK floor, and absence of cross-platform framework manifests.

## Milestones (high level)
1. Foundation + CI skeleton + contract checks
2. Routine/session domain + persistence
3. Session runner + rest timer + logging UX
4. Analytics summaries + export/backup
5. Accessibility hardening + TestFlight packaging evidence

## Development quickstart
```bash
git clone https://github.com/rwrife/set-flow.git
cd set-flow

# Pure domain package (works on Linux/macOS with Swift 6.2)
swift test --package-path Packages/SetFlowKit

# Local policy gates
python3 -m unittest discover -s Scripts/tests -v
bash scripts/check_zero_network.sh
bash scripts/check_native_only.sh

# Native simulator build and launch test (macOS, pinned Xcode 26.0.1 / 17A400)
SIMULATOR_UDID="<available iPhone simulator UDID for iOS 26.0>"
xcodebuild build \
  -project SetFlow.xcodeproj \
  -scheme SetFlow \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test \
  -project SetFlow.xcodeproj \
  -scheme SetFlow \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

CI runs the native commands through `Scripts/ci.sh`, first measuring the exact pinned Xcode version, build, and SDK. Linux structural checks do not substitute for the macOS build, built-app `UIDeviceFamily == [1]` check, or launch XCUITest.