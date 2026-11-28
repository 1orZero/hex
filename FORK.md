# Fork notes (ios-stable)

`ios-stable` is the iPhone branch of Derek's fork of [anomalyco/hex](https://github.com/anomalyco/hex). It
follows upstream's App Store releases, the `ios-beta-appstore-X.Y.Z` tags, rather than upstream's `dev`
or its TestFlight tags (`ios-beta-<sha>`). It started at `ios-beta-appstore-1.0.4` (e7ea56ba). The Mac
app follows the `stable` branch, whose own `FORK.md` covers the Mac and the daily pipeline.

The daily pipeline (`fork/daily.sh` on `stable`) merges each new App Store tag into this branch, builds
the iPhone app from it under the fork's identity (`io.veraze.hex.mobile`, team 67A6AV33K9, rewritten at
build time; this branch keeps upstream's `anomaly.hex.mobile`), and installs it on Derek888. Every other
change reaches this branch through a pull request.

## Upstream files the fork changes

Fork code lives in files upstream does not have; upstream files carry only the hooks below. When a
fork change has to touch an upstream file, add a row here with the file, the hook, and the purpose, so
whoever resolves a tag merge knows what to keep.

| Upstream file | Hook | Purpose |
| --- | --- | --- |
| `ios/HEXMobile/DictationController.swift` | `startRecording(...)`: `ForkDroplineRecognition.prepare()` after `let sharesHeard = …` | Opens the Dropline session as a recording starts (best effort). |
| `ios/HEXMobile/DictationController.swift` | `finishRecording()`: `activeTranscriber.transcribe(` becomes `activeTranscriber.transcribePreferringDropline(` with the same arguments | The app's dictation-finish point: Dropline first, the local engine on failure. |
| `ios/HEXMobile/ContentView.swift` | `homeView`: `ForkDroplineSettingsCard()` and a blank line after the Settings pages card (`.padding(.top, 8)`) | Adds, selects, and deletes the provider. |
| `ios/HEXKeyboard/KeyboardParakeet.swift` | `KeyboardTranscription.transcribe(_:hints:audioSeconds:)`: `if let dropline = try await ForkKeyboardDropline.transcribe(url, hints: hints) { return dropline }` as its first line | The keyboard's own dictation: Dropline first, the keyboard's local engines when Dropline isn't selected or fails. |
| `ios/HEXKeyboard/KeyboardLiveDictation.swift` | `resolve()`: `if let source = ForkDroplineLiveWords.source(sampleRate: sampleRate) { attach(source); return }` as its first line (1 line) | While Dropline is selected, the keyboard's live words are Dropline's drafts (`ForkDroplineLiveTranscriber`) and Apple's speech recognition doesn't start. |
| `ios/HEXKeyboard/KeyboardParakeet.swift` | `warmUp(memoryWarned:)`: `if ForkDroplineSettings().isSelected { return }` after `recordKeyboardLimit` (1 line) | The keyboard doesn't load its speech model while Dropline is selected. |
| `ios/HEXKeyboard/KeyboardLocalDictation.swift` | `begin(in:microphone:pressedAt:armed:)`: `ForkDroplineRecognition.prepare()` after `let jobID = UUID().uuidString` | Opens the Dropline session as the keyboard starts recording (best effort). |
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler for vocabulary links, since upstream's handler ignores hosts other than `keyboard`, folds in the Mac's vocabulary, and readies three-language dictation's models each time Hex becomes active. |
| `ios/HEXMobile/CustomVocabularyEditor.swift` | `.onReceive(… .forkVocabularyChanged)` after upstream's `.onReceive(… .hexWordsListsDidChange)`, which follows the editor's `.onAppear` (3 lines) | Reloads the editor's cached list after a link or the Mac's vocabulary changes it; otherwise the editor's next add or remove writes its stale list back. |
| `ios/HEXKeyboard/KeyboardViewController.swift` | `viewWillAppear(_:)`: `ForkMacVocabulary.apply()` after `super.viewWillAppear(animated)` (1 line) | Folds in the Mac's vocabulary as the keyboard comes on screen, before the keys and dictation read the list, so the iPhone gets it without opening Hex. |
| `ios/HEXMobile/AppleSpeechTranscriber.swift` | `transcribe(_:vocabulary:)`: `if let threeLanguage = await ForkThreeLanguage.transcribe(…) { … }` before the `// Labs › Two-language dictation` comment (4 lines) | The app's Apple Speech dictation reads the recording in English, Cantonese, and Mandarin when three-language dictation applies, else runs upstream's Two-language and single-language paths unchanged. |
| `ios/HEXKeyboard/KeyboardSpeech.swift` | `transcribe(_:hints:)`: the same `if let threeLanguage = …` block before the `// Labs › Two-language dictation` comment, returning the dictation language with the text (4 lines) | The same for the keyboard's own Apple Speech dictation. |
| `ios/HEXKeyboard/KeyboardLiveDictation.swift` | `resolve()`: `if let three = await ForkThreeLanguageLiveWords.source(for: picked, sampleRate: rate), !self.stopped { self.attach(three); return }` after `guard let self, !self.stopped else { return }` in the lookup task (1 line) | While three-language dictation applies, the keyboard's live words come from `ForkThreeLanguageLiveWords` instead of one recogniser in the dictation language. |
| `ios/HEXMobile/AppleSpeechTranscriber.swift` | `transcribe(_:vocabulary:)`: `if let senseVoice = await ForkSenseVoice.transcribe(audioURL, dictationLanguage: language.identifier) { return senseVoice }` before the `if let threeLanguage` block (1 line) | While Labs › SenseVoice（中文） applies, SenseVoice-Small writes the app's Apple Speech dictation; nil (lab off, no model, another language, or a failure) falls through to three-language dictation and upstream's paths unchanged. |
| `ios/HEXKeyboard/KeyboardSpeech.swift` | `transcribe(_:hints:)`: `if let senseVoice = await ForkSenseVoice.transcribe(url, dictationLanguage: language.identifier) { return (senseVoice, language) }` before the `if let threeLanguage` block (1 line) | The same for the keyboard's own Apple Speech dictation. |
| `ios/HEXKeyboard/KeyboardLiveDictation.swift` | `resolve()`: `if let senseVoice = ForkSenseVoiceLiveWords.source(language: picked?.identifier, sampleRate: rate) { self.attach(senseVoice); return }` before the three-language line (1 line; synchronous, so nothing can stop the capture between the `stopped` check and `attach`) | While SenseVoice writes the dictation and its model has loaded, the keyboard's live words come from SenseVoice and no Apple recogniser starts. |
| `ios/HEXMobile/DictationController.swift` | `startRecording(...)`: `ForkSenseVoice.prewarm()` after `ForkDroplineRecognition.prepare()` (1 line) | Loads SenseVoice as a recording starts, when it will read the dictation. |
| `ios/HEXKeyboard/KeyboardLocalDictation.swift` | `begin(in:microphone:pressedAt:armed:)`: `ForkSenseVoice.prewarm()` after `ForkDroplineRecognition.prepare()` (1 line) | The same as the keyboard starts recording. |
| `ios/HEXMobile/Settings/ExperimentsSettingsPage.swift` | `dictationSection`: `ForkSenseVoiceSettingsCard()` and a blank line after the Dictation card (2 lines) | Labs › SenseVoice（中文）: the switch, the model's download with its progress, and Remove model. |

