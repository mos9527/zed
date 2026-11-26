use std::{
    fs::{File, TryLockError},
    sync::OnceLock,
};

use anyhow::Context as _;
use release_channel::RELEASE_CHANNEL_NAME;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsOnlyInstance {
    Yes,
    No,
}

pub fn ensure_only_instance() -> IsOnlyInstance {
    static INSTANCE_LOCK: OnceLock<File> = OnceLock::new();
    if INSTANCE_LOCK.get().is_some() {
        return IsOnlyInstance::Yes;
    }

    let lock = (|| {
        let data_dir = paths::data_dir();
        std::fs::create_dir_all(data_dir).context("creating Zed Custom data directory")?;
        File::options()
            .write(true)
            .create(true)
            .truncate(false)
            .open(data_dir.join(format!("{}-instance.lock", *RELEASE_CHANNEL_NAME)))
            .context("opening the Zed Custom single-instance lock")
    })();

    match lock {
        Ok(lock) => match lock.try_lock() {
            Ok(()) => {
                // Keep the lock open for the lifetime of the process.
                INSTANCE_LOCK.get_or_init(|| lock);
                IsOnlyInstance::Yes
            }
            Err(TryLockError::WouldBlock) => IsOnlyInstance::No,
            Err(TryLockError::Error(error)) => {
                log::warn!("Failed to acquire the single-instance lock: {error}");
                IsOnlyInstance::Yes
            }
        },
        Err(error) => {
            log::warn!("{error:#}");
            IsOnlyInstance::Yes
        }
    }
}
