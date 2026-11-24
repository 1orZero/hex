//! Hex fork (see FORK.md): `hex://vocabulary/add?term=<term>[&sounds_like=a,b]`
//! (`hex-test://` in a test build) adds a term to the shared vocabulary the
//! way `hex vocabulary add` does, then says what happened beside the HUD.
//! Without a term it opens the Vocabulary sheet with a new row, as the menu
//! bar's Add term… does. Declared from `rune_ui.rs`, so it lives under
//! `rune_ui`.

use rune::Tx;

use super::Ui;
use super::live_text::fork_notice;
use super::story_link::percent_decode;
use crate::app_settings::AppSettings;
use crate::control::{self, ControlCommand, ControlReply};
use crate::dictation::vocabulary::{self, VocabularyEntry};

/// What a vocabulary link asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Link {
    /// Add `term`; each `sounds_like` value is a comma-separated list.
    Add {
        term: String,
        sounds_like: Vec<String>,
    },
    /// No term: the Vocabulary sheet with a new row.
    NewRow,
}

/// What adding a term did to the list.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Outcome {
    Added,
    AddedSpellings,
    AlreadyThere,
    Refused(String),
}

/// Handles `link` when it is a vocabulary link; returns whether it was one.
pub(super) fn open(ui: &mut Ui, link: &str, tx: &mut Tx) -> bool {
    let Some(link) = parse(link, super::story_link::scheme()) else {
        return false;
    };
    match link {
        Link::NewRow => {
            super::show(ui, super::Destination::Settings, tx);
            super::vocabulary::open_new_term(ui, tx);
            crate::macos_rune::bring_window_forward();
        }
        Link::Add { term, sounds_like } => {
            let spawned = std::thread::Builder::new()
                .name("hex-vocabulary-link".into())
                .spawn(move || save(&term, sounds_like));
            if let Err(error) = spawned {
                tracing::warn!(%error, "could not start the vocabulary link's save");
            }
        }
    }
    true
}

/// Reads `scheme://vocabulary/add[?term=…][&sounds_like=…]`. Query values are
/// percent-decoded; `+` stays a plus, so `C++` needs no escaping.
fn parse(link: &str, scheme: &str) -> Option<Link> {
    let url = url::Url::parse(link).ok()?;
    if url.scheme() != scheme || url.host_str() != Some("vocabulary") {
        return None;
    }
    let mut segments = url.path_segments()?.filter(|segment| !segment.is_empty());
    if !segments.next()?.eq_ignore_ascii_case("add") || segments.next().is_some() {
        return None;
    }
    let mut term = None;
    let mut sounds_like = Vec::new();
    for pair in url.query().unwrap_or_default().split('&') {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        let value = percent_decode(value).unwrap_or_else(|| value.to_owned());
        match key {
            "term" => term = Some(value),
            "sounds_like" => sounds_like.push(value),
            _ => {}
        }
    }
    Some(
        match term.filter(|term| !vocabulary::clean(term).is_empty()) {
            Some(term) => Link::Add { term, sounds_like },
            None => Link::NewRow,
        },
    )
}

/// Adds `term` to `list` through `hex vocabulary add`'s edit.
fn add(list: &mut Vec<VocabularyEntry>, term: &str, sounds_like: Vec<String>) -> Outcome {
    let existed = vocabulary::contains(list, term);
    let command = ControlCommand::VocabularyAdd {
        term: term.to_owned(),
        sounds_like,
    };
    match control::edit_vocabulary(list, &command) {
        Ok(ControlReply::Done { changed: true, .. }) if existed => Outcome::AddedSpellings,
        Ok(ControlReply::Done { changed: true, .. }) => Outcome::Added,
        Ok(_) => Outcome::AlreadyThere,
        Err(error) => Outcome::Refused(error.message),
    }
}

fn message(term: &str, outcome: &Outcome) -> String {
    let term = vocabulary::clean(term);
    match outcome {
        Outcome::Added => format!("Added “{term}” to Vocabulary"),
        Outcome::AddedSpellings => format!("Added spellings to “{term}”"),
        Outcome::AlreadyThere => format!("“{term}” is already in Vocabulary"),
        Outcome::Refused(why) => format!("Couldn't add: {}", shorten_quotes(why)),
    }
}

/// Cuts each quoted text in `reason` to its first 16 characters, so the
/// reason after a long term still fits on the plate.
fn shorten_quotes(reason: &str) -> String {
    let mut out = String::with_capacity(reason.len());
    let mut rest = reason;
    while let Some((before, after)) = rest.split_once('“')
        && let Some((quoted, tail)) = after.split_once('”')
    {
        out.push_str(before);
        out.push('“');
        if quoted.chars().count() > 16 {
            out.extend(quoted.chars().take(16));
            out.push('…');
        } else {
            out.push_str(quoted);
        }
        out.push('”');
        rest = tail;
    }
    out.push_str(rest);
    out
}

