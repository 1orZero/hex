//! `dictation::processor`'s child (FORK.md "Jev key"), so it reaches the
//! profiles' steps.

use super::{Profile, Profiles};
use crate::fork::jev::{has_jev, with_jev, without_jev};

impl Profiles {
    /// Global runs `jev`.
    pub(crate) fn fork_global_has_jev(&self) -> bool {
        has_jev(&self.default.transformations)
    }

    /// Every mode with `jev` put in its place (`on`) or taken out, for one
    /// dictation whose Jev key chose so.
    pub(crate) fn fork_with_jev(mut self, on: bool) -> Self {
        let choose = |profile: &mut Profile| {
            profile.transformations = if on {
                with_jev(&profile.transformations)
            } else {
                without_jev(&profile.transformations)
            };
        };
        choose(&mut self.default);
        self.contextual
            .iter_mut()
            .for_each(|contextual| choose(&mut contextual.profile));
        self
    }
}
