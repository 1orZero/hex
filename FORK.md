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
the Dropline private API provider (see "Dropline private API"), the iPhone vocabulary link (see
"Vocabulary"), screen text (see "Screen text"), and Traditional Chinese in Annotate and meetings (see
"Traditional Chinese in Annotate and meetings"). Every hook in a file all three OSes build runs only on macOS
(behind `#[cfg(target_os = "macos")]`, or after `build.rs`'s macOS check), so Linux and Windows build
upstream's code unchanged. The `crates/capture/build.rs` row and the `clean_summary` cut in
`src/meeting/notes.rs` are upstream fixes carried before a release has them, not hooks.

| Upstream file | Hook | Purpose |
| --- | --- | --- |
| `src/main.rs` | `mod fork;` (macOS) after `mod feedback;` | Compiles the fork module. |
| `src/parakeet.rs` | `InferenceJob.dropline` field; `fork::dropline::job(&samples)` after `diagnostics::persist` in the submit path; `fork::dropline::wait(job.dropline, job.transcript)` in `run_inference_worker` | The dictation-finish point: takes the clip for Dropline and picks Dropline's text or the local one. |
| `src/recognition.rs` | `fork::dropline::prepare()` after `worker.prepare_paste()` on capture start | Opens the Dropline session early (best effort). |
| `src/macos_rune.rs` | `fork::dropline::deselect()` in `StatusItemAction::SelectModel` | Choosing a local model in the menu bar stops using Dropline. |
| `src/rune_ui.rs` | `mod fork_dropline;`, `Ui.fork_dropline` field and its default, both behind `#[cfg(target_os = "macos")]` | The picker section's form state, which only macOS reads. |
| `src/rune_ui/picker.rs` | `fork_dropline::model_chosen()` at the top of `choose`; `content.children(fork_dropline::section(ui, p))` after the body in `modal` | Choosing a local model in the picker stops using Dropline; the picker's last section adds, uses, and deletes the provider. |
| `src/rune_ui/general.rs` | `fork_dropline::model_name(ui, model.name)` in the Speech model button; `description.or_else(\|\| fork_dropline::status(ui, p))` after the description match | General names Dropline while it is in use and shows the last fallback. |
| `src/capture_host.rs` | `scrawl_engine`: `let transcriber = crate::fork::annotate::traditional(transcriber);` first (macOS, 2 lines) | Annotate's capture engine transcribes through the conversion, whichever of Hex's model or Apple Speech `ChosenTranscriber` picks. |
| `src/capture_host/replay.rs` | after `let transcriber = ChosenTranscriber;` in the replay's finish: `let transcriber = crate::fork::annotate::Traditional(std::sync::Arc::new(transcriber));` (macOS, 2 lines) | The 15 s replay transcribes with its own `ChosenTranscriber`, outside the engine. |
| `src/meeting/transcript.rs` | `TrackTranscript::accept`: `let transcript = crate::fork::traditional::transcript(transcript);` first (macOS, 2 lines) | Every meeting chunk before its words are joined with spaces: the in-call draft, Copy new and ⌥⌃V, the final pass, a track rebuilt from its WAV, and imports. |
| `src/meeting/notes.rs` | `clean_title` and `clean_summary`: `let title = &crate::fork::traditional::text(title);` (and `summary`) first (macOS, 2 lines each) | Generated text from either notes writer (Apple Intelligence or OpenCode): the final title and summary, the provisional title, and chapter titles (`chapters::clean_topic` calls `clean_title`). |
| `src/meeting/notes.rs` | `clean_summary`: `.unwrap_or_else(\|\| text.floor_char_boundary(MAX_SUMMARY_CHARS))` in place of `.unwrap_or(MAX_SUMMARY_CHARS)` (1 line) | Upstream fix: a summary over 400 bytes without a space (Chinese) was cut inside a character and panicked (`meeting::fork_tests::a_long_chinese_summary_without_spaces_is_cut_at_a_character`). Upstream `dev` still has the bug; take upstream's line once a release fixes it. |
| `src/meeting/chapters.rs` | `clean_summary`: `let summary = &crate::fork::traditional::text(summary);` first (macOS, 2 lines) | Live chapter summaries. |
| `src/meeting.rs` | `#[cfg(all(test, target_os = "macos"))] mod fork_tests;` at the end (3 lines) | The fork's tests that need the meeting module's private functions. |
| `ios/HEXMobile/DictationController.swift` | `finishRecording()`: `activeTranscriber.transcribe(` becomes `activeTranscriber.transcribePreferringDropline(` with the same arguments | The iPhone dictation-finish point: Dropline first, the local engine on failure. |
| `ios/HEXMobile/DictationController.swift` | `startRecording(...)`: `ForkDroplineRecognition.prepare(hints: vocabularyTerms)` after `let vocabularyTerms = …` | Opens the Dropline session early (best effort). |
| `ios/HEXMobile/ContentView.swift` | `standaloneView`: `ForkDroplineSettingsCard()` between `settingsCard` and `ExperimentsCard()` | Adds, selects, and deletes the provider. |
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler for vocabulary links; upstream's handler ignores hosts other than `keyboard`. |
| `ios/HEXMobile/CustomVocabularyEditor.swift` | `.onReceive(… .forkVocabularyLinkAdded)` after the editor's `.onAppear` (3 lines) | Reloads the editor's cached list after a link adds a term; otherwise the editor's next add or remove writes its stale list back and drops the linked term. |
| `build.rs` | `compile_swift_bridge("fork/screen_text", …)` and the Vision link, after the calendar bridge (2 lines) | Builds screen text's Swift bridge, `src/fork/screen_text.swift`. |
| `src/recognition/context_watch.rs` | `ContextWatch.screen_text` (the last field) and `ScreenTextRead::start()` in `start`; `self.screen_text.begin()`, `.intend()`, `.cancel()` at the end of `begin`, `intend`, and `cancel`; `finish` takes `self.screen_text.finish()`, calls `finish_snapshot` (the old body of `finish`), and sets `snapshot.fork_screen_text` (16 lines) | One read per capture, started when the capture becomes real or when a short tap finishes, dropped by a cancel, and handed to the snapshot `finish` returns. |
| `src/recognition.rs` | `handle_hotkey_action`, `HotkeyAction::Start`: `context.screen_text.raw(raw)` after `context.begin()` (1 line) | A raw dictation (the raw shortcut, `hex dictation start --raw`) runs no transformation, so it reads nothing. |
| `src/dictation/context.rs` | `ContextSnapshot.fork_screen_text` (macOS), the last field; `fork_screen_text: Default::default()` in `snapshot_of` and in `capture_for_meeting`'s two `Self { … }` (6 lines) | The snapshot a capture finishes with carries its read. |
| `src/dictation/processor.rs`, `src/meeting/detection.rs` | `fork_screen_text: Default::default()` (macOS) in the tests' `context` helpers (2 lines each) | Struct literals that name every field need the new one. |
| `src/personal_commands.rs` | `InvocationContext.screen_lines` (macOS) after `window_title`; `screen_lines: context.fork_screen_text.lines()` in `invocation_context`; `mod fork_screen_text_tests` (`#[path]` to `src/fork/screen_text/transformation_tests.rs`) at the end of the file (9 lines) | Each transformation chain waits for its dictation's read and passes it as `screenLines`; the test module runs a real config against the worker. |
| `src/personal_commands/hex.d.ts` | `screenLines?: readonly string[]` at the end of `HandlerContext` (2 lines) | Types the field for configs. |
| `crates/capture/build.rs` | `compile_helper`: `profile_dir` is the parent of the `build` directory in `OUT_DIR`, not `out_dir.ancestors().nth(3)` | Upstream backport: anomalyco/hex#1734 (`db338045`), cherry-picked unchanged with `-x`, which also touches `.github/workflows/build-desktop.yml` and `docs/plans/capture-in-hex.md`. Under cargo 1.100's build-dir layout, v3.4.0 puts `scrawl-helper` in `target/release/build/`, so `scripts/build-app.sh` can't copy it from `target/release/`. The row goes away once a release that includes #1734 is merged; until then, take upstream's version on a conflict. |

The window hooks draw nothing in scenes and tests (`Ui::live` is false), so the goldens are unchanged.

Apart from screen text's hooks (see "Screen text"), a trial merge of upstream `dev` at a394af280
(2026-11-25, not pushed) conflicts only at earlier hooks:
`src/parakeet.rs`, `src/recognition.rs`, `src/rune_ui.rs`, `src/rune_ui/general.rs`, and
`src/rune_ui/picker.rs` (Dropline dictation), and three files under `ios/`, which this branch no longer
builds. The Traditional Chinese hooks merge cleanly: `dev` moved `ChosenTranscriber` to
`src/capture_host/words.rs`, but `scrawl_engine` and the replay's `let transcriber = ChosenTranscriber;`
are still where the hooks expect them.

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
- `src/fork/screen_text.rs`, `src/fork/screen_text.swift`, `src/fork/screen_text/transformation_tests.rs`, and
  `tests/fixtures/fork/qa-screen-text.png`: screen text (see "Screen text").
- `src/fork/traditional.rs`, `src/fork/annotate.rs`, and `src/meeting/fork_tests.rs`: Traditional Chinese in
  Annotate and meetings.
- `fork/docs/`: the glossary (`GLOSSARY.md`) and the decisions (`adr/`) behind the fork's meeting, Annotate,
  and screen text features, in Traditional Chinese as Derek accepted them.

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

- `src/fork/dropline/client.rs` calls `src/fork/dropline/text.rs` on a successful `final_text` before
  the dictation worker receives it. Apple's offline `Hans-Hant` transform changes Han characters,
  not regional terms: `软件` becomes `軟件`, not `軟體`. The client keeps common existing spellings
  such as `了解` and the Cantonese particle `吓`, and uses Taiwan forms such as `啟` for `启`.
  It skips backtick-quoted code, Han identifiers marked by an underscore, and runs with kana or Hangul.
  For mixed Chinese text, it uses a simplified copy to look up the whole phrase and keeps the input
  characters that were already distinctly traditional. This distinguishes `干擾` from `干燥` without
  treating either spelling as a rule for every name or phrase. Local and fallback transcripts bypass
  this parser.
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

## Traditional Chinese in Annotate and meetings

Mac only. Annotate and meetings keep transcribing with the local model; their text goes through the same
conversion as Dropline's answers (`src/fork/dropline/text.rs`, re-exported as `crate::fork::traditional::text`),
so identifiers, the Cantonese particle `吓`, and Taiwan forms come out the same everywhere. Times never change.

- Timed words convert as one run without separators, then each word gets back as many characters as it had:
  the conversion reads context, and a phrase a model split across words (`头` + `发`) would otherwise become
  `頭發` instead of `頭髮`. A word's own leading and trailing spaces stay in place; between two Chinese
  words they don't split the run, but beside an identifier, code, kana, or Hangul they still do, as in the
  transcript's text. When the run's conversion changes its length, each word converts on its own and only
  their count is logged. A transcript's text and each segment convert whole.
- Annotate: the capture engine's transcriber and the 15 s replay's convert `text`, `segments`, and `words`,
  so `summary.md`, `scrawl.json`, each keyframe's narration, the clipboard, and Paste read converted text.
  Not converted: the retranscription Scrawl runs after Apple's speech model downloads
  (`crates/capture/src/speech_model.rs`) and Apple's live-transcription experiment
  (`crates/capture/src/live_transcribe.rs`), which run outside these transcribers; neither runs with
  `capture.transcriber = parakeet`.
- Meetings: every chunk converts as the track accepts it, so the in-call draft, Copy new and ⌥⌃V, the final
  transcript, its Markdown, and `hex meetings` read converted text. Generated titles, summaries, and chapters
  convert in the shared cleaners, whichever writer produced them. A title the user typed, calendar names,
  hand-edited notes, links, and exported files are left alone.
- The summary prompt is English and names no output language, so a writer may still answer in English.

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
runs `fork/vocabulary.py` from `~/.hex-fork/repo` before `fork/daily.sh` to keep the most used terms in front
and to add new ones; `fork/daily.sh` then copies the result to the iPhone (see "The Mac's vocabulary on
the iPhone"):

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

## Screen text

While a dictation records, the Mac app reads the front window's text with Vision and passes the lines to
that dictation's transformations as `context.screenLines`, top to bottom and each row left to right. It
does what Derek's `hex-screen-ocr` LaunchAgent did from another process through
`~/.local/share/hex-lab/screen.json`, for his `jev` transformation.

- Only while some mode uses a script transformation, the condition under which Hex reads the window
  title. A capture reads once: when it becomes real (held past the hold threshold, a control start, or a
  released microphone opening), or, for a short tap, when it finishes. A discarded or cancelled press and
  a raw dictation read nothing.
- The window is the frontmost on-screen one at layer 0, wider and taller than 50 points, that no Hex
  build (`anomaly.hex`, `anomaly.hex.*`) owns, chosen as the read starts. Only that window is captured
  (ScreenCaptureKit, at most 2800 px on its longer side, without the cursor); if it has closed by then,
  nothing is read and no other window is captured. Vision reads it with `.accurate`, `en-US`, and no
  language correction. Lines whose centers are closer than half a line's height form one row.
- Before every read Hex checks Screen Recording with `CGPreflightScreenCaptureAccess`. It never asks:
  without the permission nothing is listed or captured, and dictation works as before. macOS keeps a
  process's first answer, so Hex starts reading only after it is reopened once Screen Recording is allowed.
- The read belongs to the snapshot its capture finished with, so two overlapping dictations each get
  their own. A transformation chain waits up to 500 ms for it, as `screen.ts` did. A late, failed, or
  unpermitted read leaves `screenLines` out, and a late one is stopped. At most 400 lines and 32 KiB pass.
- Every custom transformation in the chain sees the same `screenLines`, as with `windowTitle`. Hex keeps
  the lines in memory only and logs counts and durations (`fork screen text: …`), never text.
- When the listener starts with a script transformation set up and Screen Recording allowed, Vision loads
  on a background thread; the helper once saw 43 s for a first read after a restart. The model then stays
  in Hex's memory.
- Screen text never reaches speech recognition or Dropline. Dropline's prompt is Hex's vocabulary
  (`vocabulary::terms()`), which the read never touches. When upstream's Words on screen (Labs,
  `screen-vocabulary`, on `dev`) reaches a release, check that its terms stay out of `vocabulary::terms()`
  too, or Dropline's prompt would carry them.

A trial merge of upstream `dev` (`a394af280`) conflicts in five of the hook files. In
`src/recognition/context_watch.rs`, Words on screen and Rewrite reads nearby text add `screen` and `caret`
fields and split `finish` into `finish` and `finish_snapshot` the same way: keep both sides' fields, and
in `finish` take `self.screen_text.finish()` before `finish_snapshot` and set `fork_screen_text` beside
`screen_terms`. In `src/dictation/context.rs`, `src/dictation/processor.rs`, and `src/meeting/detection.rs`,
`dev` adds `screen_terms`, `caret_text`, and `bundle_name` where the fork adds `fork_screen_text`: keep
both. `dev` moves `handle_hotkey_action` from `src/recognition.rs` to `src/recognition/capture_actions.rs`:
take `dev`'s `recognition.rs` and put `context.screen_text.raw(raw)` back after `context.begin()` there
(the Dropline `prepare()` hook moves with it). `build.rs`, `src/personal_commands.rs`, and `hex.d.ts`
merge cleanly.

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
   the iPhone app was installed in this run, or `--force` is given, copy the file to
   `Library/fork-mac-vocabulary.json` in the App Group `group.io.veraze.hex.mobile` with
   `xcrun devicectl device copy to --domain-type appGroupDataContainer`. devicectl can't write to the
   container's root (CoreDeviceError 7000), so the file goes under `Library/`.
   The iPhone app folds it into its list as `ios-stable`'s `FORK.md` describes, the next time the keyboard
   or Hex comes on screen, without Derek opening Hex.
3. `--no-push` reads and compares only (`changed` or `up-to-date`).

The file holds names and email addresses, so it is written owner-only under `~/.hex-fork/state/` and never
inside a repository or a build. Copying rather than building it into the app means a changed vocabulary
needs no rebuild or reinstall, which would close the keyboard and Hex on the iPhone each night. The nightly
vocabulary upkeep (`fork/vocabulary.py apply`) should run before `daily.sh`, so the iPhone gets the
same night's order.

Environment overrides: `HEX_FORK_HOME`, `HEX_FORK_BRANCH`, `HEX_FORK_IOS_BRANCH`, `HEX_FORK_REPO`, `HEX_FORK_UPSTREAM_REPO`, `HEX_FORK_TEAM_ID`, `HEX_FORK_IPHONE`, `HEX_FORK_IOS_BUNDLE_PREFIX`, `HEX_FORK_IOS_APP_NAME`, `HEX_FORK_IDLE_WAIT`, `HEX_FORK_HEX` (the `hex` command the vocabulary is read with).
