# Set Flow — Implementation Plan

## Scope
Set Flow is a native Swift iPhone-only workout circuit runner and logger. MVP scope is deterministic routine execution, rest timing, local history, and export/backup. No account system, no cloud dependency, no clinical claims.

## Architecture
- **App shell:** SwiftUI-first, UIKit interop only where needed.
- **Domain module (`SetFlowKit` planned):**
  - Entities: `Routine`, `Exercise`, `SetBlock`, `Session`, `SetEntry`, `TimerState`, `SessionNote`
  - Deterministic queue engine for next actionable set
  - Derived metrics (weekly volume, completion rate, elapsed-rest variance)
- **Persistence:** GRDB/SQLite with versioned migrations and deterministic fixture data.
- **Backup/export:**
  - JSON full snapshot (versioned)
  - CSV event export for external analysis
- **UI layers:**
  - Routine editor
  - Session runner (large touch targets)
  - History + summaries
  - Settings/privacy/export
- **Future dual-screen seam:** `SessionWorkspaceLayout` contract preserving session continuity across fold/unfold states once native APIs are available.

## Technology choices and rationale
- **Swift + SwiftUI/UIKit (native only):** matches policy and iOS platform integration.
- **iOS 26+ SDK pin:** explicit modern toolchain contract and deterministic CI gating.
- **SQLite/GRDB local store:** reliable offline data ownership, migration support, queryable summaries.
- **JSON/CSV export:** user-controlled portability and backup recovery.

## Platform contract (must stay true)
- Native Swift implementation only.
- iPhone-only target (`TARGETED_DEVICE_FAMILY = 1`), no native iPad support unless explicitly requested later.
- Android out of scope.
- Bundle ID prefix must remain `com.infinityball.`; this repo uses `com.infinityball.setflow`.
- CI/release path must use iOS 26+ SDK.

## Milestones and dependency order
1. **Scaffold guardrails**
   - Add app skeleton and CI contract checks for toolchain and device-family invariants.
2. **Core data/domain**
   - Implement schema + migrations + repository interfaces.
3. **Session execution loop**
   - Routine loader, deterministic set queue, rest timer lifecycle, set completion writes.
4. **History + summaries**
   - Weekly volume, completion consistency, per-exercise timeline.
5. **Export/restore + privacy controls**
   - JSON backup/restore with preview, CSV export, local-data reset.
6. **Accessibility + release hardening**
   - VoiceOver labels, Dynamic Type coverage, contrast review, TestFlight upload path.

## Testing strategy
- **Unit tests:** queue engine, derivation math, migration safety, export codecs.
- **Integration tests:** session runner state transitions and persistence round-trips.
- **UI tests:** critical journey (start session, complete set, timer cycle, finish session).
- **Contract checks:**
  - Parse `toolchain.json` in CI.
  - Enforce `bundle_identifier == com.infinityball.setflow`.
  - Enforce `targeted_device_family == "1"` and `native_ipad_support == false`.
  - Enforce iOS SDK major >= 26.

## Packaging and distribution plan
- Build and sign with App Store Connect API key workflow using secrets named:
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`.
- Internal TestFlight first, then staged production release.
- Release evidence must include real archive/upload logs and build metadata.

## Risks
- Scope creep toward social/coaching features.
- Timer UX regressions under background/foreground transitions.
- Migration breakage if schema evolves without fixture regression tests.
- Accessibility regressions from dense session controls.

## Explicit non-goals
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity.
- No Android target.
- No native iPad support by default.
- No cloud accounts/subscriptions as MVP dependency.
- No camera/motion AI form scoring.
- No diagnosis, treatment, or medical advice features.