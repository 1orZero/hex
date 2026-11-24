# Fork notes

`1orzero/hex` is Derek's fork of [anomalyco/hex](https://github.com/anomalyco/hex). The fork works on its
`stable` branch, which follows upstream's published releases (`vX.Y.Z` tags) rather than upstream's
`dev`. The iPhone app comes from the `ios-stable` branch instead, which follows upstream's App Store
tags (`ios-beta-appstore-X.Y.Z`); its own `FORK.md` lists its hooks. This branch's `ios/` is no longer
built. The fork's `dev` branch is kept as it was and is no longer used.

## Upstream files the fork changes

Fork code lives in files upstream does not have; upstream files carry only the hooks below. When a
fork change has to touch an upstream file, add a row here with the file, the hook (the function or
line), and the purpose, so whoever resolves a release merge knows what to keep. Every hook today
belongs to the Dropline private API provider (see "Dropline private API").

| Upstream file | Hook | Purpose |
| --- | --- | --- |
| `src/main.rs` | `mod fork;` (macOS) after `mod feedback;` | Compiles the fork module. |
| `src/parakeet.rs` | `InferenceJob.dropline` field; `fork::dropline::job(&samples)` after `diagnostics::persist` in the submit path; `fork::dropline::wait(job.dropline, job.transcript)` in `run_inference_worker` | The dictation-finish point: takes the clip for Dropline and picks Dropline's text or the local one. |
| `src/recognition.rs` | `fork::dropline::prepare()` after `worker.prepare_paste()` on capture start | Opens the Dropline session early (best effort). |
| `src/macos_rune.rs` | `fork::dropline::deselect()` in `StatusItemAction::SelectModel` | Choosing a local model in the menu bar stops using Dropline. |
| `src/rune_ui.rs` | `mod fork_dropline;`, `Ui.fork_dropline` field and its default | The picker section's form state. |
| `src/rune_ui/picker.rs` | `fork_dropline::model_chosen()` at the top of `choose`; `content.children(fork_dropline::section(ui, p))` after the body in `modal` | Choosing a local model in the picker stops using Dropline; the picker's last section adds, uses, and deletes the provider. |
| `src/rune_ui/general.rs` | `fork_dropline::model_name(ui, model.name)` in the Speech model button; `description.or_else(\|\| fork_dropline::status(ui, p))` after the description match | General names Dropline while it is in use and shows the last fallback. |
| `ios/HEXMobile/DictationController.swift` | `finishRecording()`: `activeTranscriber.transcribe(` becomes `activeTranscriber.transcribePreferringDropline(` with the same arguments | The iPhone dictation-finish point: Dropline first, the local engine on failure. |
| `ios/HEXMobile/DictationController.swift` | `startRecording(...)`: `ForkDroplineRecognition.prepare(hints: vocabularyTerms)` after `let vocabularyTerms = …` | Opens the Dropline session early (best effort). |
| `ios/HEXMobile/ContentView.swift` | `standaloneView`: `ForkDroplineSettingsCard()` between `settingsCard` and `ExperimentsCard()` | Adds, selects, and deletes the provider. |

The window hooks draw nothing in scenes and tests (`Ui::live` is false), so the goldens are unchanged.

## Fork-only files

- `FORK.md`: this file.
- `fork/daily.sh`: the daily sync, build, and install pipeline. Its steps live in `fork/lib/sync.sh`,
  `fork/lib/mac.sh`, and `fork/lib/ios.sh`.
- `src/fork.rs`, `src/fork/dropline.rs`, `src/fork/dropline/`, and `src/rune_ui/fork_dropline.rs`: the
  Dropline private API provider in the Mac app.
- `ios/HEXShared/Fork/`, `ios/HEXMobile/Fork/`, and `ios/HEXMobileTests/ForkDropline*Tests.swift`: the same
  provider in the iPhone app.

## Dropline private API

A custom transcription provider, "Dropline 私人 API", in the Mac and iPhone apps. While it is selected, a
finished dictation's recording is sent to Dropline's private API and its text replaces the local model's;
the rest of the pipeline (corrections, modes, transformations, paste, History) is unchanged. When Dropline
fails (network error, timeout, a second 401 after one token refetch, a bad answer), the dictation uses the
local model's text of the same recording and says why. An empty `final_text` is a valid answer: Dropline
heard no speech, so the dictation inserts nothing and does not fall back.

- The access token comes from a token endpoint (default `https://voice.veraze.io/v1/dropline-private/token`)
  called with a bearer. The endpoint must be https. Saving the provider fetches one token first and stores
  nothing if that fails.
