//! The fork's Dropline private API in the window (`crate::fork::dropline`,
//! macOS): a section closing the speech model picker that adds, uses, and
//! deletes the provider, the picker's local model marked as the fallback,
//! and General's Speech model row naming it while dictation uses it.
//! Elsewhere, and in scenes and tests, every hook leaves the window as it is.

#[cfg(not(target_os = "macos"))]
mod other {
    use rune::El;

    use super::super::Ui;
    use super::super::controls::Paint;

    pub(in crate::rune_ui) fn section(_ui: &Ui, _p: Paint) -> Option<El> {
        None
    }

    pub(in crate::rune_ui) fn model_name<'a>(_ui: &Ui, name: &'a str) -> &'a str {
        name
    }

    pub(in crate::rune_ui) fn status(_ui: &Ui, _p: Paint) -> Option<(String, rune::Color)> {
        None
    }

    pub(in crate::rune_ui) fn model_chosen() {}
}

#[cfg(not(target_os = "macos"))]
pub(super) use other::{model_chosen, model_name, section, status};

#[cfg(target_os = "macos")]
pub(super) use macos::{
    Form, fallback_badge, local_is_fallback, model_chosen, model_name, section, status,
};

#[cfg(target_os = "macos")]
mod macos {
    use std::sync::{Arc, Mutex};
    use std::time::SystemTime;

    use rune::{El, TextEdit, col, edit_access, row, text};
    use rune_kit::{Button, ButtonVariant, TextInput};

    use super::super::controls::{ButtonKind, Paint, PushSize, button, status_dot};
    use super::super::lists::group_label;
    use super::super::{Ui, picker};
    use crate::fork::dropline::{self, DEFAULT_ENDPOINT, NAME, Provider};
    use crate::transcription::models as transcription_models;

    const TITLE: &str = "自訂辨識服務";

    type Outcome = Arc<Mutex<Option<Result<(), String>>>>;

    /// The add form and the provider's pending actions.
    #[derive(Default)]
    pub(in crate::rune_ui) struct Form {
        adding: bool,
        endpoint: TextEdit,
        bearer: TextEdit,
        /// The save running off the UI thread, then its outcome.
        saving: Option<Outcome>,
        /// A select or delete that failed.
        error: Option<String>,
        confirm_delete: bool,
    }

    impl Form {
        fn saving(&self) -> bool {
            self.saving
                .as_ref()
                .is_some_and(|outcome| outcome.lock().unwrap_or_else(|e| e.into_inner()).is_none())
        }

        fn save_error(&self) -> Option<String> {
            let outcome = self
                .saving
                .as_ref()?
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            outcome.as_ref()?.as_ref().err().cloned()
        }
    }

    /// The local model dictation falls back to.
    fn local_name(ui: &Ui) -> String {
        transcription_models::definition(ui.settings.transcription.model)
            .name
            .to_string()
    }

    fn in_use(ui: &Ui) -> bool {
        ui.live() && dropline::selected()
    }