## Fork-only files

- `FORK.md`: this file.
- `ios/HEXShared/Fork/`, `ios/HEXMobile/Fork/`, `ios/HEXKeyboard/Fork/`, and
  `ios/HEXMobileTests/ForkDropline*Tests.swift`: the Dropline private API provider.
- `ios/HEXMobile/Fork/VocabularyLink.swift` and `ios/HEXMobileTests/Fork/VocabularyLinkTests.swift`: the
  vocabulary link.
- `ios/HEXShared/Fork/ForkMacVocabulary.swift` and `ios/HEXMobileTests/Fork/ForkMacVocabularyTests.swift`:
  the Mac's vocabulary on the iPhone.
- `ios/HEXShared/Fork/ForkThreeLanguage.swift`, `ios/HEXShared/Fork/ForkThreeLanguageEnglishWords.swift`,
  `ios/HEXKeyboard/Fork/ForkThreeLanguageLiveWords.swift`, `ios/HEXMobileTests/Fork/ForkThreeLanguageTests.swift`,
  `ios/HEXMobileTests/Fork/ForkThreeLanguageEnglishWordsTests.swift`, `ios/HEXMobileTests/Fork/qa-three-language-lanes.json`,
  and `ios/HEXMobileTests/Fork/qa-three-language-english.json`: three-language dictation.
