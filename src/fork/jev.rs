//! Where Derek's `jev` transformation sits in a mode's steps (FORK.md
//! "Output switches"): right after Traditional Chinese, else right before CJK
//! spacing, else last. Output's 使用 Jev switch and the recording's Jev key
//! (`jev_key`) both place it this way.

pub const JEV: &str = "jev";
const AFTER: &str = "traditional-chinese";
const BEFORE: &str = "cjk-spacing";

pub fn with_jev(steps: &[String]) -> Vec<String> {
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

pub fn without_jev(steps: &[String]) -> Vec<String> {
    steps.iter().filter(|id| *id != JEV).cloned().collect()
}

pub fn has_jev(steps: &[String]) -> bool {
    steps.iter().any(|id| id == JEV)
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
