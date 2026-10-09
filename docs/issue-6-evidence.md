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

2. **Compact iPhone accessibility & keyboard surfaces (`RecallRail/PracticeView.swift`):**
   - Shared `PracticeControlStyle` requests minimum 44pt button height and fills available width; the actual reachable hit regions await Apple simulator/device checks. Destructive "Abandon session" uses role-aware `systemRed` rather than losing its distinction.
   - `accessibilityAddTraits(.isHeader)` on prompt text and a custom "Reveal answer" action. VoiceOver order/action activation requires device evidence.
   - Shortcuts wired: `r` for reveal, `1`/`2`/`3` for Again/Hard/Recalled, `Cmd+Z` for Undo, and `Return` for Next. External hardware-keyboard operation has not been verified.
   - State restoration and timer integrity preserved across layout presentation changes in the model test.
   - Debug and Release project settings allow portrait and landscape on iPhone (`UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight`); actual rotation awaits Apple UI tests.

3. **Structural and unit test coverage:**
   - `RecallRailTests/PracticeWorkspaceTests.swift`: checks pane plans and model state across simulated intent changes, frozen grade timing, and resume timer segment restart (1000 ms foreground + 1000 ms additional = 2000 ms). This app-target test is Apple-CI-only and has not run on Linux.
   - `RecallRailUITests/CompactAccessibilityTests.swift`: new Apple-only journey asserts exact effective AX5 Dynamic Type category through an in-app probe (`practice.size-category`), geometric window bounds after rotation, preservation of revealed answer and pending grade, and resume after termination. It has not run on Linux. An applied size category alone does not prove absence of clipping; screenshots will be attached only if Apple CI executes this test.
   - `scripts/tests/test_practice_workspace.py`: Linux structural gate checks no session copying, no posture entanglement in `Packages`, source-level keyboard/accessibility wiring, destructive role styling, and orientation settings. These checks are not runtime accessibility proof.
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
- **Independent read-only review:**
  - Round 1 FAIL addressed: rotation window geometry asserted, pending-grade preservation across rotation proved, destructive button role styling restored, and Dynamic Type proven via in-app category probe. Round 2 pending fresh verdict.
- **macOS / iOS native simulator build and tests:**
  - Deferred to Apple CI runner (`macos-15`, Xcode 26.0.1, iOS 26 SDK).
  - Linux checks cannot build or test the native iPhone app. VoiceOver auditory narration and physical motion reduction are Apple-runner/device properties, not local Linux results.

## Manual iPhone accessibility evidence gate (required before release claims)

Real VoiceOver narration, external hardware keyboards, Increase Contrast, and
Reduce Motion cannot be driven by XCUITest on iPhone and are NOT claimed as
verified by this slice. A human must complete this matrix on a physical iPhone
after the exact head ships a build, and append results here (device/OS/head
SHA/settings/outcome per row). Issue #7 release evidence must cite it.

| # | Check | Settings | Expected | Device/OS/Head | Result |
|---|-------|----------|----------|----------------|--------|
| 1 | One-handed reachability of prompt/reveal/grade | Default, AX5 | Primary actions reachable with thumb in portrait and landscape | | pending |
| 2 | VoiceOver reading order | VoiceOver on, AX5 | Card count → prompt (header) → hint → answer → grades → pending controls; no leaked private-cue text | | pending |
| 3 | VoiceOver custom action | VoiceOver on | "Reveal answer" rotor action on the prompt activates reveal | | pending |
| 4 | Hardware keyboard shortcuts | Connected keyboard | `r`, `1`/`2`/`3`, `Cmd+Z`, `Return` drive reveal/grade/undo/next | | pending |
| 5 | Interruption/resume | VoiceOver on | Background/foreground cancels pending grade with the notice on resume | | pending |
| 6 | Increase Contrast | Increase Contrast On | Grade and destructive controls remain distinguishable | | pending |
| 7 | Reduce Motion | Reduce Motion On | No motion regressions (app declares no animations; structural gate enforces) | | pending |
| 8 | Text clipping sweep | AX5, portrait + landscape | No clipped prompt/answer/notice text (screenshots attached) | | pending |
