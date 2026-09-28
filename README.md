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
- Planned permissions: notifications (rest timer alerts). No location, contacts, or microphone required for MVP.
- Health/wellness boundary: this app logs workouts only; it does not diagnose, treat, or provide medical advice.

## Signing, TestFlight, and App Store release plan
- GitHub Actions secrets configured by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`.
- Planned CI/release path: build with iOS 26+ SDK, archive/sign with App Store Connect API key flow, upload to TestFlight, and gate release on real device/simulator evidence.
- `ASC_TEAM_ID` is the App Store Connect team identifier used for signing/provisioning selection.

## Current status
Scaffold phase only. Repository currently contains planning docs, policy contracts, and issue backlog. No Xcode project, app binary, or test suite is claimed yet.

## Milestones (high level)
1. Foundation + CI skeleton + contract checks
2. Routine/session domain + persistence
3. Session runner + rest timer + logging UX
4. Analytics summaries + export/backup
5. Accessibility hardening + TestFlight packaging evidence

## Development quickstart (scaffold stage)
```bash
git clone https://github.com/rwrife/set-flow.git
cd set-flow
# Read README + PLAN + issue backlog, then implement via PR-first issue slices.
```

When app source exists, this section will add concrete `xcodebuild` commands and simulator targets.