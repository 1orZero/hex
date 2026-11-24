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
| `ios/HEXKeyboard/KeyboardLocalDictation.swift` | `begin(in:microphone:pressedAt:armed:)`: `ForkDroplineRecognition.prepare()` after `let jobID = UUID().uuidString` | Opens the Dropline session as the keyboard starts recording (best effort). |
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler for vocabulary links, since upstream's handler ignores hosts other than `keyboard`, and folds in the Mac's vocabulary each time Hex becomes active. |
| `ios/HEXMobile/CustomVocabularyEditor.swift` | `.onReceive(… .forkVocabularyChanged)` after the editor's `.onAppear` (3 lines) | Reloads the editor's cached list after a link or the Mac's vocabulary changes it; otherwise the editor's next add or remove writes its stale list back. |
| `ios/HEXKeyboard/KeyboardViewController.swift` | `viewWillAppear(_:)`: `ForkMacVocabulary.apply()` after `super.viewWillAppear(animated)` (1 line) | Folds in the Mac's vocabulary as the keyboard comes on screen, before the keys and dictation read the list, so the iPhone gets it without opening Hex. |

## Fork-only files

- `FORK.md`: this file.
- `ios/HEXShared/Fork/`, `ios/HEXMobile/Fork/`, `ios/HEXKeyboard/Fork/`, and
  `ios/HEXMobileTests/ForkDropline*Tests.swift`: the Dropline private API provider.
- `ios/HEXMobile/Fork/VocabularyLink.swift` and `ios/HEXMobileTests/Fork/VocabularyLinkTests.swift`: the
  vocabulary link.
- `ios/HEXShared/Fork/ForkMacVocabulary.swift` and `ios/HEXMobileTests/Fork/ForkMacVocabularyTests.swift`:
  the Mac's vocabulary on the iPhone.

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

- The app and keyboard share `ios/HEXShared/Fork/ForkDroplineClient.swift`. Its answer parser
  converts a successful `final_text` to Traditional Chinese before either caller receives it.
  Apple's offline `Hans-Hant` transform changes Han characters, not regional terms: `软件` becomes
  `軟件`, not `軟體`. The client keeps common existing spellings such as `了解` and the Cantonese
  particle `吓`, and uses Taiwan forms such as `啟` for `启`. Ambiguous characters still depend on
  context. Local and fallback transcripts and live words bypass this parser.
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
  fails. The keyboard's live words (Show what I say, Type as I speak) stay local; the final text is
  Dropline's.

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
order (`hex vocabulary list`) and copies the terms to the App Group as `fork-mac-vocabulary.json`
(`{"terms": [...]}`) with `devicectl`. The copy holds names and email addresses, so it lives only in
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