- `ios/HEXShared/Fork/ForkSenseVoice*.swift`, `ios/HEXMobile/Fork/ForkSenseVoiceSettingsCard.swift`, and
  `ios/HEXMobileTests/Fork/ForkSenseVoice*Tests.swift`: SenseVoice（中文）.

## Dropline private API

A custom transcription provider, "Dropline 私人 API". While it is selected, a finished dictation's
recording is sent to Dropline's private API and its text replaces the local engine's; the rest of the
pipeline (corrections, vocabulary spelling, style, cleanup, translation, insertion) is unchanged. When
Dropline fails (no bearer, network error, timeout, a second 401 after one token refetch, a bad answer, a
recording over 178 s), the local engine transcribes the same recording, and the card shows the last
fallback and why. An empty `final_text` means Dropline heard no speech: the dictation ends quietly with
nothing inserted, as when a local engine hears none, and doesn't fall back.

- The access token comes from a token endpoint (default `https://voice.veraze.io/v1/dropline-private/token`)
  called with a bearer. The endpoint must be https. Saving the provider fetches one token first and stores
  nothing if that fails, then selects the provider.
- Context: the dictation's recognition hints (the custom vocabulary while Custom vocabulary is on, and
  the words Learn how I type learned) go to Dropline as `context.text`; the early session gets the
  custom vocabulary alone.
