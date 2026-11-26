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
"Vocabulary"), screen text (see "Screen text"), Traditional Chinese in Annotate and meetings (see
"Traditional Chinese in Annotate and meetings"), meetings through Dropline (see "Meetings through
Dropline"), the Output pane's switches (see "Output switches"), and continued dictations in History (see
"Continued dictations in History"). Every hook in a file all three OSes build runs only on macOS (behind
`#[cfg(target_os = "macos")]`, or after `build.rs`'s macOS check), so Linux and Windows build upstream's
code unchanged. The `clean_summary` cut in `src/meeting/notes.rs` and the
`keep_across` hook in `src/meeting/transcript.rs` are upstream fixes carried before a release has
them, not features.

| Upstream file | Hook | Purpose |
| --- | --- | --- |
| `src/main.rs` | `mod fork;` (macOS) after `mod feedback;` | Compiles the fork module. |
| `src/parakeet.rs` | `InferenceJob.dropline` field; `fork::dropline::job(&samples, submitted_at)` after `diagnostics::persist` in the submit path; `fork::dropline::wait(job.dropline, job.transcript)` in `run_inference_worker` | The dictation-finish point: takes the clip for Dropline and picks Dropline's text or the local one. |
| `src/parakeet.rs` | `InferenceJob.transcript: crate::fork::dropline::Local` in place of `PendingTranscript` (and `PendingTranscript` dropped from the `transcription::engine` import); `crate::fork::dropline::local(&dropline, engine, stream, samples, offline)` in place of `engine.finish_with(stream, samples, offline)` in the submit path | While Dropline takes the clip, the local model transcribes it only after Dropline fails. Without Dropline, or with a live stream, the engine starts it at once as upstream does. |
| `src/dictation.rs` | `begin_stream`: `#[cfg(target_os = "macos")] if self.fork_dropline_live() { return; }` at the top (4 lines); `#[cfg(target_os = "macos")] #[path = "fork/dropline/live.rs"] mod fork_dropline_live;` at the end of the file (4 lines) | While Dropline is selected a hotkey capture opens no local stream, and Dropline gives its live text. The module sits in `src/fork/dropline/` but is `dictation`'s child, so it reads the private recording. |
| `src/dictation/modes/output.rs` | `record_history`: `#[cfg(target_os = "macos")] model: crate::fork::dropline::history_model(input.total_started),` before upstream's `model: crate::history::dictation_model(),`, which gets `#[cfg(not(target_os = "macos"))]` (3 lines) | History names what made the text: Dropline, or the local model marked as Dropline's fallback. On macOS `input.total_started` is the job's `submitted_at` (`run_inference_worker` in `src/parakeet.rs`), the same instant `job` received. All three OSes build this file, so the other OSes keep upstream's line. |
| `src/recognition/capture_actions.rs` | `handle_hotkey_action`, `HotkeyAction::Start`: `crate::fork::dropline::prepare();` after `worker.prepare_paste();` (1 line) | Opens the Dropline session early (best effort). |
| `src/macos_rune.rs` | `fork::dropline::deselect()` in `StatusItemAction::SelectModel` | Choosing a local model in the menu bar stops using Dropline. |
| `src/rune_ui.rs` | `mod fork_dropline;`, `Ui.fork_dropline` field and its default, both behind `#[cfg(target_os = "macos")]` | The picker section's form state, which only macOS reads. |
| `src/rune_ui/picker.rs` | `fork_dropline::model_chosen()` at the top of `choose`; `content.children(fork_dropline::section(ui, p))` after the body in `modal` | Choosing a local model in the picker stops using Dropline; the picker's last section adds, uses, and deletes the provider. |
| `src/rune_ui/picker/compare.rs`, `src/rune_ui/picker/list.rs` | `#[cfg(target_os = "macos")] State::InUse if crate::rune_ui::fork_dropline::local_is_fallback(ui) => { … fallback_badge(p) }` before `State::InUse => facts::in_use(p),` (4 lines each) | While Dropline is in use, the local model's card and row read 失敗時改用 instead of In use. |
| `src/rune_ui/general.rs` | `fork_dropline::model_name(ui, model.name.as_ref())` in the Speech model button; `let description = description.or_else(\|\| super::fork_dropline::status(ui, p));` right before the `rows.push(icon_described_row(… "transcription" …))` that shows the row | General names Dropline while it is in use and shows the last fallback. |
| `src/capture_host.rs` | `scrawl_engine`: `let transcriber = crate::fork::annotate::traditional(transcriber);` first (macOS, 2 lines) | Annotate's capture engine transcribes through the conversion, whichever of Hex's model or Apple Speech `ChosenTranscriber` picks. |
| `src/capture_host/replay.rs` | after `let transcriber = ChosenTranscriber;` in the replay's finish: `let transcriber = crate::fork::annotate::Traditional(std::sync::Arc::new(transcriber));` (macOS, 2 lines) | The 15 s replay transcribes with its own `ChosenTranscriber`, outside the engine. |
| `src/meeting/transcript.rs` | `TrackTranscript::accept`: `let transcript = crate::fork::traditional::transcript(transcript);` first (macOS, 2 lines) | Every meeting chunk before its words are joined with spaces: the in-call draft, the final pass, a track rebuilt from its WAV, and imports. |
| `src/meeting/transcript.rs` | `TrackTranscript::accept`, a segmented chunk after a hard cut: `crate::fork::meeting_seam::keep_across(&mut incoming, &self.entries, seam);` between `self.entries.retain(…)` and `incoming.retain(…)` (macOS, 2 lines) | Upstream fix: the join keeps an incoming segment only if it starts after the middle of the 2 s overlap, so a segment that starts inside the overlap and runs past it was dropped with all of its new speech. A model that answers a chunk as one segment (Qwen3-ASR, also Whisper's longer segments) lost every chunk after a hard cut, which speech with no pause between 6 s and 10 s into a chunk causes. The hook moves that segment to the seam without the speech the kept entries end with; when the two chunks hear the overlap too differently to find that repeat, the segment is kept whole and up to 2 s can show twice (`fork::meeting_seam`, `meeting::fork_tests::a_hard_cut_keeps_the_new_speech_of_a_chunk_answered_as_one_segment`). v3.4.0 and upstream `dev` at df3f3e41b (2026-11-26) have the bug, with the same two `retain` lines; drop the row once a release keeps such segments. |
| `src/meeting/notes.rs` | `clean_title` and `clean_summary`: `let title = &crate::fork::traditional::text(title);` (and `summary`) first (macOS, 2 lines each) | Generated text from either notes writer (Apple Intelligence or OpenCode): the final title and summary, the provisional title, and chapter titles (`chapters::clean_topic` calls `clean_title`). |
| `src/meeting/notes.rs` | `clean_summary`: `.unwrap_or_else(\|\| text.floor_char_boundary(MAX_SUMMARY_CHARS))` in place of `.unwrap_or(MAX_SUMMARY_CHARS)` (1 line) | Upstream fix: a summary over 400 bytes without a space (Chinese) was cut inside a character and panicked (`meeting::fork_tests::a_long_chinese_summary_without_spaces_is_cut_at_a_character`). Upstream `dev` still has the bug; take upstream's line once a release fixes it. |
| `src/meeting/chapters.rs` | `clean_summary`: `let summary = &crate::fork::traditional::text(summary);` first (macOS, 2 lines) | Live chapter summaries. |
| `src/meeting.rs` | `#[cfg(all(test, target_os = "macos"))] mod fork_tests;` at the end (3 lines) | The fork's tests that need the meeting module's private functions. |
| `src/meeting.rs` | `record`: `let _dropline = crate::fork::dropline::meeting::start(&meeting_dir);` after `let given_title = …;` (macOS, 2 lines) | A meeting that starts while Dropline is selected sends its audio to Dropline; the guard lives until `record` returns, after the final pass. |
| `src/meeting.rs` | `write_tracks`: `crate::fork::dropline::meeting::offer(directory, packet.source, packet.position, packet.sample_rate, &packet.samples)` after the packet's samples are written (macOS, 8 lines) | Hands each packet, at its place in the WAV (gaps padded), to the meeting's cutter without waiting. |
| `src/meeting/sweep.rs` | `remove_orphaned_imports`: `crate::fork::dropline::meeting::clear_owed();` first (macOS, 2 lines); the sweep runs once per launch, and upstream `dev` calls it from `src/meeting/recovery.rs` | Once per launch: finds each meeting that sent audio and has no clear outcome, before retention expiry runs, and clears for it on its own thread, including meetings waiting for a final pass that may not run. |
| `src/meeting/transcript.rs` | `transcribe`: `let join_entries = \|entries, origin_ms, envelope\| { crate::fork::dropline::meeting::join(directory, manifest, entries, origin_ms, envelope, join_entries) };` before `Ok(join_entries(…))` (macOS, 11 lines) | The final pass, also when the next launch finishes a meeting: the local merge and echo suppression run as before, then answered segments put Dropline's words in the entries they cover. |
| `ios/HEXMobile/DictationController.swift` | `finishRecording()`: `activeTranscriber.transcribe(` becomes `activeTranscriber.transcribePreferringDropline(` with the same arguments | The iPhone dictation-finish point: Dropline first, the local engine on failure. |
| `ios/HEXMobile/DictationController.swift` | `startRecording(...)`: `ForkDroplineRecognition.prepare(hints: preferences.recognitionHints)` after `let sharesHeard = …` | Opens the Dropline session early (best effort). |
| `ios/HEXMobile/ContentView.swift` | `homeView`: `ForkDroplineSettingsCard()` and a blank line after the Settings pages card (`.padding(.top, 8)`) | Adds, selects, and deletes the provider. |
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler for vocabulary links; upstream's handler ignores hosts other than `keyboard`. |
| `ios/HEXMobile/CustomVocabularyEditor.swift` | `.onReceive(… .forkVocabularyLinkAdded)` after upstream's `.onReceive(… .hexWordsListsDidChange)`, which follows the editor's `.onAppear` (3 lines) | Reloads the editor's cached list after a link adds a term; otherwise the editor's next add or remove writes its stale list back and drops the linked term. |
| `build.rs` | `compile_swift_bridge("fork/screen_text", …)` and the Vision link, after the calendar bridge (2 lines) | Builds screen text's Swift bridge, `src/fork/screen_text.swift`. |
| `src/recognition/context_watch.rs` | `ContextWatch.screen_text` (the last field, after upstream's `screen` and `caret`) and `ScreenTextRead::start()` in `start`; `self.screen_text.begin()`, `.intend()`, `.cancel()` at the end of `begin`, `intend`, and `cancel`; in `finish`, `let screen_text = self.screen_text.finish();` before `finish_snapshot` and `snapshot.fork_screen_text = screen_text;` before `Ok(snapshot)` (8 lines) | One read per capture, started when the capture becomes real or when a short tap finishes, dropped by a cancel, and handed to the snapshot `finish` returns. |
| `src/recognition/capture_actions.rs` | `handle_hotkey_action`, `HotkeyAction::Start`: `context.screen_text.raw(raw);` after `context.begin();` (1 line) | A raw dictation (the raw shortcut, `hex dictation start --raw`) runs no transformation, so it reads nothing. |
| `src/dictation/context.rs` | `ContextSnapshot.fork_screen_text` (macOS), the last field, after upstream's `bundle_name`; `fork_screen_text: Default::default()` after `bundle_name` in `snapshot_of` and in `capture_for_meeting`'s two `Self { … }` (6 lines) | The snapshot a capture finishes with carries its read. |
| `src/dictation/processor.rs`, `src/meeting/detection.rs` | `fork_screen_text: Default::default()` (macOS) in the tests' `context` helpers (2 lines each) | Struct literals that name every field need the new one. |
| `src/personal_commands.rs` | `InvocationContext.screen_lines` (macOS) after `window_title`; `screen_lines: context.fork_screen_text.lines()` in `invocation_context`; `mod fork_screen_text_tests` (`#[path]` to `src/fork/screen_text/transformation_tests.rs`) at the end of the file (9 lines) | Each transformation chain waits for its dictation's read and passes it as `screenLines`; the test module runs a real config against the worker. |
| `src/personal_commands/hex.d.ts` | `screenLines?: readonly string[]` at the end of `HandlerContext` (2 lines) | Types the field for configs. |
| `src/rune_ui.rs` | `#[cfg(target_os = "macos")] mod fork_output;` after `mod fork_dropline;` (2 lines) | Compiles the Output switches' section. |
| `src/rune_ui/output.rs` | `pane`: a `#[cfg(target_os = "macos")]` block with `content = content.child(super::fork_output::section(ui, p));` right after `content = content.child(every_dictation(…));` (4 lines) | Output's 轉換選項 section, below Every dictation, with 讀取螢幕文字 and 使用 Jev. |
| `src/dictation/modes/output.rs` | `record_history`: `match history.record(draft)` becomes `match recorded`, with `#[cfg(target_os = "macos")] let recorded = crate::history::fork_continued::record(history, draft, &input.text);` and `#[cfg(not(target_os = "macos"))] let recorded = history.record(draft);` before it (5 lines) | A dictation whose paste joined the previous dictation's paste is added to that dictation's entry instead of becoming a new one. The other OSes keep upstream's call. |
| `src/paste/macos.rs` | `Paster::insert_text`: `crate::history::fork_continued::paste(text, self.continuation.join(revision, joinable, text).is_some());` after `let joinable = …;` (4 lines) | Tells History whether each paste continues the one before it, with the same check the join right after it makes (`Continuation::join` changes nothing). |
| `src/history.rs` | `#[cfg(target_os = "macos")] #[path = "fork/history_continued.rs"] pub(crate) mod fork_continued;` at the end of the file (4 lines) | The module sits in `src/fork/` but is `history`'s child, so it changes the store's entries, recordings, and rollup the way `record` does. |
| `scripts/file-size-exceptions.txt`, `scripts/folder-shape-exceptions.txt` | `src/dictation.rs 1503` and `src/meeting.rs 1501` added, `src/meeting/transcript.rs` raised from upstream's ceiling to 1943; `src/rune_ui 62` added (4 lines) | Upstream's code-shape check (`scripts/code-shape.py`, and the `code_shape_tests::repo_satisfies_code_shape` test) fails files over 1,500 non-test lines and folders over 60 files. The hooks above push these three files past their limits, and `src/rune_ui/fork_dropline.rs` and `src/rune_ui/fork_output.rs` push `src/rune_ui` past 60. On a conflict, take upstream's files and set these entries to the counts `python3 scripts/code-shape.py --check` reports. |

The window hooks draw nothing in scenes and tests (`Ui::live` is false), so the goldens are unchanged.

Merging v3.5.0 moved these hooks: `handle_hotkey_action` went from `src/recognition.rs` to
`src/recognition/capture_actions.rs`, `record_history` from `src/parakeet.rs` to
`src/dictation/modes/output.rs`, and the Output pane lost its Try card, so 轉換選項 now follows Every
dictation. Words on screen and Rewrite reads nearby text added `screen_terms`, `caret_text`, and
`bundle_name` where the fork adds `fork_screen_text`; the fork's field stays after them. v3.5.0 includes
anomalyco/hex#1734, so the fork no longer carries it in `crates/capture/build.rs`.

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
- `src/rune_ui/fork_output.rs`: the Output switches (see "Output switches").
- `src/fork/history_continued.rs`: continued dictations in History (see "Continued dictations in History").
- `src/fork/traditional.rs`, `src/fork/annotate.rs`, and `src/meeting/fork_tests.rs`: Traditional Chinese in
  Annotate and meetings.
- `src/fork/dropline/meeting.rs` and `src/fork/dropline/meeting/`: meetings through Dropline.
- `src/fork/meeting_seam.rs`: meeting segments that run across a hard cut (see the
  `src/meeting/transcript.rs` `keep_across` row); its end-to-end test is in `src/meeting/fork_tests.rs`.
- `fork/docs/`: the glossary (`GLOSSARY.md`) and the decisions (`adr/`) behind the fork's meeting, Annotate,
  and screen text features, in Traditional Chinese as Derek accepted them.

## Dropline private API

A custom transcription provider, "Dropline 私人 API", in the Mac and iPhone apps. While it is selected, a
finished dictation's recording is sent to Dropline's private API and its text replaces the local model's;
the rest of the pipeline (corrections, modes, transformations, paste) is unchanged. When Dropline
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
- No other speech model runs while Dropline is selected: a hotkey capture opens no local live stream, and
  the local model transcribes the finished clip only after Dropline fails. The local model stays loaded for
  that fallback. General and the model picker show the last fallback.
- Live text (`src/fork/dropline/live.rs`): with Labs › Live text on (or during the first run's practice),
  a hotkey capture past its hold threshold shows no live text until Dropline's first words, and every 4 s
  sends the whole recording so far to Dropline in the session and with the vocabulary the final request
  uses. That is at most 15 requests a minute: a round is skipped, not made up, while the previous request
  is out, and none goes once the recording passes 180 s, which keeps the last words shown. An empty answer changes nothing; a failed one is
  logged by reason and changes nothing. With Live text off, nothing is sent until the recording finishes.
- History's Speech model names what made each dictation's text: `Dropline 私人 API` when Dropline
  answered, the local model followed by `（Dropline 失敗後改用）` when it fell back (for example
  `Qwen3-ASR 1.7B（Dropline 失敗後改用）`), and the local model alone when Dropline wasn't selected.
  History's search matches the same text (`hex history` doesn't print the model). Inference is how long
  the text took: Dropline's request when it answered, or Dropline's attempt plus the local transcript when
  it fell back. The fallback's model is read when the local transcript finishes, so a model chosen before History records the dictation doesn't
  rename it. Answers live in memory by submission instant until History records the dictation or 16
  newer answers push them out (a dictation History never records: cancelled, no speech, a failed paste,
  the local API's).
- While Dropline is in use, the picker's local model reads 失敗時改用 where it read In use; Dropline's row
  reads 使用中.
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
  `頭發` instead of `頭髮`. A word's own leading and trailing spaces stay in place. A space joins the run
  only where a Chinese character meets a Chinese character and neither word holds an identifier's `_`, a
  backtick, kana, or Hangul; anywhere else it still separates the words, as in the transcript's text. When the run's conversion changes its length, each word converts on its own and only
  their count is logged. A transcript's text and each segment convert whole.
- Annotate: the capture engine's transcriber and the 15 s replay's convert `text`, `segments`, and `words`,
  so `summary.md`, `scrawl.json`, each keyframe's narration, the clipboard, and Paste read converted text.
  Not converted: the retranscription Scrawl runs after Apple's speech model downloads
  (`crates/capture/src/speech_model.rs`) and Apple's live-transcription experiment
  (`crates/capture/src/live_transcribe.rs`), which run outside these transcribers; neither runs with
  `capture.transcriber = parakeet`.
- Meetings: every chunk converts as the track accepts it, so the in-call draft, the final
  transcript, its Markdown, and `hex meetings` read converted text. Generated titles, summaries, and chapters
  convert in the shared cleaners, whichever writer produced them. A title the user typed, calendar names,
  hand-edited notes, links, and exported files are left alone.
- The summary prompt is English and names no output language, so a writer may still answer in English.

## Meetings through Dropline

Mac only. A meeting that starts while Dropline is selected sends its audio to Dropline in segments while it
records, and the final transcript takes Dropline's words where they line up with the local transcript. The
in-call draft stays local (ADR-0003; upstream removed Copy new and ⌥⌃V in v3.5.0). `src/fork/dropline/meeting.rs` runs it;
`fork/docs/adr/` has the decisions.

- Start: the selection, the token endpoint, the bearer, and the vocabulary are read once, when the meeting
  starts, and hold for the whole meeting. Without Dropline selected, nothing starts: no threads, no file,
  no network.
- Segments: each track's packets come from the WAV writer with their positions in the WAV, resampled to
  16 kHz. A segment ends in the middle of the first pause of 0.5 s or more (25 blocks of 20 ms) once it is
  70% of 178 s long, and at 178 s otherwise. A block counts as a pause below the 10th-percentile level of
  the segment's first 70% plus 6 dB, and never below 45 on the 20 ms level scale that dictation uses
  (`src/fork/dropline/audio.rs`). A gap in the positions ends a segment, and segment times are WAV
  positions, gaps included. A tail shorter than 500 ms isn't sent, and a segment with no block above the
  threshold is recorded as answered with no text and isn't sent. Packets the cutter can't take in time
  (4,096 behind) become a gap that keeps local text.
- Sending: each segment is encoded as Ogg Opus and queued; at most 20 wait, and later ones fail. The meeting
  sends one segment at a time on its own threads with its own token, and never touches dictation's
  prepared session or the status General shows. The vocabulary goes as context. The text is
  `transcript.text`, else `final_text`, through the same Traditional conversion.
- Retries (ADR-0005): each request gets 60 s. A 429 waits for `Retry-After` (5 s without it, at most 60 s,
  at most 10 times) and doesn't count as a send; a 502–504, a network error, or a timeout is sent at most
  twice; a 401 fetches a new token once; other statuses and bad answers aren't resent. An authorization
  failure (no provider, the token endpoint refusing, the Worker refusing the bearer, a second 401, or
  Dropline answering 403) stops the meeting's sends.
- Final pass: Stop cuts each track's tail and waits up to 3 minutes for the queue, and gives up at once when
  Hex is quitting; segments still unanswered fail. The local transcript is merged and echo-suppressed as
  before. Then each local entry takes part in the alignment of every answered segment it overlaps and takes
  the part of Dropline's text aligned with it (characters compared in Simplified form, without spaces or
  punctuation, lower case), its ends moved to nearby punctuation (not an ASCII mark or `’` between two
  ASCII letters or digits, as in `1.5` or `can't`) and never inside a word (letters and digits of a
  script written with spaces, with ASCII marks and `’`), so a word Dropline corrected or joined stays
  whole. An entry spanning segments joins its parts in order, with a space between two words of a script
  written with spaces; Thai, Lao, Tibetan, Burmese, Khmer, Chinese, Japanese, and full-width forms get
  none. Where a letter or digit meets another, the entry's local text decides, since a 178 s cut can fall
  inside a word: a space when it writes the two words apart, none when it writes them as one word, and the
  local text is kept when it writes them neither way. It keeps its local text when a stretch it overlaps
  has no answer (failed, unsent, or in no segment, such as a tail under 500 ms or a gap) or aligned too
  weakly, or when the segment holding its middle had no speech or Dropline heard none there; a segment
  without speech that it only crosses into adds nothing. Its words still don't go to a neighbour.
  Dropline's words for entries dropped as echo are dropped too.
  A segment whose alignment ratio is below 0.4 keeps local text (ADR-0008), as do failed, unsent, and
  uncovered stretches. The ratio is logged as a number; no text is logged.
- `fork-dropline.ndjson` (0600) in the meeting folder records the provider, each segment's track, number,
  `[start, end)` in samples of the track resampled to 16 kHz (not the WAV's own rate), whether it was sent,
  its state and text, and the memory clear's outcome. It holds no audio or credentials, skips a last line cut
  short (even inside a character), starts the next record on a line of its own after one, and goes to the
  Trash with the meeting.
- Memory clear (ADR-0004, ADR-0007): once per meeting, after its last possible send, when a segment was sent
  and no clear outcome is recorded, Hex posts to `…/dropline-private/memory/clear` beside the token
  endpoint with the saved bearer. A token endpoint that doesn't end in `/dropline-private/token` is skipped.
  `cleared: true` is recorded as `cleared`, `cleared: false` as `not_cleared`, and a 403, a 429, or
  any other failure as `failed` with its HTTP status or failure reason; the answer's other content isn't
  kept. When the final pass ends with a request still in flight, the clear waits for it (at most 65 s) on its
  own thread. When Hex is quitting, the clear runs at once (at most 10 s); if a request was still in flight,
  its outcome isn't recorded. At launch, Hex clears once for each meeting that sent audio and has no clear
  outcome, such as one Hex quit while its clear waited, or one waiting for a final pass that doesn't run
  while Meetings is off or the model is missing. These meetings are found before retention moves expired
  meetings to the Trash, so one that moves still gets its clear. The launch clear and a final pass check for
  a recorded clear under one lock, so they never both clear one meeting.
- Quit and the next launch: quitting while a meeting records stops its sends. The next launch finishes the
  meeting from its WAV files as before; the final pass reads the file, reuses the answered segments, sends
  no audio, and runs the memory clear if it never ran. A meeting dropped without its final pass stops
  sending and clears once its request in flight is over. Transcribing a Dropline meeting again reuses its
  answered segments the same way and sends no audio. Imported meetings and meetings recorded without
  Dropline have no file and stay local.

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
`~/.local/share/hex-lab/screen.json`, for his `jev` transformation
(`fork/docs/adr/0006-screen-ocr-fork-module.md`).

- Only while Output's 讀取螢幕文字 switch is on (see "Output switches") and some mode uses a script
  transformation, the condition under which Hex reads the window title. A capture reads once: when it becomes real (held past the hold threshold, a control start, or a
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
  (`vocabulary::terms()`), which the read never touches. Upstream's Words on screen (Labs, from v3.5.0)
  keeps its terms in a per-capture slot that `vocabulary::for_capture` sets around the local model's run,
  so they stay out of `vocabulary::terms()` and out of Dropline's prompt too.

## Output switches

The Mac app's Output pane ends its Global steps with a 轉換選項 section (`src/rune_ui/fork_output.rs`), below
Every dictation, holding two switches:

- 讀取螢幕文字 turns screen text off and on. It is saved as `{"enabled": false}` in `fork/screen-text.json`
  in the data folder's owner-only `fork` folder (`HEX_APPLICATION_SUPPORT_DIR` moves it with the data
  folder), not in `settings.json`, so it stays out of the upstream settings and Derek's dotfiles. A missing
  or unreadable file reads as on, which is how screen text behaved before the switch. While it is off, no
  capture reads the screen, the listener doesn't load Vision, and `screenLines` is left out of every
  transformation. Turning it on loads Vision right away (when a script transformation is set up and Screen
  Recording is allowed); turning it off doesn't unload a model Vision already holds. The switch takes
  effect from the next dictation. It has no `hex settings` key: the registry only addresses
  `settings.json`, so a key would mean a new upstream `AppSettings` field.
- 使用 Jev is on while the Global mode's `transformations` contain `jev`. Turning it on puts `jev` right
  after `traditional-chinese`, else right before `cjk-spacing`, else last; turning it off removes `jev`
  and leaves every other step in its order. It saves `settings.json` the way the window saves any setting,
  and `hex settings set dictation_processing.default_mode '<json>'` changes the same list from the CLI.
  When `hex.config.ts` doesn't register `jev`, the switch shows the list's state, disabled, with
  `hex.config.ts 沒有註冊 jev`.

Both hooks are macOS-only, so Linux and Windows build the Output pane unchanged and the goldens (rendered
on Linux) don't change.

## Continued dictations in History

Upstream joins back-to-back dictations into one sentence when nothing happened between them: no typing,
clicking, or focus change (`src/continuation.rs`). The second paste gets a leading space and the
capitalization the first one's end calls for. Upstream's History still records each dictation on its own,
so a sentence spoken in two holds of the shortcut became two entries. On the Mac, History keeps it as one
(`src/fork/history_continued.rs`):

- The paster reports every paste and whether it joined the paste before it. A dictation whose paste
  joined, and came right after the paste of the dictation that made the newest entry, is added to that
  entry. Any other paste in between (Paste Last, the recent-dictations picker), an Annotate paste, a
  dictation that only copied or printed, or a History record that failed starts a new entry.
- Only a Dictation or Raw entry of the same kind is continued, never a Send, a cancelled entry, or one
  transcribed again (it has versions).
- The entry keeps its id, time, application, model, and processing. Its raw and final texts are joined the
  way the paste joined them, and its audio, inference, and total times add up.
- With Labs › Keep recordings on, the new audio is appended to the entry's WAV (written next to it as
  `history-audio/18446744073709551615.wav`, merged, and removed), so Transcribe again hears the whole
  sentence. When the entry has no audio, or the new part has none, the entry keeps none.
- With Labs › Dictation stats on, the day's rollup gets the new words and audio without counting another
  dictation.
- Paste Last still pastes the newest dictation's own text, as upstream does.

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
