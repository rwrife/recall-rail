# Recall Rail

Local-first iPhone study and rehearsal deck trainer: Leitner-style decks, spoken-answer practice, honest mastery states, and user-owned exports for exams and presentations — no accounts, no cloud.

## Why

Popular education apps such as Quizlet, Duolingo, and Kahoot! show demand for short, repeatable learning sessions, but often add accounts, subscriptions, social features, opaque scoring, and network dependence. Recall Rail keeps one job focused: turn a user's own prompts into an explainable practice queue and record only what the user actually demonstrated.

## Target users

- Students preparing for written, oral, or practical exams.
- Speakers rehearsing presentations, interviews, demonstrations, or teaching material.
- Lifelong learners who want private, portable practice decks without a service account.

## Core workflows

1. Create a deck and add prompt/answer cards manually or import UTF-8 CSV.
2. Start a session scoped by deck, due state, or a chosen rehearsal order.
3. Reveal or speak an answer, then self-grade `again`, `hard`, or `recalled`.
4. Let a deterministic Leitner-style engine place each card into its next box and due window.
5. Review an evidence ledger showing attempts, response time, grade, and schedule changes.
6. Export cards and attempts as CSV, or create/restore a versioned JSON backup after previewing changes.

## MVP

- Local decks, cards, tags, and ordered rehearsal outlines.
- Explainable three-grade Leitner scheduling with deterministic due dates.
- Focused text-answer and spoken-rehearsal modes; microphone permission is optional and audio is not retained by default.
- Honest mastery states: unseen, learning, due, recently recalled, and insufficient evidence. Skipped cards never count as correct.
- Session progress, due queue, and append-only attempt history.
- UTF-8 CSV import/export and versioned JSON backup/restore with validation and preview.
- Dynamic Type, VoiceOver, Reduce Motion, high-contrast, keyboard, and one-handed controls.
- A zero-network default enforced by architecture and CI contract checks.

## iPhone Duo design target

Recall Rail is a standard native iPhone app today. Native iPad support is disabled by default; iPad, tablet layouts, and multitasking require explicit user opt-in. No unavailable fold or dual-screen API is required.

A future `PracticeWorkspaceLayout` seam will support:

- folded mode: one-handed prompt, reveal, and grade flow;
- dual-screen mode: persistent source/outline and session controls on one display, with a distraction-free prompt or speaker view on the other;
- spanned rehearsal: upcoming cues remain private on the control surface while the active prompt stays presentation-safe.

When Apple ships supported dual-screen APIs, only the layout adapter should gain posture, hinge, and display-region awareness; the domain, scheduler, storage, and session state remain unchanged.

## Platform contract

- Native Swift with SwiftUI/UIKit only.
- iPhone-only; Android and native iPad support are out of scope.
- iOS 26 SDK or newer.
- `TARGETED_DEVICE_FAMILY = 1` in every app build configuration; built `UIDeviceFamily` must be `[1]` when verified on an Apple runner.
- Bundle identifier: `com.infinityball.recallrail` everywhere, including `PRODUCT_BUNDLE_IDENTIFIER`, Info.plist, signing, provisioning, and App Store Connect.
- No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity, or other cross-platform/hybrid framework.

## Privacy, permissions, and data ownership

All decks, cards, attempts, schedules, and settings stay in an app-owned local database: a single SQLite file at `Library/Application Support/RecallRail/recallrail.sqlite` inside the app container, managed by the `RecallStore` GRDB package. Attempts and skips are append-only evidence enforced by database triggers — editing or deleting cards and decks can never rewrite recorded history. The file is included in the device backup; `deleteAllData` (the user-facing "delete all my data" reset) removes it irreversibly. There is no cloud sync, account, network storage, analytics, or tracking. The app requires no account, analytics, ads, trackers, or network service. Microphone access is opt-in per spoken session; denial leaves text/self-grade practice fully useful. The MVP performs no speech transcription, voice identification, or cloud AI. Notifications are optional reminders derived from local due dates and can be disabled without losing core function. Export files are created only on explicit request and become user-owned once shared through the system sheet.

Recall Rail is a study aid, not an accredited testing system. Its mastery labels describe app evidence, not guaranteed knowledge or exam outcomes.

## Status and milestones

Native iPhone Xcode project, domain package, and GRDB-backed local store have landed. Authoring and CSV import are under issue #4. Apple CI builds and tests the current app; no archive, dual-screen validation, or TestFlight binary exists yet.

1. Native project skeleton, iPhone-only settings, and CI contracts.
2. Domain model, scheduler, and persistence.
3. Authoring/import and core practice session.
4. Accessible rehearsal UI and future dual-screen layout seam.
5. Backup/export, privacy audit, and release evidence.

## Card CSV format (documented contract)

Cards in one selected deck use plain UTF-8 CSV following RFC 4180 quoting:

- **Encoding:** UTF-8 only. A UTF-8 byte-order mark is accepted and stripped with a warning; files in any other encoding are rejected rather than guessed.
- **Header row:** required columns `prompt` and `answer`; optional `hint`, `source`, `tags`, `id`, `sort` in any order. Unknown columns abort the import instead of silently discarding data.
- **Quoting:** fields containing commas, quotes, or line breaks are wrapped in double quotes; embedded quotes are doubled. Quoted multi-line fields are supported and error reports cite the record's original starting line. Unterminated quotes, quotes in bare fields, and characters after a closing quote are errors; malformed rows cannot be imported even in valid-rows-only mode.
- **Line endings:** CRLF, LF, and CR are all accepted; a mixed file parses with a warning.
- **Tags:** semicolon-separated within the cell (`exam;ch1`), trimmed, duplicates removed.
- **Stable IDs:** the optional `id` column carries the card's UUID. An export includes IDs, so edit-then-reimport updates matching cards in place (unchanged rows are skipped, changed rows are updates) instead of duplicating them. An `id` that is not a valid UUID, or repeated within the file, is an error. Cards can never be re-parented to another deck through import.
- **Sort order:** the optional `sort` column sets stable order; missing or duplicate values fall back to sequential row order with a warning.
- **Preview before commit:** the import screen lists additions, updates, skipped-unchanged rows, warnings, and errors — nothing is written until the user commits. Commit is all-or-nothing by default; "valid rows only" is available only as an explicit user choice and still lists every excluded row.

## Development quickstart

The Xcode project is available. Expected commands on an Apple environment:

```bash
xcodebuild -version
xcodebuild -project RecallRail.xcodeproj -scheme RecallRail -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project RecallRail.xcodeproj -scheme RecallRail -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Linux can run the Swift package suites and static source policy checks, but cannot build or run the iPhone app. Apple CI supplies simulator build/test and built `UIDeviceFamily` evidence for each exact PR head; no Linux result substitutes for it.

## Distribution

App Store Connect bundle registration succeeded for `com.infinityball.recallrail`. GitHub Actions has these secret names configured: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, and `ASC_TEAM_ID`. A future release workflow must use Xcode 26/iOS 26+, verify signing and iPhone-only metadata, upload to TestFlight, and record the processed build ID before any release claim.

## License

MIT. See [LICENSE](LICENSE).