- Audio: long pauses shortened and edges trimmed per 20 ms block (Derek Voice's `keptPackets`), then
  24 kbit/s Ogg Opus, streamed from the recording file.
- Settings: endpoint, selection, and the last fallback in the App Group defaults (`fork.dropline.*`); the
  bearer in the Keychain (service `anomaly.hex.fork.dropline-private`, account `bearer`, access group
  `KeyboardBridge.appGroup`, after first unlock), so the app and the keyboard both read it. The card sits
  on Hex's home screen under the Settings pages.

### Where dictations go through Dropline

- The app and keyboard share `ios/HEXShared/Fork/ForkDroplineClient.swift`. Its answer parser calls
  `ForkDroplineText.swift` in the same folder on a successful `final_text` before either caller receives it.
  Apple's offline `Hans-Hant` transform changes Han characters, not regional terms: `软件` becomes
  `軟件`, not `軟體`. The client keeps common existing spellings such as `了解` and the Cantonese
  particle `吓`, and uses Taiwan forms such as `啟` for `启`. It skips backtick-quoted code, Han
  identifiers marked by an underscore, and runs with kana or Hangul. For mixed Chinese text, it
  uses a simplified copy to look up the whole phrase and keeps the input characters that were
  already distinctly traditional. This distinguishes `干擾` from `干燥` without treating either
  spelling as a rule for every name or phrase. Local and fallback transcripts bypass this
  parser; Dropline's live drafts go through it.
- In the app: dictations Hex records itself (the app's Dictate, the Action button, Control Center, Siri,
  and the keyboard's dictations handed to Hex) finish in `DictationController.finishRecording()`.
- In the keyboard: from iOS 26 the keyboard records and transcribes by itself
  (`KeyboardLocalDictation`), and every such dictation goes through `KeyboardTranscription`, which tries
  Dropline first. Its text then runs through Hex's steps in the dictation language (Settings › Dictation
  language, else the keyboard's), as the app's Dropline dictations run in the app's.
- The keyboard can use Dropline because self-dictation already needs Full Access, which is also what
  gives a keyboard the network and the App Group's Keychain items. Dropline needs little memory there:
  the recording is read in 4,096-frame chunks and encoded as it is read, so a dictation holds its Opus
  (about 3 KB a second, under 600 KB at the 178 s limit) and one level byte per 20 ms, against the 24 MB
  a keyboard must have free before it dictates by itself. The memory of the network stack in a keyboard
  hasn't been measured on an iPhone. A local engine Hex hasn't already loaded loads only when Dropline
  fails. While recording, the keyboard's live words are Dropline's (below).

### While recording

While Dropline is selected, nothing else transcribes a dictation the keyboard records by itself:

- Live words (Settings › Dictation › Live words, In bar or Into field) come from Dropline
  (`ios/HEXShared/Fork/ForkDroplineLiveWords.swift`). Every 4 s of audio, the recording so far (kept
  at 16 kHz, encoded as the final recording is) goes to `/client/dictate` in the session the final
  text uses, with the custom vocabulary as context, and its `final_text` replaces what shows. Until
  the first text the preview says Listening…, and an empty answer leaves it. A round whose time
  comes while the previous request is still out is skipped, so at most 15 go out a minute. Past
  180 s of audio no request goes out and the last text stays. A 429, a missing bearer, a second
  401, a token endpoint failure, or audio Dropline would refuse ends the drafts for that
  dictation; a timeout, a network error, or another HTTP error leaves the next round going.
  Drafts never record a fallback or run a local engine. With Live words Off, none go out.
- Apple's speech recognition doesn't start for live words, and the keyboard doesn't load its
  speech model (Parakeet) as it appears.
- The final text is Dropline's, as before. Only when it fails does the keyboard's local engine
  transcribe the recording: Parakeet if this keyboard process had it loaded already, else Apple's
  speech recognition on the iPhone. The card shows the fallback.
- Dictations Hex records itself (the app, Keep mic warm, Open Hex) have no live words, so they
  send no drafts. The app still prepares its local engine at launch, since its setup and the
  keyboard's handoff wait on it; it doesn't run during a Dropline dictation unless the final text
  fails.
- Unknown: whether Dropline writes each draft into the account's memory, and whether it counts
  the requests of one session as one dictation.

## Vocabulary link

```text
hex-dictation://vocabulary/add?term=<term>
```

- Adds the term to Hex's vocabulary list (`CustomVocabularySettings`, in the App Group
  `KeyboardBridge.appGroup` that the app and the keyboard share): the list in Settings › Dictation ›
  Custom vocabulary and Settings › Keyboard › Vocabulary. Dictation spells it while Custom vocabulary is
  on, and the full keyboard never autocorrects it away.
- Uses the list editor's checks: at most 64 characters, at least two letters or digits, no duplicate
  spelling (case, spaces, and punctuation ignored), at most 100 terms.
- Shows an alert over whatever is on screen: "Added to Vocabulary", "Already in the list", "Too long",
  "Needs at least two letters or digits", "Up to 100 terms", or "No word in the link". The iPhone list has
  no "sounds like" spellings, so `sounds_like` is ignored.
- Query values are percent-decoded; `+` stays a plus (`term=C++`), so encode spaces as `%20`.

Shortcuts app on the iPhone:

1. New shortcut: **Ask for Input** (Text, prompt "Word"), then **URL Encode** (input: Provided Input).
2. **Text**: `hex-dictation://vocabulary/add?term=` followed by **URL Encoded Text**.
3. **Open URLs** with that Text.
4. Run it from the Home Screen, the Action button, or Settings › Accessibility › Touch › Back Tap.

## The Mac's vocabulary on the iPhone

One way, Mac to iPhone. Each night `fork/daily.sh` (on `stable`) reads the Mac's vocabulary in its
order (`hex vocabulary list`) and copies the terms to the App Group as
`Library/fork-mac-vocabulary.json` (`{"terms": [...]}`) with `devicectl`, which can't write to the
container's root (CoreDeviceError 7000). The copy holds names and email addresses, so it lives only in
`~/.hex-fork/state/` on the Mac and in the App Group on the iPhone, never in a repository.

`ForkMacVocabulary.apply()` folds a new copy into Hex's list (`CustomVocabularySettings`,
`customVocabulary.terms` in the App Group) when the keyboard comes on screen and when Hex becomes active,
so Derek doesn't have to open Hex. It runs once per copy:

