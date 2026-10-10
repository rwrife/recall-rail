# Issue #7 candidate evidence

## Current reviewer-fix snapshot (2026-10-10)

The parent supplied committed/pushed candidate `30f15234b5eacb45cb09446c71d58afa7eabfde2` and draft PR #14. This single writer changed only the dedicated issue-7 worktree; no commit, push, PR operation, merge, workflow dispatch, signing or upload was performed during this fix pass. The supplied verdict refers to tree `5b51d3ba3b4137f0e3b2a4368321a798f399202a`; it is reviewer input, not independently executed verification of this snapshot. Prior main CI does not verify this candidate or these staged fixes.

Nested deck/card/session/schedule schemas now reject unknown keys before Decodable can ignore them. IDs retain their actual single-string wire format; unexpected nested ID objects reject. Domain dates accept existing lossless `ref:` bit-pattern strings and legacy epoch numbers without re-encoding raw records, with finite ±1e12 epoch-second bounds. Sort order, recall count, cursor and elapsed milliseconds are bounded to 0...1e9. Decodable enforces UInt64 clock bounds and required fields. Nested attempt schemas/bounds determine readability; malformed attempts remain byte-identical raw corrupt evidence with original flags during private validation/restore. Their grades/timing are never fabricated. The normal attempt read/mastery path applies the same schema and timing validation, preventing private restored unknown fields from becoming readable grades.

Before archive signing, and again immediately before upload, the release script reads all paginated ASC builds for the same marketing version and fails if candidate numeric components are less than or equal to any prior build. Decimal components compare as integers, with trailing zero equivalence. API/authentication/pagination errors fail closed with fixed diagnostics. Archive explicitly requests `CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Distribution"`; existing distribution profile/entitlement checks still apply. Actual ASC/signing behavior remains unexecuted. [Apple documents the marketing-version build filter](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds).

### Legacy privacy blocker is explicitly retained

[Apple reason 35F9.1](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) permits off-device elapsed time between in-app events; it does not permit full boot anchors. Newly constructed attempts/sessions carry `clockProvenance: appOriginElapsedV1`: anchors are elapsed intervals from initialization of the app clock origin to an app event. Missing provenance stays unknown on decode/resume/restore; it is never inferred from small numeric values. Public JSON backup and raw attempt CSV now fail atomically for legacy or unclassifiable records, including corrupt raw attempts whose clock content cannot be proven safe. Deck/card CSV remains available. No stored row is rewritten, dropped or normalized. Previously created files are outside this gate. Ordinary OS-managed device backups remain outside the application export implementation and need Apple assessment.

This deliberately leaves complete-history backup for legacy/corrupt data unavailable. The error explains the gate and preservation policy; deleting history is not a recommended workaround. A version-3 duration-only export would change raw history and restore semantics and has NOT been authorized or implemented. No claim of a resolved complete-history privacy policy or issue completion is made. Apple/privacy acceptance and a safe authorized legacy-history policy remain blockers before distribution.

Ownership export choices now come from a fresh throwing `allDecks(includeArchived: true)` query when the screen opens, with refresh after restore/delete and errors surfaced. Native boundary tests cover archived deck/card contents and closed-store errors; a production-navigation UI test covers reaching the archived deck export sheet. Those native tests have only been parsed here. No generic ancestor accessibility identifiers were added. Linux CI already installs `libssl-dev` for the LinuxSHA C shim; this was verified rather than changed.

### Fix-pass verification

Docker image `recall-rail-issue7-ci`, nonroot UID/GID 1001, container `HOME=/tmp`, container `/tmp` Swift scratch; host HOME was untouched. The hostile nested schema test initially failed with four missed rejections; the legacy clock test initially failed three export assertions; the release-number tests initially failed because the helper did not exist. A first schema implementation incorrectly expected object-shaped IDs, and its failing run was corrected to the actual string representation.

Final exact working-source checks at 2026-10-10 11:28 UTC: RecallStore **74 tests passed**, including **18 ownership tests**; RecallRailKit **77 passed**, both with warnings as errors. Swift frontend parse of app/native/UI sources passed; this is syntax only. Release helper **7 tests passed**; structural/mutation/schema suites **12 passed**. Project contract, zero-network plus self-test, native-only, release shell syntax and diff whitespace checks passed. Concise captured output is in `issue-7-fix-verification.txt`. All fix files are staged for parent review; no commit was created. Parent owns fresh independent review and native CI. Exact-tree Apple UI/build/signing/upload and a matching processed VALID TestFlight build remain pending.

## Historical initial-candidate evidence (superseded where above differs)

This is an uncommitted implementation candidate in the dedicated issue-7 worktree. No commit, push, PR, merge, tag, release dispatch, external annotation, secret lookup, signing, upload, or TestFlight claim was made. Independent parent review and Apple verification remain required.

## Ownership implementation

