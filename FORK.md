# Fork notes

`1orzero/hex` is Derek's fork of [anomalyco/hex](https://github.com/anomalyco/hex). The fork works on its
`stable` branch, which follows upstream's published releases (`vX.Y.Z` tags) rather than upstream's
`dev`. The iPhone app comes from the `ios-stable` branch instead, which follows upstream's App Store
tags (`ios-beta-appstore-X.Y.Z`); its own `FORK.md` lists its hooks. This branch's `ios/` is no longer
built. The fork's `dev` branch is kept as it was and is no longer used.

## Upstream files the fork changes

Fork code lives in files upstream does not have; upstream files carry only the hooks below. When a
fork change has to touch an upstream file, add a row here with the file, the hook (the function or
line), and the purpose, so whoever resolves a release merge knows what to keep. The hooks belong to
the Dropline private API provider (see "Dropline private API") and the iPhone vocabulary link (see
"Vocabulary").

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
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler for vocabulary links; upstream's handler ignores hosts other than `keyboard`. |
| `ios/HEXMobile/CustomVocabularyEditor.swift` | `.onReceive(… .forkVocabularyLinkAdded)` after the editor's `.onAppear` (3 lines) | Reloads the editor's cached list after a link adds a term; otherwise the editor's next add or remove writes its stale list back and drops the linked term. |

The window hooks draw nothing in scenes and tests (`Ui::live` is false), so the goldens are unchanged.

## Fork-only files

- `FORK.md`: this file.
- `fork/daily.sh`: the daily sync, build, and install pipeline. Its steps live in `fork/lib/sync.sh`,
  `fork/lib/mac.sh`, and `fork/lib/ios.sh`.
- `src/fork.rs`, `src/fork/dropline.rs`, `src/fork/dropline/`, and `src/rune_ui/fork_dropline.rs`: the
  Dropline private API provider in the Mac app.
- `ios/HEXShared/Fork/`, `ios/HEXMobile/Fork/`, and `ios/HEXMobileTests/ForkDropline*Tests.swift`: the same
  provider in the iPhone app.
- `ios/HEXMobile/Fork/VocabularyLink.swift` and `ios/HEXMobileTests/Fork/VocabularyLinkTests.swift`: the
  iPhone vocabulary link.
- `fork/vocabulary.py`: nightly vocabulary upkeep (see "Vocabulary").

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

## Vocabulary

### Add a word on the iPhone

```text
hex-dictation://vocabulary/add?term=<term>
```

- Adds the term to the custom vocabulary list (`CustomVocabularySettings`, in the App Group
  `KeyboardBridge.appGroup` that the app and the keyboard share): the list under Experiments ›
  Custom vocabulary, which dictation spells while that experiment is on.
- Uses the list editor's checks: at most 64 characters, at least two letters or digits, no
  duplicate spelling (case, spaces, and punctuation ignored), at most 100 terms.
- Shows an alert over whatever is on screen: "Added to Vocabulary", "Already in the list",
  "Too long", "Needs at least two letters or digits", "Up to 100 terms", or "No word in the
  link". The iPhone list has no "sounds like" spellings, so `sounds_like` is ignored.
- Query values are percent-decoded; `+` stays a plus (`term=C++`), so encode spaces as `%20`.

Shortcuts app on the iPhone:

1. New shortcut: **Ask for Input** (Text, prompt "Word"), then **URL Encode** (input: Provided Input).
2. **Text**: `hex-dictation://vocabulary/add?term=` followed by **URL Encoded Text**.
3. **Open URLs** with that Text.
4. Run it from the Home Screen, the Action button, or Settings › Accessibility › Touch › Back Tap.

### Add a word on the Mac

The Mac needs no fork code: a Shortcuts quick action runs `hex vocabulary add`, which edits the
vocabulary through the running Hex as Settings does (64 characters per term, 500 terms).

1. In Shortcuts › Settings › Advanced, turn on **Allow Running Scripts**.
2. Create a shortcut named "Add to Hex Vocabulary". In its details (ⓘ), turn on **Use as Quick
   Action** with **Services Menu**, set it to receive **Text**, and set **If there's no input** to
   **Ask For Text**, so the key also works with nothing selected.
3. Add **Run Shell Script**: shell `zsh`, **Pass Input** as arguments, script:

   ```sh
   /Applications/Hex.app/Contents/MacOS/hex vocabulary add "$1" 2>&1 || true
   ```

4. Add **Show Notification** with the **Shell Script Result**. It shows `Added “X”`,
   `“X” is already in the vocabulary`, or the reason the term was refused.
5. In the shortcut's details choose **Add Keyboard Shortcut** (or System Settings › Keyboard ›
   Keyboard Shortcuts… › Services › Text), then select a word anywhere and press it.

Hex must be running; otherwise the notification says so.

### Nightly vocabulary upkeep

Transcription reads only the front of the vocabulary: Qwen3-ASR and QwenCleo the first terms that
fit 1,000 characters (Whisper 500), Parakeet with Labs › Vocabulary biasing on the first 64 terms
(`src/dictation/vocabulary.rs`). The rest still serves rewriting and search. The 22:00 automation
runs `fork/vocabulary.py` from `~/.hex-fork/repo` after `fork/daily.sh` to keep the most used terms in front
and to add new ones:

```text
fork/vocabulary.py init --import-log LOG          once: record which terms were imported
fork/vocabulary.py dictations                     the dictations since the last apply, printed
fork/vocabulary.py plan [--add FILE] [--exclude-app APP]   tonight's changes, printed
fork/vocabulary.py apply [--add FILE] [--exclude-app APP]  back up, change, verify, record
```

