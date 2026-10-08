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

Native iPhone authoring, CSV import, and local practice are implemented. Apple CI is wired to build and test the app and its XCUITest journey at the exact triggering head; local Linux checks do not establish an Apple pass. No archive, dual-screen validation, or TestFlight binary exists yet.

## Practice contract (issue #5)

From a deck, choose due-only or all cards, required tags and a text filter. These conditions intersect; due means `now >= dueAt`. Practice follows the user-authored card order (use Edit in the deck to reorder). The service also accepts an explicit rehearsal subset/order. Order, current cursor, and answer reveal are saved locally and never recomputed during a run. Resume restores an existing run before a new one can start.

Reveal the answer, then select Again, Hard, or Recalled. This is a **pending** self-grade: no attempt or schedule is saved until **Next — save attempt**. Undo cancels only that pending grade. Next atomically appends immutable evidence, updates its schedule, and advances the cursor. Undo cannot rewrite saved history. Interruption and relaunch cancel pending grades, with an explicit message on resume. The ledger shows raw grades, timestamps, elapsed milliseconds, mode, and before/after box and due snapshots. Mastery describes app evidence, not guaranteed knowledge.

Elapsed time belongs to the current card and freezes at grade selection. Background time is excluded. A clean interruption retains measured foreground time; an unclean relaunch restarts the uncheckpointed timing segment. A backwards uptime counter conservatively restarts current-card timing. Wall-clock edits never reorder the saved queue or replay a committed attempt. Next records its wall-clock commit instant and computes the next due date from that instant.

**Spoken practice scope:** choosing Spoken rehearsal lets you speak aloud and use the same reveal/self-grade/undo/Next controls. It does not listen to or evaluate speech. Only tapping “Request microphone permission” invokes the system microphone permission request (`AVAudioApplication.requestRecordPermission`); starting or resuming spoken practice does not. Permission grant starts no recorder or audio capture. Denial retains the full self-grade workflow. There is no recording, audio retention, transcription, speech recognition, pronunciation score, or network service. The permission control is optional and is not required to speak aloud.

The shared Xcode scheme includes an actual `RecallRailUITests` target that authors a deck and two cards, practices, undoes a pending grade, terminates/relaunches, resumes the revealed card, commits, and inspects the ledger. App boundary tests inject microphone denial. These Apple tests must run on the pinned Apple runner; Linux syntax parsing is not a build or simulator result. CI uploads the exact SHA, Xcode/SDK versions, simulator inventory, logs, `.xcresult`, and built metadata as `apple-practice-<SHA>`.

See [issue #5 local evidence](docs/issue-5-evidence.md) for executed RED/GREEN output, exact commands/counts, changed files, and remaining Apple verification.

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
- **Preview before commit:** the import screen lists additions, updates, skipped-unchanged rows, warnings, and errors — nothing is written until the user commits. Truly empty lines may be skipped; comma-only records are malformed, not blank. Commit is all-or-nothing by default; "valid rows only" is available only as an explicit user choice and still lists every excluded file row. The remaining valid rows commit together or not at all if database revalidation rejects any card (for example a cross-deck ID).

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
