# Issue #5 implementation and local evidence

Implemented only in the `issue-5-practice` worktree on `feat/issue-5-practice`. Recovery checkpoint: `add2c00`. No push, PR, merge, main-branch commit, other-repository edit, or scheduled-job change was performed.

## Exact changed files

- Domain: `Packages/RecallRailKit/Sources/RecallRailKit/{AttemptEntities,LeitnerScheduler,MasteryDeriver,PracticeSelection}.swift`; `Packages/RecallRailKit/Tests/RecallRailKitTests/PracticeSelectionTests.swift`.
- Store: `Packages/RecallStore/Sources/RecallStore/{PracticeService,RecallRepository}.swift`; `Packages/RecallStore/Tests/RecallStoreTests/{PracticeServiceTests,InterruptionRecoveryTests}.swift`.
- App: `RecallRail/{DeckDetailView,DeckLibrary,PracticeModel,PracticeView}.swift`.
- Apple tests: `RecallRailTests/SpokenPracticeTests.swift`; `RecallRailUITests/PracticeJourneyTests.swift`.
- Wiring/gates: `RecallRail.xcodeproj/project.pbxproj`; `RecallRail.xcodeproj/xcshareddata/xcschemes/RecallRail.xcscheme`; `.github/workflows/ci.yml`; `scripts/check_project_contract.sh`.
- Documentation: `README.md`; this file. `PLAN.md` was read first alongside README. `toolchain.json` is unchanged.

## Executed RED → GREEN sequence

Logs and the container runner are under `/home/rwrife/.hermes/cache/scratch/issue5/`.

| Focused vertical slice | Executed RED evidence | GREEN evidence |
| --- | --- | --- |
| Queue intersection/boundary and pending grade service | `red-both.log`: `cannot find 'PracticeSelection' in scope`; `cannot find 'PracticeService' in scope` | `green3.log`: 76 domain, 47 store tests passed |
| Transactional stale order/schedule guard | `red-guards2.log`: 4 assertions failed after a forged order committed evidence | `green3.log`: guard test passed; full suites passed |
| Foreground timing and commit timestamp; injected transaction failure/retry | `red-timing.log`: `extra argument 'at' in call` before the commit-time API existed | `green-timing.log`: 76 domain, 49 store tests passed; injected cursor-write failure rolled back evidence and schedule, then retry committed once |
| Clock-shift mastery, immutable session order, invalid schedules | `red-honesty.log`: missing `currentSchedule` API; 4 store assertions failed | `green-honesty.log`: 77 domain, 50 store tests passed |
| Missing schedule with existing ledger | `red-missing.log`: `XCTAssertThrowsError failed: did not throw error`; `XCTAssertNil failed` for an invented session | `final-green.log`: 77 domain, 51 store tests passed, zero failures |

The first container invocation failed before tests because Podman rejected `cp -a` permission preservation. The runner was corrected to `cp -R`. An initial queue fixture incorrectly supplied explicit IDs absent from its card input; it was corrected before the guard RED run. The strengthened schedule guard exposed an old recovery fixture that built a before-snapshot from a later instant; the fixture now reads the actual durable schedule.

## Actual final commands and results

The cached Docker image is `swift:6.2-noble` (this host's Docker CLI uses Podman). The worktree is mounted read-only; packages are copied into writable container `/build`, so no container build outputs or root-owned files land in the worktree:

```bash
docker run --rm \
  -v /home/rwrife/repos/recall-rail-worktrees/issue-5-practice:/source:ro \
  swift:6.2-noble bash -c '
    apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null &&
    mkdir /build && cp -R /source/Packages /build/ && cd /build &&
    swift test --package-path Packages/RecallRailKit -Xswiftc -warnings-as-errors &&
    swift test --package-path Packages/RecallStore -Xswiftc -warnings-as-errors'
```

Final output: **77 RecallRailKit tests + 51 RecallStore tests = 128 passing tests**, zero failures. Both commands compile production packages and execute their real tests. The new tests include service-level file-backed relaunch, smaller reboot uptime, backwards wall-clock changes, no duplicate attempts, pending cancellation, per-card timing, intersecting selection, stale retry, missing evidence, and transaction rollback/retry.

```bash
bash scripts/check_project_contract.sh
bash scripts/check_native_only.sh
bash scripts/check_zero_network.sh
```

All PASS (`final-contracts.log`), including native gate self-test. Bundle `com.infinityball.recallrail`, iPhone family `1`, Xcode `26.0.1` build `17A400`, SDK `26.0`, and zero-network policy remain intact.

```bash
docker run --rm \
  -v /home/rwrife/repos/recall-rail-worktrees/issue-5-practice:/source:ro \
  swift:6.2-noble bash -c '
    find /source/RecallRail /source/RecallRailTests /source/RecallRailUITests \
      -name "*.swift" -print0 | xargs -0 swiftc -frontend -parse'
docker run --rm \
  -v /home/rwrife/repos/recall-rail-worktrees/issue-5-practice:/source:ro \
  -w /source docker.io/rhysd/actionlint:latest -color .github/workflows/ci.yml
python3 /home/rwrife/.hermes/cache/scratch/issue5/project_audit.py
git diff --check
```

All exit 0. Syntax parsing covers all **14 app/unit/UI Swift files**. The scratch OpenStep/XML audit checks project structure, separate app/unit/UI source groups, UI app binding, configuration device family, and shared scheme wiring. These are static checks, **not an Xcode build**.

## Apple evidence still required

No Apple build, app unit test, or XCUITest was executed locally. The two microphone boundary tests and actual UI journey are implemented and wired, but their Apple RED/GREEN execution is unavailable on this Linux host. Do not infer an Apple pass from package tests or syntax parsing.

The exact-head CI gate retains the pinned Xcode/SDK checks and required built iPhone metadata gate. It runs the shared scheme, including the actual `RecallRailUITests` target, and uploads `apple-practice-<SHA>` with SHA, toolchain/SDK, simulator inventory, `.xcresult`, test/build logs, and built Info.plist/metadata. Parent review must push the branch and obtain actual pinned Apple build/test evidence before merging.

The UI journey authors a deck and two cards through the real app, reveals and grades, undoes a pending grade, commits Next, terminates/relaunches with another pending grade, resumes the exact revealed card, commits, and verifies the raw ledger excludes the canceled grade. Injected denial tests exercise the app's permission boundary without a production launch-argument bypass. Spoken mode is optional aloud rehearsal and self-grading only; it never captures or retains audio. The complete user-visible scope is documented in README.