The automation's agent reads the dictations, picks up to 5 names, products, technical terms, or
misheard spellings that recur, and passes them as `--add` (`{"add": [{"term", "sounds_like"}]}`).
`apply` then ranks the vocabulary:

1. Pinned terms (`~/.hex-fork/state/vocab/pinned.json`, empty until Derek adds some).
2. Uses in the last 30 days of History's final text (`hex history --since 30d`), most first, matched
   in any case, as whole words for Latin terms and as substrings otherwise. Equal counts go terms the
   script added in the last 30 days (up to 200 characters of the front), then Derek's own terms,
   then imported terms and older script terms, each group in its current order.

The front takes ranked terms while they fit (64 terms, or the characters left, passing over a term
too long for what is left), so the model reads exactly the planned terms. `hex vocabulary add`
appends, so `apply` moves the fewest terms to the end (`remove`, then `add` with the same
spellings) that leave the planned front first; terms inside the front keep their order. It writes
only when the front changes or a term is added or removed, copies `settings.json` to
`~/.hex-fork/backup/vocab/` first, and afterwards checks that every term and spelling is unchanged
and the front matches the plan; otherwise it stops and names the backup, keeps the terms it already
added as its own, and leaves the analyzed window for the next night. A model that reads no
vocabulary (or Parakeet with biasing off) gets no reordering.

Terms Derek added or imported are never removed and get no new spellings. A term the script added is
removed after 90 days without a use or a new spelling. `~/.hex-fork/state/vocab/` holds `own.json` (the script's terms with
their added and last-seen dates, and the end of the last analyzed window), `pinned.json`,
`imported.json`, and `last-plan.json`; no dictation text is stored.

`HEX_FORK_HOME`, `HEX_FORK_HEX` (the `hex` binary), and `HEX_APPLICATION_SUPPORT_DIR` override the defaults,
which is how the script is tried against Hex Test.

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
7. iPhone vocabulary: copy the Mac's vocabulary into the iPhone app's App Group when it changed (see
   "The Mac's vocabulary on the iPhone").

The two branches don't wait for each other: a conflict or a failed build on one side stops only that
side, and the run's exit code is the first failure in this order: `stable`'s sync, `ios-stable`'s sync,
the Mac, the iPhone, the vocabulary copy. `state/last-run.json` has each side's status (`sync` and
`mac` for `stable`, `ios_sync` and `ios` for `ios-stable`) and `ios_vocabulary`.

Each run writes `~/.hex-fork/logs/<run>.log` (`latest.log` points to the newest) with `-mac-build`,
`-ios-build`, `-ios-install`, and `-ios-vocabulary` logs beside it, and summarizes itself in
`~/.hex-fork/state/last-run.json`.

```text
fork/daily.sh [--continue] [--continue-ios] [--allow-identity-change] [--no-push] [--force]

--continue               finish a merge whose conflicts were resolved and committed in the clone
--continue-ios           finish an ios-stable merge whose conflicts were resolved and added in ios-src
--allow-identity-change  replace a Hex.app signed by another identity (macOS permissions reset)
--no-push                merge and build only; push and install nothing
--force                  build and install even when the installed commits match, and copy the vocabulary
```

| Exit | Meaning |
| --- | --- |
| 0 | Every step succeeded or had nothing to do |
| 2 | Setup problem: a missing tool, a failed fetch or release lookup, a dirty clone, another run in progress |
| 10 | The iPhone isn't reachable; its install or vocabulary copy is skipped and retried next run |
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
| 44 | Reading the Mac's vocabulary or copying it to the iPhone failed |

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

## The Mac's vocabulary on the iPhone

One way, Mac to iPhone, each run after the installs:

1. Read the Mac's vocabulary in its order (`hex vocabulary list --json`, from the running Hex) into
   `~/.hex-fork/state/ios-vocabulary/next/fork-mac-vocabulary.json` as `{"terms": [...]}`. When Hex
   isn't running, the step is skipped (`skipped-hex-not-running`) and the next run copies.
2. When the terms differ from the last copy (`~/.hex-fork/state/ios-vocabulary/fork-mac-vocabulary.json`),
   the iPhone app was installed in this run, or `--force` is given, copy the file into the App Group
   `group.io.veraze.hex.mobile` with `xcrun devicectl device copy to --domain-type appGroupDataContainer`.
   The iPhone app folds it into its list as `ios-stable`'s `FORK.md` describes, the next time the keyboard
   or Hex comes on screen, without Derek opening Hex.
3. `--no-push` reads and compares only (`changed` or `up-to-date`).

The file holds names and email addresses, so it is written owner-only under `~/.hex-fork/state/` and never
inside a repository or a build. Copying rather than building it into the app means a changed vocabulary
needs no rebuild or reinstall, which would close the keyboard and Hex on the iPhone each night. The nightly
vocabulary upkeep (`fork/vocabulary.py apply`) should run before `daily.sh`, so the iPhone gets the
same night's order.

Environment overrides: `HEX_FORK_HOME`, `HEX_FORK_BRANCH`, `HEX_FORK_IOS_BRANCH`, `HEX_FORK_REPO`, `HEX_FORK_UPSTREAM_REPO`, `HEX_FORK_TEAM_ID`, `HEX_FORK_IPHONE`, `HEX_FORK_IOS_BUNDLE_PREFIX`, `HEX_FORK_IOS_APP_NAME`, `HEX_FORK_IDLE_WAIT`, `HEX_FORK_HEX` (the `hex` command the vocabulary is read with).