The deck library’s **Data and privacy** screen offers deck CSV, card CSV for each deck (including archived cards), attempt CSV, and a complete JSON backup using SwiftUI’s system file exporter. Attempt CSV includes raw records, original schema flags, and readable ledger columns; corrupt rows retain their raw text and have empty derived columns. File and store errors are shown. Restore uses the system file importer, checks file size before loading, offers merge/replace counts and preserved-corrupt-evidence counts, and requires an explicit commit confirmation.

JSON envelope versions 1 and 2 contain a base64-encoded JSON payload plus its SHA-256 checksum. The payload includes every application-table column in deck, card, attempt, session and skip, including schedules, archive flags, timestamps, raw record strings and schema flags. Base64 preserves the exact checksummed payload bytes; this is a checksum, not authentication or encryption. Version 1 accepts prior epoch-number dates inside raw domain records; version 2 writes the existing lossless reference-date records. Raw records are never decoded/re-encoded on restore. GRDB migration bookkeeping and SQLite implementation metadata are regenerated by the current migrator, not imported as application data.

Validation rejects unsupported versions, checksum changes, unknown envelope/row/table/column fields, missing tables, duplicate UUIDs (including case variants), invalid IDs, missing/cross-deck references, invalid authoring fields, snapshot disagreement, invalid schedule boxes/versions/counters, missing last-attempt references, readable last-attempt snapshot disagreement, invalid session order/cursor/status, and oversized resources. Bounds are 64 MiB per file, 100,000 rows total, 1 MiB per raw string, 1,000 tags and 1 KiB per tag. Raw corrupt attempt evidence is explicitly preserved, including undecodable records with schema_ok=1 and flagged records that happen to decode. A preview reports this evidence without changing its flag or grade.

Merge accepts new IDs and byte-equivalent existing records only; any changed existing ID, including immutable attempt/skip history, rejects the whole merge. Replace and merge revalidate in the write transaction. A database-content fingerprint plus SQLite total-change and data-version counters prevents a stale preview from committing, including a no-op write or changes reverted to identical content. Replace drops only the evidence DELETE guards inside that transaction, restores them before commit, and retains UPDATE guards and deck-pinning protections. An injected INSERT failure verifies rollback of both records and triggers.

## Local privacy audit

No app account, HTTP client, cloud sync, analytics, tracking, recording, speech recognition, or notification authorization exists. The existing spoken-rehearsal microphone permission button remains explicit and starts no capture. The future Duo layout seam remains simulated and iPhone-only. Data stays in the application-support SQLite database and participates in device backup. The privacy manifest declares no tracking or collected data and reason 35F9.1 for measuring time between app events. The production monotonic source now returns elapsed time from a process-local origin, rather than exporting raw device uptime. Practice resume resets the live timing anchor after relaunch; raw restored records are untouched. Apple permits exported elapsed time between app events under [its required-reason guidance](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). Legacy backups containing old boot-relative anchors remain unchanged to honor raw-record restoration; Apple privacy review must assess that legacy export case before distribution.

The deletion screen requires confirmation, erases all application rows with append-only triggers restored, enables SQLite secure_delete, truncates the WAL and vacuums deleted pages. It does not claim to erase exported files, historic device backups, filesystem snapshots or physical flash copies. Errors during local cleanup are surfaced and the library is refreshed. Deleting a card/deck with evidence remains restricted; archive preserves history.

The zero-network gate checks first-party Swift/C/Objective-C sources, source entitlements, package manifests/locks and Xcode remote-package declarations. GRDB 7.11.1 at the existing pinned revision is the sole remote dependency. Apple SHA-256 uses CryptoKit; Linux uses an OpenSSL C shim excluded from Apple package targets. No swift-crypto or iPhone network dependency was added. Mutation tests cover forbidden network/recording/notification APIs and dependency/entitlement additions. This is a structural policy check, not a proof against obfuscated code or arbitrary runtime behavior.

## Release candidate

The TestFlight workflow runs only after successful main push CI, consumes the successful run’s exact-SHA Apple artifact, checks passed test summary, built bundle/family and toolchain evidence, and checks out that SHA. The release script checks toolchain.json’s Xcode 26.0.1 / 17A400 / SDK 26.0, archives the native iPhone target, verifies signature, exact bundle, family [1], built SDK, build number, signing entitlements and distribution provisioning profile, then uses xcodebuild -exportArchive with app-store-connect and destination upload.

Only ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 and ASC_TEAM_ID signing secret names are referenced. Build numbers are github.run_number.github.run_attempt. Keys, export options, archive, raw tool output and temporary distribution output stay in a mode-0700 ephemeral directory cleaned by an EXIT trap; shell tracing is disabled. Artifacts contain fixed category/count sanitization, public toolchain/SHA/build facts, and the processed build ID, never raw signing output or identity values. Sanitizer tests include partial-key/issuer/team canaries and unknown output. The poller matches bundle, exact build number and upload time, waits at most 20 minutes, requires processingState VALID, rejects FAILED/INVALID and records the matching build ID. Tests demonstrate that COMPLETE, stale uploads and different build numbers do not pass.

