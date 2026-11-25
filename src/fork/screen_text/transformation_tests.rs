//! `context.screenLines` as a transformation receives it (FORK.md, "Screen
//! text"). Compiled into `personal_commands` as its child, for its worker.

use std::fs;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc;
use std::time::{SystemTime, UNIX_EPOCH};

use super::*;
use crate::fork::screen_text::ScreenText;

const CONFIG: &str = r#"export default {
  transformations: {
    qaScreenLines: {
      name: "qa screen lines",
      transform: (text, context) =>
        JSON.stringify({
          text,
          present: "screenLines" in context,
          array: Array.isArray(context.screenLines),
          lines: context.screenLines ?? null,
        }),
    },
  },
}
"#;

/// What the qa transformation reports for a dictation with `context`.
fn transformed(context: ContextSnapshot) -> serde_json::Value {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("hex-qa-screen-lines-{unique}"));
    let workspace = root.join("hex");
    fs::create_dir_all(&workspace).unwrap();
    fs::write(workspace.join("hex.config.ts"), CONFIG).unwrap();
    let (requests, _receiver) = mpsc::sync_channel(4);
    let mut worker = Worker {
        transformations: Arc::new(TransformationClient::default()),
        requests,
        workspace,
        status_file: Some(root.join("personal-commands.json")),
        trust_file: Some(root.join("transform-trust.json")),
        generation: 0,
        loaded: None,
        status: StatusSnapshot::default(),
    };
    worker.reload();
    let (response, result) = mpsc::sync_channel(1);
    worker.transform(
        TransformationRequest {
            generation: worker.status.active_generation.unwrap_or(0),
            ids: vec!["qaScreenLines".into()],
            text: "qa-dictation".into(),
            context,
            source: crate::dictation::processor::Source::Dictation,
            response,
        },
        &AtomicBool::new(false),
    );
    let output = result.recv().unwrap();
    fs::remove_dir_all(&root).unwrap();
    serde_json::from_str(&output.unwrap()).unwrap()
}

#[test]
fn a_transformation_receives_its_dictations_screen_lines_in_order() {
    let report = transformed(ContextSnapshot {
        fork_screen_text: ScreenText::ready(&["qa-alpha-4127", "qa-bravo-5203", "qa-charlie-6311"]),
        ..ContextSnapshot::default()
    });
    assert_eq!(
        report,
        serde_json::json!({
            "text": "qa-dictation",
            "present": true,
            "array": true,
            "lines": ["qa-alpha-4127", "qa-bravo-5203", "qa-charlie-6311"],
        })
    );
}

#[test]
fn a_window_without_text_gives_empty_screen_lines() {
    let report = transformed(ContextSnapshot {
        fork_screen_text: ScreenText::ready(&[]),
        ..ContextSnapshot::default()
    });
    assert_eq!(report["present"], true);
    assert_eq!(report["lines"], serde_json::json!([]));
}

#[test]
fn without_a_read_the_context_has_no_screen_lines() {
    let report = transformed(ContextSnapshot::default());
    assert_eq!(report["present"], false);
    assert_eq!(report["lines"], serde_json::Value::Null);
}
