# Hex fork notes

`1orzero/hex` is a fork of [`anomalyco/hex`](https://github.com/anomalyco/hex) that merges
upstream `dev` every day. Fork code lives in new files (`src/fork/`, `ios/HEXMobile/Fork/`);
upstream files only get small hooks. This file lists what the fork adds and where every hook
sits, so a merge conflict can be resolved without guessing the fork's intent.

## Quick add to Vocabulary (URL scheme)

Adds a term to Hex's vocabulary from a link, so a keyboard shortcut from Shortcuts or Raycast
can add the selected word without opening the window.

### Mac

```text
hex://vocabulary/add?term=<term>[&sounds_like=<a,b>]     (hex-test:// in Hex Test)
```

- Adds the term through `hex vocabulary add`'s edit (`control::edit_vocabulary`): same
  settings update, same runtime reload, and an open window adopts it. The term is matched in
  any case; new `sounds_like` spellings merge into an existing term.
- Says what happened for 4 seconds on the live text plate beside the HUD: "Added “X” to
  Vocabulary", "Added spellings to “X”", or "“X” is already in Vocabulary". The window is not
  opened.
- Limits are `hex vocabulary add`'s: 64 characters per term or spelling, 500 terms, 16
  spellings per term. A refused term changes nothing and shows the reason as a red failure
  notice ("Couldn't add: …", with a long term cut to 16 characters), whether or not Labs ›
  Failure notices is on.
- With no `term` (or a blank one) it opens Settings' Vocabulary sheet with a new focused row,
  the menu bar's Add term… path (no Labs switch needed).
- Query values are percent-decoded. `+` stays a plus (`term=C++`), so encode spaces as
  `%20`.

### iPhone

```text
hex-dictation://vocabulary/add?term=<term>
```

- Adds the term to the custom vocabulary list (`CustomVocabularySettings`, App Group
  `group.anomaly.hex.mobile`): the list Settings › Keyboard › Vocabulary edits, which the
  keyboard autocorrects with and dictation spells while Custom vocabulary is on.
- Uses the vocabulary editor's checks: at most 64 characters, at least two letters or digits,
  no duplicate spelling (case, spaces, and punctuation ignored), at most 100 terms.
- Shows an alert over whatever is on screen: "Added to Vocabulary", "Already in the list",
  "Too long", "Needs at least two letters or digits", "Up to 100 terms", or "No word in the
  link". The iPhone list has no "sounds like" spellings, so `sounds_like` is ignored.

### Keyboard shortcuts

Mac, Shortcuts app (adds the selected text):

1. New shortcut. In its details (ⓘ), turn on **Use as Quick Action** and **Services Menu**;
   set **Receive** to Text from Quick Actions.
2. Add **URL Encode** (input: Shortcut Input), then **Text**:
   `hex://vocabulary/add?term=` followed by the **URL Encoded Text** variable.
3. Add **Open URLs** with that Text.
4. Give it a key: in the shortcut's details, **Add Keyboard Shortcut**, or in System
   Settings › Keyboard › Keyboard Shortcuts… › Services › Text.

Mac, Raycast quicklink:

- Create Quicklink with Link `hex://vocabulary/add?term={selection}` (the selected text), or
  `hex://vocabulary/add?term={argument name="Term"}` (type the word). Raycast
  percent-encodes placeholders. Assign a hotkey in Raycast Settings › Extensions.

iPhone, Shortcuts app:

1. New shortcut: **Ask for Input** (Text, prompt "Word"), then **URL Encode** (input: Provided
   Input).
2. **Text**: `hex-dictation://vocabulary/add?term=` followed by **URL Encoded Text**.
3. **Open URLs** with that Text.
4. Run it from the Home Screen, the Action button, or Settings › Accessibility › Touch › Back
   Tap.

### Fork changes

| File | Hook | Purpose |
| --- | --- | --- |
| `src/fork/vocabulary_link.rs` | new | Parses vocabulary links, adds the term, picks the confirmation; unit tests |
| `src/fork/live_text_notice.rs` | new | Shows a confirmation or failure line on the live text plate |
| `src/rune_ui.rs` | `mod fork_vocabulary_link` above `on_open_url` (3 lines), and its first statement calls `fork_vocabulary_link::open` (3 lines) | Routes vocabulary links before the Labs, settings, and story links |
| `src/rune_ui/live_text.rs` | `mod fork_notice` at the end of the file (4 lines, `#[path]` to `src/fork/live_text_notice.rs`) | Lets the notice reach the plate's private state (`LIVE`, `PLACE`, `Plate`, `notice()`, `schedule`); an upstream change to that state shows up as a build error in `src/fork/live_text_notice.rs` |
| `ios/HEXMobile/Fork/VocabularyLink.swift` | new | Parses vocabulary links, adds the term, shows the alert |
| `ios/HEXMobileTests/Fork/VocabularyLinkTests.swift` | new | Unit tests for the iPhone link |
| `ios/HEXMobile/HEXMobileApp.swift` | `.forkVocabularyLinks()` on `ContentView`, before its `.onOpenURL` (1 line) | Adds a second URL handler; upstream's handler ignores hosts other than `keyboard` |