The opaque 1024×1024 RGB PNG app icon is deterministically generated with Python stdlib struct/zlib; its PNG CRCs, dimensions and RGB-without-alpha format are tested. No media model was used.

## Executed local verification

Docker uses a derivative of swift:6.2-noble with libsqlite3-dev/libssl-dev/python3, runs as --user 1001:1001 with HOME=/tmp and keeps Swift build scratch under container /tmp. Host Swift is unavailable. GRDB package resolution and a read-only Apple privacy-documentation lookup used development network access; the app has no runtime network implementation. No host HOME was exported. The first git safety configuration attempt found the worktree’s external git metadata unavailable inside the mount; Swift package tests were unaffected.

Candidate base commit: `4f0c365039a90e0d3cb2079c6598151e006a95bc`. Executed on 2026-10-10; the working-tree changes remain uncommitted.

- `swift test --package-path Packages/RecallStore --scratch-path /tmp/issue7-store -Xswiftc -warnings-as-errors`: **70 tests passed, 0 failures**, including 14 ownership tests. The final store run after the production-clock change finished at 11:06:13 UTC. Its log is `packages-final.log` (previous runs are retained in `store-final.log`).
- `swift test --package-path Packages/RecallRailKit --scratch-path /tmp/issue7-kit -Xswiftc -warnings-as-errors`: **77 tests passed, 0 failures**. Log: `packages-final.log`, rerun after the production-clock change. The earlier `recall-issue7-tests.log` is also retained.
- Project contract, native-only gate/self-test, zero-network source/entitlement/dependency gate: **PASS**.
- Structural Python suites: practice workspace **5**, zero-network mutation checks **3**, ownership/UI/icon/release contract **3**, schema column coverage **1**, sanitizer/processing-state checks **5**; **17 tests passed**. Log: `structural.log`. Privacy manifest plist syntax and required-reason category were also checked successfully.
- `bash -n scripts/testflight_release.sh` and `git diff --check`: **PASS**.
- Docker `rhysd/actionlint:latest` over both Actions workflows: **PASS**, no diagnostics. Log: `actionlint.log`.
- Docker Swift 6.2 frontend parse of all app, native test and UI test Swift files: **PASS**. Log: `swift-syntax.log`. This establishes syntax only, not Apple type checking or native behavior.

Intermediate compiler failures (an overly complex validation expression, then a missing `try` in a new test) and a mutation-test expectation mismatch were corrected before these final passes. Full local output is in /home/rwrife/.hermes/cache/scratch/recall-rail-issue7-20261010/; no credentials or signing operations were involved.

## Apple gaps / acceptance status

Issue #7 is **not fully acceptance-verified**. Linux cannot build SwiftUI/UIKit, exercise system document pickers, validate the compiled icon/catalog and embedded privacy manifest, sign an archive or upload to ASC. Added native boundary tests and XCUITests cover production navigation, card/deck/attempt export sheets, backup save, local deletion, system import, restore commit and returned deck. They have only been syntax-parsed here and may need document-picker adjustments on the pinned simulator. The release workflow and actual ASC behavior are unexecuted; no processed TestFlight build exists from this work. The existing CI runner must actually provide exact Xcode 26.0.1/17A400 and SDK26.0 or fail closed. Parent review and real Apple CI/signing/TestFlight evidence are blockers before marking acceptance complete.

## Staged file inventory

All 32 intended files are staged; no commit was created.

- `.github/workflows/ci.yml`
- `.github/workflows/testflight.yml`
- `PLAN.md`
- `Packages/RecallRailKit/Sources/RecallRailKit/Clocks.swift`
- `Packages/RecallStore/Package.swift`
- `Packages/RecallStore/Sources/LinuxSHA/LinuxSHA.c`
- `Packages/RecallStore/Sources/LinuxSHA/include/LinuxSHA.h`
- `Packages/RecallStore/Sources/RecallStore/Ownership.swift`
- `Packages/RecallStore/Sources/RecallStore/RecallRepository.swift`
- `Packages/RecallStore/Tests/RecallStoreTests/OwnershipTests.swift`
- `README.md`
- `RecallRail.xcodeproj/project.pbxproj`
- `RecallRail/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- `RecallRail/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `RecallRail/Assets.xcassets/Contents.json`
- `RecallRail/DeckLibrary.swift`
- `RecallRail/DeckListView.swift`
- `RecallRail/OwnershipView.swift`
- `RecallRail/PracticeModel.swift`
- `RecallRail/PrivacyInfo.xcprivacy`
- `RecallRailTests/OwnershipBoundaryTests.swift`
- `RecallRailUITests/OwnershipJourneyTests.swift`
- `docs/issue-7-evidence.md`
- `scripts/check_zero_network.py`
- `scripts/check_zero_network.sh`
- `scripts/generate_app_icon.py`
- `scripts/release_support.py`
- `scripts/test_release_support.py`
- `scripts/testflight_release.sh`
- `scripts/tests/test_backup_schema.py`
- `scripts/tests/test_ownership_structure.py`
- `scripts/tests/test_zero_network.py`
