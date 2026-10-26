//! Files only the proxy's user may read: the running policies and the start facts.

use std::fs::{DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

/// Writes `text` to `path` with mode 0600.
pub fn write_private(path: &Path, text: &str) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(text.as_bytes())
}

/// Creates `path` and its missing parents with mode 0700.
pub fn make_private_dir(path: &Path) -> io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(path)
}
