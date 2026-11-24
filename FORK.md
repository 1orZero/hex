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

## Fork-only files

- `FORK.md`: this file.
- `ios/HEXShared/Fork/`, `ios/HEXMobile/Fork/`, `ios/HEXKeyboard/Fork/`, and
  `ios/HEXMobileTests/ForkDropline*Tests.swift`: the Dropline private API provider.

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
