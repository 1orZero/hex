//! The provider's saved settings: `fork/dropline-private.json` in the data
//! folder's owner-only `fork` folder. The bearer is in the Keychain, never
//! here.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::Provider;

pub const DEFAULT_ENDPOINT: &str = "https://voice.veraze.io/v1/dropline-private/token";

#[derive(Deserialize, Serialize)]
struct Saved {
    endpoint: String,
    selected: bool,
}

fn path() -> Option<PathBuf> {
    crate::app_paths::support_dir()
        .ok()
        .map(|support| support.join("fork").join("dropline-private.json"))
}

pub(super) fn load() -> Option<Provider> {
    let bytes = std::fs::read(path()?).ok()?;
    match serde_json::from_slice::<Saved>(&bytes) {
        Ok(saved) => Some(Provider {
            endpoint: saved.endpoint,
            selected: saved.selected,
        }),
        Err(error) => {
            tracing::warn!(%error, "ignoring an unreadable Dropline provider file");
            None
        }
    }
}

pub(super) fn save(provider: &Provider) -> std::io::Result<()> {
    let path = path().ok_or_else(|| std::io::Error::other("no data folder"))?;
    if let Some(folder) = path.parent() {
        crate::app_paths::create_private_dir(folder)?;
    }
    let saved = Saved {
        endpoint: provider.endpoint.clone(),
        selected: provider.selected,
    };
    let bytes = serde_json::to_vec_pretty(&saved).map_err(std::io::Error::other)?;
    crate::durable::write(&path, &bytes)
}

pub(super) fn remove() -> std::io::Result<()> {
    let Some(path) = path() else {
        return Ok(());
    };
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}
