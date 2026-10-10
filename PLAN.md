# Recall Rail plan

## Scope

Recall Rail is a local-first native Swift iPhone app for building user-authored prompt decks and rehearsing them through an explainable queue. The MVP optimizes for trustworthy session state, fast capture, accessibility, and user-owned exports rather than content marketplaces or opaque AI tutoring.

## Architecture

- **RecallRail app target:** SwiftUI navigation, authoring, practice, settings, import/export, and permission surfaces.
- **RecallRailKit Swift package:** pure Swift entities, queue/scheduling engine, mastery derivation, import validation, backup codec, and deterministic tests.
- **RecallStore:** GRDB/SQLite repository with explicit migrations, transactions, foreign keys, and fixture databases.
- **PracticeWorkspaceLayout:** the only adaptive workspace seam. It exposes compact one-pane behavior now and a future dual-screen region strategy later without leaking unavailable fold APIs into domain code.
- **Boundary services:** protocol-backed clock, notification scheduler, microphone session, file importer/exporter, and system share presenter.

### Core model

- `Deck`: title, notes, tags, archived state, creation/update timestamps.
- `Card`: stable ID, prompt, answer, optional hint/source, sort order, tags, archived state.
- `Attempt`: immutable timestamp, grade (`again`, `hard`, `recalled`), elapsed duration, mode, and before/after schedule snapshot.
- `ScheduleState`: box, due instant, consecutive-recall count, last-attempt ID, and algorithm version.
- `Session`: ordered card IDs, cursor, mode, start/end timestamps, and interruption-safe resume state.

Mastery is derived, never manually asserted. Missing, skipped, imported-without-history, and corrupted evidence remain unknown/insufficient rather than being converted to failure or success.

## Technology choices

- **Swift 6 + SwiftUI/UIKit:** native platform support, accessibility, background/scene handling, and App Store tooling.
- **iOS 26 SDK minimum build requirement:** project and CI pin the supported current Apple toolchain.
- **GRDB over SQLite:** inspectable local storage, explicit migrations, deterministic fixtures, and no cloud dependency.
- **Swift Package Manager:** isolate domain tests from UI and simulator concerns.
- **CSV + versioned JSON:** interoperable card exchange plus complete validated backup/restore.
- **No network entitlement or HTTP client in MVP:** enforce the privacy promise structurally.

## Platform and signing contract

- Bundle identifier: `com.infinityball.recallrail` in every app/signing/provisioning surface.
- `TARGETED_DEVICE_FAMILY = 1` in every app build configuration and generator setting.
- Native iPad support is disabled. Android and iPad work require explicit user opt-in.
- Built `UIDeviceFamily` must equal `[1]` on a real Apple CI runner before release.
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or equivalent cross-platform/hybrid framework.
- App Store Connect secrets referenced by name only: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID`.

## iPhone Duo target and migration

The current app uses ordinary compact iPhone APIs. `PracticeWorkspaceLayout` owns presentation state:

1. Compact: prompt, reveal, and grading controls in one focused stack.
2. Future dual-screen companion: private outline/due queue and session controls persist on one screen; active prompt/answer or speaker view occupies the other.
3. Future spanned mode: hinge-safe regions and posture transitions preserve the same session ID, cursor, revealed state, and timer anchors.

No fold SDK symbol, posture assumption, device claim, or iPad layout enters the MVP. When supported APIs exist, add an adapter and native-device evidence rather than branching the scheduler or persistence layer.

## Milestones and dependency order

1. **Foundation:** Xcode project, package, iPhone-only settings, bundle ID, zero-network and toolchain CI checks.
2. **Truth layer:** entities, deterministic schedule transitions, unknown-safe mastery derivation, property/unit tests.
3. **Persistence:** migrations, repositories, fixture database, interruption-safe sessions, transactional imports.
4. **Authoring:** deck/card CRUD, reorder, search/filter, strict CSV preview/import with error reports.
5. **Practice:** due queue, reveal/grade loop, spoken rehearsal permission boundary, attempt ledger, resume behavior.
6. **Accessible workspace:** Dynamic Type, VoiceOver, keyboard, Reduce Motion, contrast, compact layouts, `PracticeWorkspaceLayout` seam.
7. **Ownership and release:** CSV exports, JSON backup/restore preview, privacy audit, signed archive, TestFlight processing evidence.

## Testing strategy

- Table-driven and property tests for schedule transitions, clock boundaries, algorithm versioning, and unknown-safe mastery.
- Migration and repository tests against temporary SQLite databases, including rollback and corrupted-row fixtures.
- Golden fixtures for CSV quoting/encoding/duplicate IDs and JSON schema/version compatibility.
- State-machine tests for interruption, reveal, grade, undo window, and resume semantics.
- Accessibility identifiers and focused UI journeys for create deck, import preview, practice, spoken-mode denial, export, and restore.
- CI policy checks: no network APIs/entitlements, bundle ID exact match, all `TARGETED_DEVICE_FAMILY` values equal `1`, toolchain pin, secrets referenced only by name.
- Apple-runner evidence: app build/tests on an iPhone simulator, archive inspection for `UIDeviceFamily = [1]`, signing, and TestFlight processing. Linux checks never substitute for this evidence.

## Packaging and distribution

Use Xcode 26 with the iOS 26 SDK or newer. Produce a signed iPhone archive using `com.infinityball.recallrail`, verify the archive metadata and entitlements, then upload through App Store Connect using the configured Actions secrets. Capture Xcode/SDK/build SHA, archive verification, upload result, and processed build ID. App Store metadata must state local storage, explicit microphone permission without recording, no implemented notifications, no account, and no tracking.

## Risks and mitigations

- **Self-grading bias:** show raw attempt evidence and label states as app-observed, not objective mastery.
- **Scheduling surprises:** version the algorithm, expose why a card is due, and test every transition.
- **Data loss:** transactional storage, explicit backup, restore preview, schema validation, and migration fixtures.
- **Microphone privacy:** permission only when requested, no retained audio by default, no transcription in MVP.
- **Dual-screen SDK uncertainty:** isolate the future behavior behind one layout seam; make no compatibility claim before real hardware/API evidence.
- **Release drift:** machine-check bundle/device/toolchain settings and verify built metadata on Apple CI.

## Explicit non-goals

- No Android app and no native iPad support.
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or other cross-platform/hybrid framework.
- No cloud sync, web account, classroom administration, collaborative decks, content marketplace, ads, analytics, or subscriptions.
- No automatic web scraping, copyrighted textbook ingestion, or answer generation.
- No speech-to-text, pronunciation scoring, biometric voice analysis, or cloud AI in MVP.
- No claim that a mastery label predicts grades, certification, competence, or safety-critical readiness.
- No dependency on unavailable dual-screen/fold APIs and no claimed iPhone Duo compatibility before supported hardware/API testing.