/// Saves the term as `hex vocabulary add` does (one settings update, then
/// the runtime's reload, which an open window adopts) and shows the result.
fn save(term: &str, sounds_like: Vec<String>) {
    let mut settings = match AppSettings::load() {
        Ok(settings) => settings,
        Err(error) => {
            tracing::warn!(%error, "could not read settings for a vocabulary link");
            fork_notice::show_failure(format!("Couldn't read Vocabulary: {error}"));
            return;
        }
    };
    let base = settings.clone();
    let outcome = add(&mut settings.vocabulary, term, sounds_like);
    if matches!(outcome, Outcome::Added | Outcome::AddedSpellings) {
        if let Err(error) = base.update(&settings) {
            tracing::warn!(%error, "could not save a vocabulary link's term");
            fork_notice::show_failure(format!("Couldn't save Vocabulary: {error}"));
            return;
        }
        if let Some(runtime) = crate::macos_rune::runtime() {
            let _ = runtime.send(crate::macos_rune::Request::ReloadSettings);
        }
    }
    let text = message(term, &outcome);
    match outcome {
        Outcome::Refused(_) => fork_notice::show_failure(text),
        _ => fork_notice::show(text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(link: &str) -> Option<Link> {
        parse(link, "hex")
    }

    fn entry(term: &str, sounds_like: &[&str]) -> VocabularyEntry {
        VocabularyEntry {
            term: term.into(),
            sounds_like: sounds_like.iter().map(|&text| text.into()).collect(),
        }
    }

    /// Reads `link` and adds its term to `list`; the outcome and its notice.
    fn apply(list: &mut Vec<VocabularyEntry>, link: &str) -> (Outcome, String) {
        let Some(Link::Add { term, sounds_like }) = read(link) else {
            panic!("{link} is not an add link");
        };
        let outcome = add(list, &term, sounds_like);
        let text = message(&term, &outcome);
        (outcome, text)
    }

    #[test]
    fn a_link_adds_its_term_and_spellings_like_hex_vocabulary_add() {
        let mut list = Vec::new();
        let (outcome, text) = apply(
            &mut list,
            "hex://vocabulary/add?term=qa-Foo&sounds_like=foo%20bar,%20fu",
        );
        assert_eq!(outcome, Outcome::Added);
        assert_eq!(text, "Added “qa-Foo” to Vocabulary");
        assert_eq!(list, vec![entry("qa-Foo", &["foo bar", "fu"])]);
    }

    #[test]
    fn query_values_are_percent_decoded_and_keep_a_plus() {
        let mut list = Vec::new();
        apply(&mut list, "hex://vocabulary/add?term=%E5%8F%B0%E5%8C%97");
        apply(
            &mut list,
            "hex://vocabulary/add?term=C++&sounds_like=see%20plus%20plus",
        );
        apply(
            &mut list,
            "hex://vocabulary/add/?sounds_like=dax&term=Dax%20%20Rad",
        );
        assert_eq!(
            list,
            vec![
                entry("台北", &[]),
                entry("C++", &["see plus plus"]),
                entry("Dax Rad", &["dax"]),
            ]
        );
    }

    #[test]
    fn a_link_without_a_term_opens_a_new_row() {
        for link in [
            "hex://vocabulary/add",
            "hex://vocabulary/add/",
            "hex://vocabulary/Add?term=",
            "hex://vocabulary/add?term=%20%20",
            "hex://vocabulary/add?sounds_like=foo",
        ] {
            assert_eq!(read(link), Some(Link::NewRow), "{link}");
        }
    }

    #[test]
    fn an_existing_term_says_so_and_takes_new_spellings() {
        let mut list = vec![entry("qa-Foo", &["fu"])];
        let (outcome, text) = apply(&mut list, "hex://vocabulary/add?term=QA-foo&sounds_like=fu");
        assert_eq!(outcome, Outcome::AlreadyThere);
        assert_eq!(text, "“QA-foo” is already in Vocabulary");
        let (outcome, text) = apply(
            &mut list,
            "hex://vocabulary/add?term=qa-foo&sounds_like=foo",
        );
        assert_eq!(outcome, Outcome::AddedSpellings);
        assert_eq!(text, "Added spellings to “qa-foo”");
        assert_eq!(list, vec![entry("qa-Foo", &["fu", "foo"])]);
    }

    #[test]
    fn the_vocabularys_limits_refuse_and_change_nothing() {
        let mut list = Vec::new();
        let long = format!("hex://vocabulary/add?term={}", "a".repeat(65));
        let (outcome, text) = apply(&mut list, &long);
        assert!(matches!(outcome, Outcome::Refused(_)));
        assert_eq!(
            text,
            "Couldn't add: “aaaaaaaaaaaaaaaa…” is longer than 64 characters"
        );
        let spellings: Vec<String> = (0..17).map(|n| format!("s{n}")).collect();
        let many = format!(
            "hex://vocabulary/add?term=qa-Foo&sounds_like={}",
            spellings.join(",")
        );
        assert!(matches!(apply(&mut list, &many).0, Outcome::Refused(_)));
        assert!(list.is_empty());

        let mut full: Vec<_> = (0..vocabulary::MAX_ENTRIES)
            .map(|n| entry(&format!("term{n}"), &[]))
            .collect();
        let (outcome, text) = apply(&mut full, "hex://vocabulary/add?term=qa-Foo");
        assert_eq!(text, "Couldn't add: the vocabulary holds at most 500 terms");
        assert!(matches!(outcome, Outcome::Refused(_)));
        assert_eq!(full.len(), vocabulary::MAX_ENTRIES);
    }

    #[test]
    fn a_test_build_reads_its_own_scheme() {
        assert_eq!(
            parse("hex-test://vocabulary/add?term=qa-Foo", "hex-test"),
            Some(Link::Add {
                term: "qa-Foo".into(),
                sounds_like: Vec::new(),
            })
        );
    }

    #[test]
    fn leaves_other_links_alone() {
        for other in [
            "hex://labs",
            "hex://settings/general",
            "hex://story/hud/processing",
            "hex://vocabulary",
            "hex://vocabulary/remove?term=qa-Foo",
            "hex://vocabulary/add/more?term=qa-Foo",
            "hex-test://vocabulary/add?term=qa-Foo",
            "https://vocabulary/add?term=qa-Foo",
            "not a link",
            "",
        ] {
            assert_eq!(read(other), None, "{other}");
        }
    }
}
