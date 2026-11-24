# Fork notes

`1orzero/hex` is Derek's fork of [anomalyco/hex](https://github.com/anomalyco/hex). The fork works on its
`stable` branch, which follows upstream's published releases (`vX.Y.Z` tags) rather than upstream's
`dev`. The fork's `dev` branch is kept as it was and is no longer used.

## Upstream files the fork changes

None. Every fork change lives in files upstream does not have. When a fork change has to touch an
upstream file, add a row here with the file, the hook (the function or line), and the purpose, so
whoever resolves a release merge knows what to keep.

| Upstream file | Hook | Purpose |
| --- | --- | --- |
| (none) | | |

## Fork-only files

- `FORK.md`: this file.
- `fork/daily.sh`: the daily sync, build, and install pipeline. Its steps live in `fork/lib/sync.sh`,
  `fork/lib/mac.sh`, and `fork/lib/ios.sh`.

## Daily pipeline

`fork/daily.sh` runs on Derek's Mac from its own clone, `~/.hex-fork/repo` (created on the first run).
A Capy automation runs `~/.hex-fork/repo/fork/daily.sh` every day at 22:00 Asia/Taipei.

1. Sync: fetch `origin/stable` and upstream's `v*` tags, then find the newest `vX.Y.Z` tag whose GitHub
   release is neither a draft nor a prerelease. When `stable` doesn't contain it, `git merge <tag>`.
2. Decide: each app is built only when the candidate (the merge, or `origin/stable`) differs from the
   commit it last installed, recorded in `~/.hex-fork/state/mac-installed` and `ios-installed`.
3. Build the Mac app and the iPhone app. A merge is pushed only after both build.
4. Push the merge to `origin/stable`. If the branch refuses direct pushes, the merge goes through a pull
   request merged with `gh pr merge --match-head-commit`.
5. Install on the Mac and on the iPhone, and record each installed commit.

Each run writes `~/.hex-fork/logs/<run>.log` (`latest.log` points to the newest) with `-mac-build`,
`-ios-build`, and `-ios-install` logs beside it, and summarizes itself in `~/.hex-fork/state/last-run.json`.

```text
fork/daily.sh [--continue] [--allow-identity-change] [--no-push] [--force]

--continue               finish a merge whose conflicts were resolved and committed in the clone
--allow-identity-change  replace a Hex.app signed by another identity (macOS permissions reset)
--no-push                merge and build only; push and install nothing
--force                  build and install even when the installed commits match
```

| Exit | Meaning |
| --- | --- |
| 0 | Every step succeeded or had nothing to do |
| 2 | Setup problem: a missing tool, a failed fetch or release lookup, a dirty clone, another run in progress |
| 10 | The iPhone isn't reachable; its install is skipped and retried next run |
| 20 | Merge conflict; the merge stays in progress in the clone |
| 21 | The merge doesn't build; nothing is pushed or installed |
| 22 | Pushing the merge failed |
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

- Built in a staging worktree, `~/.hex-fork/ios-src`, so the repo is never rewritten. The script reads the
  app's bundle ID from `ios/project.yml` and replaces it under `ios/` (Swift, entitlements, `project.yml`) with
  `io.veraze.hex.mobile`, which moves the extensions, the App Group, and any keychain group with it.
  `ios/project.fork.yml` includes `project.yml` and sets team 67A6AV33K9 and the names "Hex Fork" and
  "Hex Fork Keyboard".
- `xcodebuild -allowProvisioningUpdates` builds Release with the team's profiles for `io.veraze.hex.mobile`,
  and `xcrun devicectl device install app` installs it on Derek888 over Wi-Fi.
- The iPhone app has no in-app updater.

Environment overrides: `HEX_FORK_HOME`, `HEX_FORK_BRANCH`, `HEX_FORK_REPO`, `HEX_FORK_UPSTREAM_REPO`, `HEX_FORK_TEAM_ID`, `HEX_FORK_IPHONE`, `HEX_FORK_IOS_BUNDLE_PREFIX`, `HEX_FORK_IOS_APP_NAME`, `HEX_FORK_IDLE_WAIT`.