- Context: Hex's vocabulary terms go to Dropline as `context.text`.
- Audio: long pauses shortened and edges trimmed per 20 ms block (Derek Voice's `keptPackets`), then
  24 kbit/s Ogg Opus.

### Mac

- The local model still transcribes every clip while Dropline runs, so a fallback needs no second
  transcription. When Dropline answers, the local transcript still finishes in the background under its own
  deadlines. General and the model picker show the last fallback.
- The bearer lives in the Keychain (service `anomaly.hex.fork.dropline-private`, account = the data
  folder); the endpoint and selection in `fork/dropline-private.json` in the data folder. Opus comes from
  macOS's encoder.
- Saving adds the provider; choosing it with 使用 selects it, and choosing a local model in the picker or
  the menu bar stops using it.

### iPhone

This describes this branch's `ios/`, which is no longer built; the installed iPhone app is
`ios-stable`'s, whose `FORK.md` describes the provider there, keyboard dictation included.

- Keyboard dictation is recorded and transcribed by the app's `DictationController` (the keyboard only
  sends start and stop through `KeyboardBridge`), so it takes the same path. The local engine
  transcribes the same file only after Dropline fails (any failure other than cancellation).
- Settings: endpoint, selection, and the last fallback in the App Group defaults; the bearer in the
  Keychain (service `anomaly.hex.fork.dropline-private`, account `bearer`, access group
  `KeyboardBridge.appGroup`, after first unlock). The daily pipeline's identity rewrite moves that group
  with the app.
- Saving the provider selects it.

## Daily pipeline

`fork/daily.sh` runs on Derek's Mac from its own clone, `~/.hex-fork/repo` (created on the first run).
A Capy automation runs `~/.hex-fork/repo/fork/daily.sh` every day at 22:00 Asia/Taipei.

1. Sync: fetch `origin/stable` and upstream's `v*` tags, then find the newest `vX.Y.Z` tag whose GitHub
   release is neither a draft nor a prerelease. When `stable` doesn't contain it, `git merge <tag>`.
2. iOS sync: fetch `origin/ios-stable` and upstream's `ios-beta-appstore-*` tags, then take the newest
   `ios-beta-appstore-X.Y.Z` by version. When `ios-stable` doesn't contain it, merge it in
   `~/.hex-fork/ios-src` against the App Store tag `ios-stable` last merged (see "Merge conflicts").
3. Decide: the Mac app is built only when its candidate (the merge, or `origin/stable`) differs from the
   commit it last installed, and the iPhone app only when its candidate (the merge, or
   `origin/ios-stable`) does; the installed commits are in `~/.hex-fork/state/mac-installed` and
   `ios-installed`.
4. Build the Mac app from `stable` and the iPhone app from `ios-stable`. Each merge is pushed only after
   its own app builds.
5. Push the merges: `stable`'s to `origin/stable` (if the branch refuses direct pushes, through a pull
   request merged with `gh pr merge --match-head-commit`), `ios-stable`'s directly to
   `origin/ios-stable`.
6. Install on the Mac and on the iPhone, and record each installed commit.

The two branches don't wait for each other: a conflict or a failed build on one side stops only that
side, and the run's exit code is the first failure in this order: `stable`'s sync, `ios-stable`'s sync,
the Mac, the iPhone. `state/last-run.json` has each side's status (`sync` and `mac` for `stable`,
`ios_sync` and `ios` for `ios-stable`).

Each run writes `~/.hex-fork/logs/<run>.log` (`latest.log` points to the newest) with `-mac-build`,
`-ios-build`, and `-ios-install` logs beside it, and summarizes itself in `~/.hex-fork/state/last-run.json`.

```text
fork/daily.sh [--continue] [--continue-ios] [--allow-identity-change] [--no-push] [--force]

--continue               finish a merge whose conflicts were resolved and committed in the clone
--continue-ios           finish an ios-stable merge whose conflicts were resolved and added in ios-src
--allow-identity-change  replace a Hex.app signed by another identity (macOS permissions reset)
--no-push                merge and build only; push and install nothing
--force                  build and install even when the installed commits match
```

| Exit | Meaning |
| --- | --- |
| 0 | Every step succeeded or had nothing to do |
| 2 | Setup problem: a missing tool, a failed fetch or release lookup, a dirty clone, another run in progress |
| 10 | The iPhone isn't reachable; its install is skipped and retried next run |
| 20 | Merge conflict on `stable`; the merge stays in progress in the clone |
| 21 | The `stable` merge doesn't build; it is not pushed, and the Mac isn't installed |
| 22 | Pushing the `stable` merge failed |
| 23 | Merge conflict on `ios-stable`; the merge stays in progress in `~/.hex-fork/ios-src` |
| 24 | The `ios-stable` merge doesn't build; it is not pushed, and the iPhone isn't installed |
| 25 | Pushing the `ios-stable` merge failed |
| 30, 31 | The Mac or iPhone build failed |
| 40 | Hex stayed busy (recording, transcribing, or a meeting); the Mac install waits for the next run |
| 41 | The installed Hex is signed by another identity; rerun with `--allow-identity-change` while Derek can grant permissions |
| 42, 43 | The Mac or iPhone install failed |