    /// General names Dropline as the speech model while dictation uses it.
    pub(in crate::rune_ui) fn model_name<'a>(ui: &Ui, name: &'a str) -> &'a str {
        if in_use(ui) { NAME } else { name }
    }

    /// General's line under the speech model while Dropline is in use and
    /// nothing about the local model needs saying: the last fallback and
    /// why, else which model answers when Dropline fails.
    pub(in crate::rune_ui) fn status(ui: &Ui, p: Paint) -> Option<(String, rune::Color)> {
        if !in_use(ui) {
            return None;
        }
        Some(match dropline::last_fallback() {
            Some(fallback) => (fallback_line(ui, &fallback), p.warning()),
            None => (format!("失敗時改用 {}", local_name(ui)), p.muted()),
        })
    }

    fn fallback_line(ui: &Ui, fallback: &dropline::Fallback) -> String {
        let minutes = SystemTime::now()
            .duration_since(fallback.at)
            .map_or(0, |age| age.as_secs() / 60);
        let when = match minutes {
            0 => "剛才".to_owned(),
            minutes if minutes < 60 => format!("{minutes} 分鐘前"),
            minutes => format!("{} 小時前", minutes / 60),
        };
        format!("{when}改用 {}：{}", local_name(ui), fallback.reason)
    }

    /// Whether the picker's model in use only answers when Dropline fails.
    pub(in crate::rune_ui) fn local_is_fallback(ui: &Ui) -> bool {
        in_use(ui)
    }

    /// Takes the place of the local model's In use while Dropline is in use.
    pub(in crate::rune_ui) fn fallback_badge(p: Paint) -> El {
        row()
            .key("fork-dropline-fallback")
            .h(28.0)
            .gap(8.0)
            .center_y()
            .child(status_dot(p.faint()))
            .child(
                text("失敗時改用")
                    .key("label")
                    .font(p.k.ty.ui_medium)
                    .color(p.muted()),
            )
    }

    /// A local model was chosen in the picker.
    pub(in crate::rune_ui) fn model_chosen() {
        dropline::deselect();
    }

    /// The picker's last section: the provider, or adding it.
    pub(in crate::rune_ui) fn section(ui: &Ui, p: Paint) -> Option<El> {
        if !ui.live() {
            return None;
        }
        let form = &ui.fork_dropline;
        let body = match dropline::provider() {
            Some(provider) => provider_row(ui, p, &provider),
            None if form.adding => form_view(ui, p),
            None => add_row(p),
        };
        let mut section = col()
            .key("fork-dropline")
            .role("group")
            .label(TITLE)
            .px(24.0)
            .pb(16.0)
            .child(group_label(p, "heading", TITLE, false).px(0.0))
            .child(body);
        if let Some(error) = &form.error {
            section = section.child(line(p, "error", error.clone(), p.danger()));
        }
        Some(section)
    }

    fn line(p: Paint, key: &str, copy: String, color: rune::Color) -> El {
        text(copy)
            .key(key.to_owned())
            .font(p.k.ty.small)
            .color(color)
            .wrap()
    }

    fn name(p: Paint) -> El {
        text(NAME)
            .key("name")
            .font(p.k.ty.ui_medium)
            .color(p.text())
    }

    fn add_row(p: Paint) -> El {
        row()
            .key("fork-dropline-add")
            .py(12.0)
            .gap(16.0)
            .center_y()
            .child(name(p).grow(1.0))
            .child(button(
                p,
                "fork-dropline-new",
                "新增…",
                ButtonKind::Secondary,
                |ui: &mut Ui, _| {
                    ui.fork_dropline = Form {
                        adding: true,
                        endpoint: TextEdit::new(DEFAULT_ENDPOINT.to_owned()),
                        ..Form::default()
                    };
                },
            ))
    }

    fn form_view(ui: &Ui, p: Paint) -> El {
        let form = &ui.fork_dropline;
        let saving = form.saving();
        let field = |key: &str, label: &str, input: El| {
            row()
                .key(key.to_owned())
                .gap(12.0)
                .center_y()
                .child(
                    text(label.to_owned())
                        .key("label")
                        .font(p.k.ty.small)
                        .color(p.muted())
                        .w(96.0),
                )
                .child(input.grow(1.0).shrink())
        };
        let endpoint = TextInput::new(&form.endpoint)
            .placeholder(DEFAULT_ENDPOINT)
            .width(None)
            .on_edit(edit_access(|ui: &mut Ui| &mut ui.fork_dropline.endpoint))
            .build(p.k)
            .key("fork-dropline-endpoint");
        let bearer = TextInput::new(&form.bearer)
            .secure()
            .placeholder("Derek Voice 的 API token")
            .width(None)
            .on_edit(edit_access(|ui: &mut Ui| &mut ui.fork_dropline.bearer))
            .on_submit(|ui: &mut Ui, _| save(ui))
            .build(p.k)
            .key("fork-dropline-bearer");
        let mut view = col()
            .key("fork-dropline-form")
            .py(12.0)
            .gap(8.0)
            .child(name(p))
            .child(field("endpoint-row", "Token 端點", endpoint))
            .child(field("bearer-row", "Bearer token", bearer));
        if let Some(error) = form.save_error() {
            view = view.child(line(p, "save-error", error, p.danger()));
        }
        let save_button = Button::new(if saving { "驗證中…" } else { "儲存" })
            .variant(ButtonVariant::Contrast)
            .disabled(saving)
            .on_press_tx(|ui: &mut Ui, _| save(ui))
            .build_push(p.k)
            .key("fork-dropline-save");
        view.child(
            row()
                .key("form-actions")
                .gap(8.0)
                .center_y()
                .child(row().grow(1.0))
                .child(
                    Button::new("取消")
                        .variant(ButtonVariant::Neutral)
                        .disabled(saving)
                        .on_press_tx(|ui: &mut Ui, _| ui.fork_dropline = Form::default())
                        .build_push(p.k)
                        .key("fork-dropline-cancel"),
                )
                .child(save_button),
        )
    }

    /// Checks the endpoint and bearer with one token fetch, off the UI
    /// thread; the provider is saved only when it works.
    fn save(ui: &mut Ui) {
        if !ui.live() || ui.fork_dropline.saving() {
            return;
        }
        let endpoint = ui.fork_dropline.endpoint.text.clone();
        let bearer = ui.fork_dropline.bearer.text.clone();
        let outcome: Outcome = Arc::default();
        let waker = ui.modes.waker.clone();
        let result = outcome.clone();
        let started = std::thread::Builder::new()
            .name("hex-dropline-save".into())
            .spawn(move || {
                let saved = dropline::save(&endpoint, &bearer);
                *result.lock().unwrap_or_else(|e| e.into_inner()) = Some(saved);
                if let Some(waker) = &waker {
                    waker();
                }
            });
        let form = &mut ui.fork_dropline;
        form.error = None;
        match started {
            Ok(_) => form.saving = Some(outcome),
            Err(error) => form.error = Some(error.to_string()),
        }
    }

    fn provider_row(ui: &Ui, p: Paint, provider: &Provider) -> El {
        let form = &ui.fork_dropline;
        let mut copy = col()
            .key("copy")
            .grow(1.0)
            .shrink()
            .gap(2.0)
            .child(name(p))
            .child(line(
                p,
                "facts",
                format!(
                    "{} · 失敗時改用 {}",
                    crate::net::host(&provider.endpoint),
                    local_name(ui)
                ),
                p.faint(),
            ));
        if let Some(fallback) = dropline::last_fallback() {
            copy = copy.child(line(
                p,
                "fallback",
                fallback_line(ui, &fallback),
                p.warning(),
            ));
        }
        let delete = if form.confirm_delete {
            button(
                p,
                "fork-dropline-delete",
                "確定刪除？",
                ButtonKind::Danger,
                |ui: &mut Ui, _| delete(ui),
            )
        } else {
            Button::new("刪除")
                .variant(ButtonVariant::Ghost)
                .on_press_tx(|ui: &mut Ui, _| ui.fork_dropline.confirm_delete = true)
                .build_small_push(p.k)
                .key("fork-dropline-delete")
        };
        let choice = if provider.selected {
            row()
                .key("in-use")
                .h(28.0)
                .gap(8.0)
                .center_y()
                .child(status_dot(p.accent()))
                .child(
                    text("使用中")
                        .key("label")
                        .font(p.k.ty.ui_medium)
                        .color(p.text()),
                )
        } else {
            Button::new("使用")
                .variant(ButtonVariant::Neutral)
                .on_press_tx(|ui: &mut Ui, _| use_dropline(ui))
                .build_small_push(p.k)
                .key("fork-dropline-use")
        };
        row()
            .key("fork-dropline-provider")
            .role("listitem")
            .label(NAME)
            .py(12.0)
            .gap(16.0)
            .center_y()
            .child(copy)
            .child(
                row()
                    .key("actions")
                    .gap(8.0)
                    .center_y()
                    .child(delete)
                    .child(choice),
            )
    }

    fn use_dropline(ui: &mut Ui) {
        if !ui.live() {
            return;
        }
        match dropline::select(true) {
            Ok(()) => {
                ui.fork_dropline.error = None;
                picker::close(ui);
            }
            Err(error) => ui.fork_dropline.error = Some(error),
        }
    }

    fn delete(ui: &mut Ui) {
        if !ui.live() {
            return;
        }
        let deleted = dropline::delete();
        ui.fork_dropline = Form::default();
        if let Err(error) = deleted {
            ui.fork_dropline.error = Some(error);
        }
    }
}
