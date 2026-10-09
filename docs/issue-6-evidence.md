# Issue #6 evidence: Accessible PracticeWorkspaceLayout and iPhone Duo seam

Date: 2026-10-09
Repository: `rwrife/recall-rail`
Worktree: `/home/rwrife/repos/recall-rail-worktrees/issue-6-workspace`
Branch: `feat/issue-6-workspace`
Issue: [#6 Create the accessible PracticeWorkspaceLayout and future iPhone Duo seam](https://github.com/rwrife/recall-rail/issues/6)

## Scope completed

1. **PracticeWorkspaceLayout seam (`RecallRail/PracticeWorkspaceLayout.swift`):**
   - Pure Swift presentation model defining `.compact`, `.simulatedCompanion`, and `.simulatedSpanned` presentations.
   - Ordered pane intents keep upcoming cues, outline/due queue, grading, navigation, and permission controls on private surfaces; presentation surfaces are strictly limited to the active prompt, revealed answer, or speaker view.
   - Independent of `RecallRailKit`, `RecallStore`, database entities, and session timing. No fold SDK or hardware assumptions.

2. **Compact iPhone accessibility & keyboard operability (`RecallRail/PracticeView.swift`):**
   - Touch targets guaranteed at minimum 44x44pt via `PracticeControlStyle`.
   - `accessibilityAddTraits(.isHeader)` on prompt text.
   - Accessibility custom action `"Reveal answer"` on the prompt view.
   - Keyboard shortcuts: `r` for reveal, `1`/`2`/`3` for Again/Hard/Recalled, `Cmd+Z` for Undo, and `Return` for Next.
   - State restoration and timer integrity preserved across layout presentation changes.
   - Orientation settings updated in Debug and Release to allow portrait and landscape on iPhone (`UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight`).

3. **Structural and unit test coverage:**
   - `RecallRailTests/PracticeWorkspaceTests.swift`: tests pane layout plans and verifies that switching layout presentations in `PracticeModel` retains the identical session, pending attempt, card, timing anchor, and database state across simulated transitions.
   - `RecallRailUITests/CompactAccessibilityTests.swift`: native XCUITest covering XXXL accessibility type scaling, portrait and landscape orientations, reveal/grade/undo/next journeys, and app termination/relaunch resume.
   - `scripts/tests/test_practice_workspace.py`: Python structural contract gate run in Linux CI verifying no session copying, no posture entanglement in `Packages`, strict accessibility and keyboard shortcuts, and orientation settings.
   - Added `test_practice_workspace.py` step to `.github/workflows/ci.yml`.

## Evidence tiers

- **Linux package test suite (swift:6.2-noble, CI's container; Packages copied to /tmp probe):**
  - `swift test --package-path Packages/RecallRailKit -Xswiftc -warnings-as-errors`: Executed 77 tests, with 0 failures.
  - `swift test --package-path Packages/RecallStore -Xswiftc -warnings-as-errors`: Executed 56 tests, with 0 failures.
- **Linux structural contract checks:**
  - `bash scripts/check_project_contract.sh`: PASS (`TARGETED_DEVICE_FAMILY = 1`, bundle `com.infinityball.recallrail`, Swift 6, iOS 26, zero tracking).
  - `bash scripts/check_zero_network.sh`: PASS (empty allowlist, no network APIs).
  - `bash scripts/check_native_only.sh`: PASS (native Swift only).
  - `python3 scripts/tests/test_practice_workspace.py`: 5 passed, 0 failures.
  - `actionlint`: PASS (clean workflow syntax).
  - `swiftc -frontend -parse`: all new and modified Swift files parse cleanly.
- **macOS / iOS native simulator build and tests:**
  - Deferred to Apple CI runner (`macos-15`, Xcode 26.0.1, iOS 26 SDK).
  - Linux checks cannot build or test the native iPhone app.