- The iPhone's own terms (added with a link, the editor, or the keyboard's add chip) stay, first and in
  their order. A term counts as the Mac's only if an earlier copy added it
  (`fork.macVocabulary.synced`), so a term added here that the Mac also has stays when the Mac drops it.
- The Mac's terms follow in the Mac's order (its most used first), skipping terms the list refuses
  (over 64 characters, fewer than two letters or digits, or a spelling already listed), until the list
  holds 90 terms. The remaining 10 places take terms added on the iPhone before the next copy.
- A term that came from the Mac and isn't in the new copy is removed. A Mac term deleted on the iPhone
  comes back with the next changed copy; to drop it for good, remove it on the Mac.

Why own terms first and 90: in 1.0.4 the list holds at most 100 terms (Apple's limit for contextual
strings), and every reader takes the whole list: dictation's recognition hints (the list, then the words
learned fixes mean, up to 100, for Apple's speech engines' contextual strings and Dropline's context;
Parakeet takes none), the spelling of dictated text, and the full keyboard's autocorrect, completions, and
swipe typing. Only the cap makes a position matter, and upstream's writers keep it by dropping the end of
the list, so the iPhone's own terms go first. Dictation uses the list only while Settings › Dictation ›
Custom vocabulary is on (off by default); the keys use it either way.

## Three-language dictation

English, Cantonese, and Mandarin told apart per dictation, for someone who keeps one of them for a
whole dictation and mixes English words into the Chinese ones. Apple has no language detection, and one
`SpeechTranscriber` hears one locale, so `ForkThreeLanguage` reads the whole recording in `en-US`,
`zh-HK`, and `zh-TW` at once.

