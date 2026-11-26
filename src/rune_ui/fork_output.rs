//! The fork's switches in the Output pane (macOS): 讀取螢幕文字 turns
//! screen text off and on (`crate::fork::screen_text`, FORK.md "Screen
//! text"), and 使用 Jev adds or removes Derek's `jev` transformation in the
//! Global mode (FORK.md "Output switches").

use rune::{El, col};

use super::Ui;
use super::controls::{CardRow, METRICS, Paint, card, setting_row, toggle_row};
use crate::fork::screen_text;

const JEV: &str = "jev";
/// `jev` runs on the Traditional Chinese text and before CJK spacing.
const AFTER: &str = "traditional-chinese";
const BEFORE: &str = "cjk-spacing";

pub(super) fn section(ui: &Ui, p: Paint) -> El {
    let rows: Vec<CardRow> = vec![screen_text_row(ui, p).into(), jev_row(ui, p).into()];
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
    let on = ui
        .settings
        .dictation_processing
        .default_mode
        .transformations
        .iter()
        .any(|id| id == JEV);
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

/// The steps with `jev` after Traditional Chinese, else before CJK spacing,
/// else last.
fn with_jev(steps: &[String]) -> Vec<String> {
    let mut steps = without_jev(steps);
    let at = steps
        .iter()
        .position(|id| id == AFTER)
        .map(|index| index + 1)
        .or_else(|| steps.iter().position(|id| id == BEFORE))
        .unwrap_or(steps.len());
    steps.insert(at, JEV.into());
    steps
}

fn without_jev(steps: &[String]) -> Vec<String> {
    steps.iter().filter(|id| *id != JEV).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(steps: &[&str]) -> Vec<String> {
        steps.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn jev_goes_after_traditional_chinese_and_before_cjk_spacing() {
        let off = ids(&["traditional-chinese", "cjk-spacing"]);
        let on = ids(&["traditional-chinese", "jev", "cjk-spacing"]);
        assert_eq!(with_jev(&off), on);
        assert_eq!(without_jev(&on), off);
        assert_eq!(
            with_jev(&ids(&[
                "qa-first",
                "traditional-chinese",
                "qa-middle",
                "cjk-spacing"
            ])),
            ids(&[
                "qa-first",
                "traditional-chinese",
                "jev",
                "qa-middle",
                "cjk-spacing"
            ])
        );
        assert_eq!(
            with_jev(&ids(&["qa-first", "cjk-spacing", "qa-last"])),
            ids(&["qa-first", "jev", "cjk-spacing", "qa-last"])
        );
        assert_eq!(with_jev(&ids(&["qa-only"])), ids(&["qa-only", "jev"]));
        assert_eq!(with_jev(&[]), ids(&["jev"]));
    }

    #[test]
    fn turning_jev_off_keeps_every_other_step_in_order() {
        assert_eq!(
            without_jev(&ids(&[
                "qa-a",
                "jev",
                "traditional-chinese",
                "jev",
                "cjk-spacing"
            ])),
            ids(&["qa-a", "traditional-chinese", "cjk-spacing"])
        );
        assert_eq!(without_jev(&ids(&["qa-a", "qa-b"])), ids(&["qa-a", "qa-b"]));
    }
}