### Merge conflicts

On exit 20 the merge stays in progress in `~/.hex-fork/repo`. Resolve each file by taking upstream's
version and re-applying only the fork hooks listed under "Upstream files the fork changes". Commit,
then run `fork/daily.sh --continue`, which builds both apps, pushes, and installs. When the right
resolution isn't clear, run `git -C ~/.hex-fork/repo merge --abort` and report the conflict; the next
run aborts any merge still in progress and tries again.

On exit 23 the `ios-stable` merge stays in `~/.hex-fork/ios-src`. App Store tags are release trees beside
upstream's `dev`, so the script merges against the App Store tag `ios-stable` last merged rather than
git's merge base: it applies the fork's changes (`ios-stable` against that tag) to the new tag, and only
those changes can conflict. `HEAD` there is the new tag; resolve each file by taking upstream's version
and re-applying only the hooks in `ios-stable`'s `FORK.md`, `git add` it (don't commit), then run
`fork/daily.sh --continue-ios`, which commits the merge with `ios-stable` and the tag as parents, builds,
pushes, and installs. When the right resolution isn't clear, run
`git -C ~/.hex-fork/ios-src cherry-pick --abort` and report the conflict; the next run drops any merge
still in progress and tries again.

## Mac app

- Built by upstream's `scripts/build-app.sh` with `HEX_RELEASE_UNSIGNED=1` (Hex, `anomaly.hex`),
  `HEX_BUILD_CHANNEL=stable`, and `HEX_VERSION` set to the release tag, so it behaves as a stable release
  and dev-only Labs stay hidden. The bundle ID and the data folder (`~/Library/Application Support/hex`)
  are the official app's.
- Updates are off through `HEX_DISABLE_UPDATES=1` in `Info.plist`'s `LSEnvironment`, the runtime switch
  upstream's updater reads (`updates_off_by_env` in `src/updater.rs`). `HEX_LOCAL_BUILD=1` also turns updates off,
  but it makes the app a dev build. `HexForkCommit` in `Info.plist` records the fork commit.
- Signed with the Apple Development identity of team 67A6AV33K9, because `scripts/macos-signing.sh` accepts
  only a Developer ID identity, which the team doesn't have. The app needs no provisioning profile, and
  its designated requirement stays the same across rebuilds, so macOS permissions survive them.
- The install waits while Hex records, transcribes, or runs a meeting (up to `HEX_FORK_IDLE_WAIT` seconds,
  default 600), quits it with `hex quit`, replaces `/Applications/Hex.app`, and reopens it if it was running.
  Replacing a Hex signed by another identity needs `--allow-identity-change`: the old app moves to
  `~/.hex-fork/backup/Hex.app` and `tccutil` resets its permissions, so Hex asks for them again.
- The clone builds in its own `target/`, because `build-app.sh` copies from `<repo>/target/release` and would
  ship a stale binary with a shared `CARGO_TARGET_DIR`. Rust comes from `~/.hex-fork/rustup` (stable, updated
  each run), which leaves the Mac's own toolchains alone.

## iPhone app

- Built from `ios-stable` in a staging worktree, `~/.hex-fork/ios-src`, so the repo is never rewritten. The
  script reads the app's bundle ID from `ios/project.yml` (`anomaly.hex.mobile` since the App Store
  releases) and replaces it under `ios/` (Swift, entitlements, `project.yml`) with `io.veraze.hex.mobile`,
  which moves the keyboard and widget extensions, the App Group, and any keychain group with it.
  `ios/project.fork.yml` includes `project.yml` and sets team 67A6AV33K9 and the names "Hex Fork" and
  "Hex Fork Keyboard". As upstream's App Store build does, the version is the tag's (`1.0.4` for
  `ios-beta-appstore-1.0.4`).
- The build is checked before it installs: the app's ID and team, the `group.io.veraze.hex.mobile`
  entitlement on the app and the keyboard, and every extension's ID under `io.veraze.hex.mobile`.
- `xcodebuild -allowProvisioningUpdates` builds Release with the team's profiles for `io.veraze.hex.mobile`,
  and `xcrun devicectl device install app` installs it on Derek888 over Wi-Fi.
- The iPhone app has no in-app updater.

Environment overrides: `HEX_FORK_HOME`, `HEX_FORK_BRANCH`, `HEX_FORK_IOS_BRANCH`, `HEX_FORK_REPO`, `HEX_FORK_UPSTREAM_REPO`, `HEX_FORK_TEAM_ID`, `HEX_FORK_IPHONE`, `HEX_FORK_IOS_BUNDLE_PREFIX`, `HEX_FORK_IOS_APP_NAME`, `HEX_FORK_IDLE_WAIT`.