- When: Labs › Two-language dictation is on, the dictation language resolves to one of the three on
  `SpeechTranscriber` or is Cantonese in any region (Settings' "Cantonese" is `yue-CN`, which counts
  as `zh-HK` and still gets the same three readings), and the `zh-HK` and `zh-TW` `SpeechTranscriber`
  models (plus `en-US`'s when English is the dictation language) are installed and not set aside.
  The `en-US` reading joins only while its model is installed; without it a Chinese dictation still
  tells Cantonese from Mandarin, and the Chinese models write the English words.
  Otherwise, including a missing Chinese model, dictation takes upstream's Two-language path, then its
  single-language path, as before, which in `zh-HK` writes Mandarin speech as Cantonese.
- Choice: each reading's score is its words' confidence times their duration, summed, in seconds. The
  highest score among readings with text wins; ties go to the dictation language. A Mandarin winner
  leading the Cantonese reading by less than 0.3 s gives way to it when the Cantonese reading writes a
  Cantonese-only character (嘅, 咗, 喺, 佢, 哋, 啲, …). A Chinese winner leading the English reading by
  less than 0.5 s gives way to it when more than half of the Chinese winner's words are in Latin
  letters (`ForkThreeLanguage.latinShare`: each run of Latin letters is one word, every other
  character but spaces and punctuation one more), since the Chinese models write a short English
  sentence in English too and score it close. The winner's text is inserted as Apple wrote
  it, Cantonese colloquial characters included, apart from the English words below; readings are
  never merged. No text in any reading
  throws the usual no-speech error. The readings run two at a time (`ForkThreeLanguage.maximumReadings`):
  Derek888 refuses a third ("Maximum number of recognizers reached"). A reading that still fails
  beside the others (`insufficientResources`) is read again alone, once, 0.3 s later; every
  reading still failing falls through to the paths above. A cancelled reading asks Apple to end its
  analysis (`cancelAndFinishNow`) and counts as failed, never as a reading that heard nothing.
- English words: when a Chinese reading wins and the `en-US` reading has words,
  `ForkThreeLanguageEnglishWords` respells the winner's Latin-letter words the way the `en-US` reading
  wrote the same stretch of audio (`Clian` → `client`, `branchmerge` → `branch merge`, `prom` →
  `prompt`). Of the up to three `en-US` words over a Latin word, only the consecutive ones spelled
  most like it are used, so a Chinese character `en-US` heard as English next to it (`會` as "Hui")
  isn't added. Chinese characters, digits, punctuation, and words with digits are never replaced. A
  word stays when the Chinese reading is at least 0.9 sure of it, it is an acronym of up to five
  capitals or a vocabulary word, the other Chinese reading wrote it the same way, or an `en-US` word
  is a stop word, shorter than three letters, or not among the English words of Hex's own typing
  model (`ios/HEXKeyboard/TypingModel/en.hextm`). A misspelling needs a spelling similarity of 0.55
  and `en-US` at least 0.5 sure and at most 0.15 less sure than the Chinese reading. A real word is
  never split into several words, and one of three letters or more gives way only to a longer or
  shorter form of itself (`prom` → `prompt`), while the Chinese reading is at most 0.85 sure of it
  and `en-US` at least 0.5 and as sure. A vocabulary word is written as the vocabulary spells it. It
  runs whenever three-language dictation does, with no setting of its own, and reads only the
  readings already taken, so no recogniser is added. The typing model is mapped once per process,
  as the readings start, and read off the main actor; UIKit's dictionary isn't used, since its first
  lookup of a misspelling in a process takes about 0.4 s on the main actor (iOS 27.2 simulator).
  Without the English model or a Latin word in the winner, or when English wins, the text is the
  winner's as before; without the English model the typing model isn't read either.
- Live words (the keyboard's preview while it records): live results carry no confidence, so after
  1 s of audio, and every 1.5 s after that (up to 12 s of audio), the recording so far is read again
  the way the dictation is (`ForkThreeLanguage.readAll`), one language at a time, and scored.
  `ForkThreeLanguage.LiveLeader` shows `pick`'s first choice and moves to another only after `pick`
  chooses it at two scorings in a row (0.6 s of audio apart at least), so the words follow the
  language the dictation will be inserted in without flipping. Only the shown language's
  `AppleLiveTranscriber` runs: it starts when that language is first shown or changes, and once
  ready it is fed the recording from its start, so the preview never holds more than two analyses,
  its recogniser and one scoring reading. An iPhone refuses analyses past a small number at once
  (`SFSpeechErrorDomain` 16, `insufficientResources`, seen on Derek888 with three recognisers and
  three scoring readings), which left the preview at "Listening" and then closed it. Nothing shows
  before the first scores. After the last scoring the shown language stays; a language change after
  12 s shows only in the inserted text. A language whose recogniser gives up is no longer scored or
  shown and the next scoring picks another; once settled, or with none left, or when no scoring
  succeeds in those 12 s, or when the scoring audio can't be written, the live words go and the
  dictation goes on. The inserted text and the pick are unchanged.
- Language downstream: both hooks keep the dictation language for the rest of the pipeline (formatting,
  translation source, and the keyboard's `noteKeyboardDictation`), as Two-language does, so the
  language Automatic recorded for the keyboard never changes with the winner.
- Models: upstream downloads and reserves only the dictation language's model and releases it when
  that language changes, so iOS may reclaim the other two. Each time Hex opens or becomes active with
  the lab on and a dictation language among the three, `ForkThreeLanguage.prepareModels()` (called
  from `forkVocabularyLinks()` in `ios/HEXMobile/Fork/VocabularyLink.swift`, one run at a time)
  keeps all three reserved and downloads any that isn't installed. A model reads as installed only to
  a process that has reserved it, and the app and the keyboard hold separate reservations, so the
  keyboard reserves the three before each check of what's installed (`usableLocales`), for the
  dictation and for the live words, when the dictation language is one of the three. Reserving
  releases the oldest other languages when at `AssetInventory.maximumReservedLocales`; with a limit under three nothing changes. The keyboard
  never downloads.
- Log: `anomaly.hex.mobile` category `fork-three-language` records each dictation's pick, the
  three scores, whether the Cantonese reading wrote Cantonese-only characters, failed readings, and the
  seconds the readings took, how many English words were respelled (`english=`), and readings left out for a missing English model (`missing=`); a dictation that doesn't use three languages logs `skipped=` with the
  reason (`lab-off`, `dictation-module`, `language=…`, or `not-installed=…`), and
  `prepareModels` logs what it starts downloading (`downloading=…`) and how each download ended. The same decisions, the newest 50, go to the App Group's
  `Library/fork-three-language.json` (event, detail, scores, process, time, and each first-time
  reading failure's `NSError` domain and code in `errors`, and the count of respelled English words in
  `english`), since an iPhone's past
  system log can't be read without root on the Mac:
  `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier
  group.io.veraze.hex.mobile --source Library/fork-three-language.json`. Never what was said.
- Unverified on an iPhone: the 0.3 s margin and the scores come from 16 synthetic clips read on a Mac
  (DER-165), the English words' thresholds from 262 synthetic qa- clips read on a Mac (HEX-32; 60 of them are
  the test fixture), and
  the time and memory of three readings at once, in the keyboard especially, haven't been measured.

## SenseVoice（中文）

Labs › SenseVoice（中文）, off by default: SenseVoice-Small (FluidAudio's
`FluidInference/sensevoice-small-coreml`, fp16 encoder on the Neural Engine) writes Mandarin and Cantonese
dictations, English words included, instead of Apple's speech recognition. It tells Mandarin, Cantonese, and
English apart itself, so three-language dictation's readings don't run unless it hears English.

- When: the switch is on, the model is downloaded, and the dictation language resolves to English, Mandarin,
  or Cantonese in any region (`ForkSenseVoice.skipReason`). Only dictations Apple's speech recognition
  would transcribe: Dropline and the keyboard's Parakeet come first, as before. Otherwise everything runs
  as without the lab.
- Final text: the whole recording is read again once it stops, in pieces of at most 15 s cut at the quietest
  300 ms (`ForkSenseVoiceSegments.pieces`). Pieces SenseVoice heard in another language than most of the
  audio are read again in that one. Recordings over 120 s (checked before decoding), a process short of
  memory (`ForkSenseVoice.fits`), a model not loaded in this process yet, a load or read error, no text
  (text without a letter or digit counts as none), a recording SenseVoice hears as English (short Cantonese
  with English words often reads as English gibberish, and three-language dictation writes English as it
  does without the lab), or under one letter or digit a second in a recording of 3 s or more
  (`ForkSenseVoice.fallbackReason`, `textReason`) fall back to three-language dictation, then upstream's
  paths, on the same recording. A dictation never waits for the model: it starts loading as a recording
  starts and once the download finishes, unless Dropline is selected, and the first load of a new build
  compiles the encoder for the Neural Engine, 93–101 s on a Mac against 0.1–0.2 s for later loads. Custom
  vocabulary doesn't steer SenseVoice (it takes no hints); Word replacements, learned fixes, and vocabulary
  spellings still apply afterwards, as the Labs card says.
- Live words (keyboard only; the app shows none): every 2 s of audio the recording after its last settled
  stretch is read; a tail of 8 s settles at a pause, and one of 13 s at its quietest point anyway, so a
  round's cost doesn't grow with the recording. A round due while the last one reads is skipped, so
  SenseVoice reads one thing at a time. Only once the model has loaded in this keyboard (before that, the
  keyboard's other live words run, three-language and then upstream's, logged as `live` `loading`), and
  where the keyboard has room for a 15 s read and Core ML lists a Neural Engine: on a Mac's CPU (as in the
  simulator) a round took up to 1.05 s, against under 0.1 s on its Neural Engine. The first settled
  stretch's language is kept. A load or read error ends the live words for that dictation; a later dictation
  in a keyboard whose load failed uses the keyboard's other live words.
- Spelling: Simplified output goes through Apple's ICU `Hans-Hant` transform (Taiwan forms), then a
  Cantonese reading takes Hong Kong forms (係, 裏, 着, 啓, 衞), and 松/面 become 鬆/麵 by context
  (`ForkSenseVoiceText`). No OpenCC.
- Features: `ForkSenseVoiceFeatures` computes the encoder's input (Kaldi log-mel, LFR, FunASR's CMVN)
  instead of FluidAudio's `SenseVoicePreprocessor` model, whose CPU convolution returns different features
  on every call once audio passes about 4.5 s on a Mac (macOS 27.2; not in the iOS 27.2 simulator, unknown
  on an iPhone), which made whole stretches read as "The." or nothing. The two agree within 2e-4 where the
  model is stable.
