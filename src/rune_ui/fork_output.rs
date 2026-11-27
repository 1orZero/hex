//! The fork's switches in the Output pane (macOS): 讀取螢幕文字 turns
//! screen text off and on (`crate::fork::screen_text`, FORK.md "Screen
//! text"), and 使用 Jev adds or removes Derek's `jev` transformation in the
//! Global mode (FORK.md "Output switches").

use rune::{El, Tx, col};

use super::Ui;
use super::controls::{CardRow, METRICS, Paint, card, setting_row, toggle_row};
use crate::fork::jev::{JEV, has_jev, with_jev, without_jev};
use crate::fork::screen_text;

mod jev_key;

pub(super) fn section(ui: &Ui, p: Paint) -> El {
    let rows: Vec<CardRow> = vec![
        screen_text_row(ui, p).into(),
        jev_row(ui, p).into(),
        jev_key::row_el(ui, p).into(),
    ];
    col()
        .key("fork-switches")
        .gap(METRICS.label_gap)
        .child(p.section_label("轉換選項").mx(METRICS.row_px))
        .child(card(p, "card", rows))
}

fn screen_text_row(ui: &Ui, p: Paint) -> El {
    let on = !ui.live() || screen_text::enabled();
    toggle_row(
        p,
        "fork-screen-text",
        "讀取螢幕文字",
        None,
        on,
        move |ui: &mut Ui| {
            if !ui.live() {
                return;
            }
            if let Err(error) = screen_text::set_enabled(!on) {
                ui.error = Some(format!("無法儲存讀取螢幕文字：{error}"));
            }
        },
    )
}

fn jev_row(ui: &Ui, p: Paint) -> El {
    let on = has_jev(
        &ui.settings
            .dictation_processing
            .default_mode
            .transformations,
    );
    let registered = ui
        .modes
        .status
        .transformations
        .iter()
        .any(|transformation| transformation.id == JEV);
    if !registered {
        let switch = rune_kit::Switch::new(on)
            .disabled(true)
            .build(p.k)
            .key("switch")
            .focusable(false)
            .a11y_hidden();
        return setting_row(
            p,
            "fork-jev",
            "使用 Jev",
            Some("hex.config.ts 沒有註冊 jev"),
            switch,
        )
        .role("switch")
        .checked(on)
        .disabled(true);
    }
    toggle_row(p, "fork-jev", "使用 Jev", None, on, move |ui: &mut Ui| {
        let current = &ui
            .settings
            .dictation_processing
            .default_mode
            .transformations;
        let next = if on {
            without_jev(current)
        } else {
            with_jev(current)
        };
        ui.update(|settings| settings.dictation_processing.default_mode.transformations = next);
    })
}

/// The Jev key's recorder, on every poll.
pub(super) fn poll(ui: &mut Ui, tx: &mut Tx) -> bool {
    jev_key::poll(ui, tx)
}
