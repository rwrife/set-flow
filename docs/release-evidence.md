# Internal TestFlight release evidence

## Reproduction

1. Merge the packaging PR only after its exact-head Pinned iOS CI passes.
2. Wait for Pinned iOS CI to pass on the exact merged main SHA. This runs the
   domain/integration tests, built-app identity guard, and all critical UI journeys.
3. Create a release-candidate tag at that validated SHA and push it; the tag
   push runs Release with upload enabled. Alternatively dispatch on a branch
   or tag known to point to the validated SHA (`gh workflow run release.yml
   --ref <tag>`). `-f upload=false` performs archive/export only.
4. Require archive/signature/metadata checks, export/upload success, and an ASC
   build with the exact attempt-specific build number and `processingState=VALID`.
5. Record the `release-evidence` artifact, run URL, source SHA, ASC app/build ID,
   uploaded date and TestFlight URL on issue #7. Only then close issue #7.

The pipeline selects the measured Xcode 26.0.1 / 17A400 / iPhoneOS SDK 26.0
pin using `Scripts/select_xcode.py`. It never substitutes a newer or older Xcode.
The signed archive must have `com.infinityball.setflow`, `UIDeviceFamily=[1]`,
the expected marketing version and `run_number.run_attempt` build number.
Icon validation checks `Assets.car` plus emitted AppIcon rasters, not the
unreliable `CFBundleIconName` key. The privacy manifest must be embedded.

Archive/export logs stay in a mode-600 runner-local temporary file and are
removed; only fixed diagnostic categories and exit codes are emitted. The ASC
key file is mode 600 and removed by an always-run cleanup step. Secret values
are never published in docs or artifacts. No certificates are revoked by CI.
A certificate-slot or provisioning blocker keeps issue #7 open.

## Privacy declarations for App Store Connect

- Data collected: none. Tracking: none. Analytics/crash SDKs: none.
- Workout routines, sessions and notes stay on the iPhone in Application Support.
- JSON/CSV export uses the system document picker only after the user chooses it.
  Files shared elsewhere are readable by their recipients and are not deleted by
  local reset. Restore/replace/reset require deliberate user confirmation.
- No account, cloud sync, or app-originated network calls. The CI upload/poller
  is release tooling, not part of the app binary.
- No notification, camera, microphone, location, contacts or Health permission
  is requested by the current app. Rest timing is in-app only.
- Non-clinical everyday training logging; no diagnosis, treatment or advice.
- No native tablet support or other mobile platform work is part of this release.
- GRDB's bundled privacy manifest supplies declarations for its SQLite-related
  required-reason APIs; the app adds no required-reason API usage of its own.

## Evidence status

Packaging sources and testable release guards are added by this slice. The
Linux host cannot archive or launch an iPhone simulator; source checks are not
native release proof. Fresh native, signing, upload, processing and release SHA
facts belong in the issue/PR comments and workflow artifacts once actually run.
Physical-device and manual VoiceOver evidence is not claimed.

## Icon sources

Generated on Halo using FLUX.2 through halo-media. Editable generation metadata
and source image remain under `/home/rwrife/media/set-flow/`; the app catalog
contains the opaque RGB 1024-pixel PNG used by actool.