- Model: turning the switch on downloads the fp16 files (about 450 MB) into
  `SpeechModels/sensevoice-small-coreml` in the App Group, with progress; a failed or stalled download turns
  the switch off and resumes next time; a finished one loads the model in the app. Remove model deletes the
  folder.
- Log: `anomaly.hex.mobile` category `fork-sensevoice`, and the newest 50 records in the App Group's
  `Library/fork-sensevoice.json`: `transcribed`, `fallback` (`too-long`, `memory`, `loading`, `load-failed`,
  `empty`, `english`, `sparse`, `error …`), `skipped`, `live` (rounds, skipped rounds, the longest round, or
  `loading`), `loaded` and `load-failed` (the load's seconds), `downloaded`, and `download-failed`, with the
  process and, where they apply, the detected language, audio and wall seconds, and peak footprint. Never
  what was said.
- Unverified on an iPhone: per-round time, the Neural Engine path, the keyboard's memory, and the first
  load's time were measured on a Mac and in the simulator only (DER-187).

## Merging an App Store tag

`fork/daily.sh` merges the newest `ios-beta-appstore-X.Y.Z` tag against the tag this branch last merged,
not against git's own merge base. App Store tags are release trees beside `dev` (1.0.3 and 1.0.4 add
pull requests to a dev commit), so git's merge base would be the last dev commit both tags share, and
every change a release tree carries beside dev would conflict with dev's later version of it in files
the fork never touched. Against the last merged tag, only the fork's changes can conflict.

The script applies the fork's changes (this branch against its last tag, as one commit) to the new tag
in `~/.hex-fork/ios-src` and commits the result with two parents, this branch and the tag. On a
conflict it stops with exit 23 and leaves the work there: `HEAD` is the new tag, and the conflict
markers put upstream's lines under `HEAD` and the fork's under "Fork changes on ios-stable at <sha>".
Resolve each file by taking upstream's version and re-applying only the hooks listed under "Upstream
files the fork changes", `git add` it, then run `fork/daily.sh --continue-ios`, which commits the
merge, builds, pushes, and installs. Don't run `git commit` there. When the right resolution isn't
clear, run `git -C ~/.hex-fork/ios-src cherry-pick --abort` and report the conflict.
