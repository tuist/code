//! Read-only, complete-or-fallback listing of ordinary loose ASCII SHA-1 refs.
//! No object/pack bytes are read; each leaf read is capped independently.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use bstr::ByteSlice;
use rustler::{Binary, Encoder, Env, Term};

const MAX_ENTRIES: usize = 8192;
const MAX_REFS: usize = 4096;
const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
const MAX_DEPTH: usize = 64;
const MAX_NAME_BYTES: usize = 2048;

fn small_file(path: &Path, limit: usize) -> Option<Vec<u8>> {
    let file = crate::files::open_metadata_file(path).ok()?;
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64).read_to_end(&mut bytes).ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

fn config_value(config: &gix_config::File, key: &str, expected: &[u8]) -> bool {
    matches!(config.raw_values(key), Ok(values) if values.len() == 1 && {
        let actual: &[u8] = values[0].as_ref();
        actual == expected
    })
}

pub(crate) fn eligible(path: &Path) -> Option<()> {
    let config = crate::config::plain_config(&path.join("config")).ok()??;
    if !config_value(&config, "core.bare", b"true")
        || !config_value(&config, "core.repositoryformatversion", b"0")
        || config
            .sections()
            .any(|section| section.header().name().eq_ignore_ascii_case(b"extensions"))
    {
        return None;
    }
    for name in ["packed-refs", "commondir"] {
        match fs::symlink_metadata(path.join(name)) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => return None,
        }
    }
    for name in ["objects", "refs"] {
        if !fs::symlink_metadata(path.join(name)).ok()?.is_dir() {
            return None;
        }
    }
    let head = small_file(&path.join("HEAD"), 1024)?;
    let target = head.strip_prefix(b"ref: ")?.strip_suffix(b"\n")?;
    if !target.starts_with(b"refs/")
        || !target.is_ascii()
        || gix_validate::reference::name(target.as_bstr()).is_err()
    {
        return None;
    }
    Some(())
}

#[derive(Default)]
struct Scan {
    refs: HashMap<String, String>,
    entries: usize,
    bytes: usize,
}

impl Scan {
    fn walk(
        &mut self,
        path: &Path,
        prefix: &mut String,
        depth: usize,
        alive: &impl Fn() -> bool,
    ) -> Option<()> {
        if depth > MAX_DEPTH || !alive() {
            return None;
        }
        for entry in fs::read_dir(path).ok()? {
            let entry = entry.ok()?;
            self.entries += 1;
            if self.entries > MAX_ENTRIES || !alive() {
                return None;
            }
            let name = entry.file_name();
            let name = name.to_str()?;
            if name.starts_with('.') || name.ends_with(".lock") {
                continue;
            }
            if !name.is_ascii() {
                return None;
            }
            let original_len = prefix.len();
            prefix.push('/');
            prefix.push_str(name);
            if prefix.len() > MAX_NAME_BYTES
                || gix_validate::reference::name(prefix.as_bytes().as_bstr()).is_err()
            {
                return None;
            }
            let kind = entry.file_type().ok()?;
            if kind.is_dir() {
                self.walk(&entry.path(), prefix, depth + 1, alive)?;
            } else if kind.is_file() {
                let bytes = small_file(&entry.path(), 128)?;
                // Git's writer produces canonical lowercase IDs and one LF.
                // All other spellings, aliases and corruption defer to Git.
                if bytes.len() != 41
                    || bytes[40] != b'\n'
                    || !bytes[..40]
                        .iter()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
                    || bytes[..40].iter().all(|byte| *byte == b'0')
                {
                    return None;
                }
                self.bytes += prefix.len() + 40;
                if self.refs.len() >= MAX_REFS || self.bytes > MAX_OUTPUT_BYTES {
                    return None;
                }
                let oid = std::str::from_utf8(&bytes[..40]).ok()?.to_owned();
                self.refs.insert(prefix.clone(), oid);
            } else {
                return None;
            }
            prefix.truncate(original_len);
        }
        Some(())
    }
}

fn collect(path: &Path, alive: &impl Fn() -> bool) -> Option<HashMap<String, String>> {
    eligible(path)?;
    let mut scan = Scan::default();
    scan.walk(&path.join("refs"), &mut "refs".to_owned(), 0, alive)?;
    Some(scan.refs)
}

pub(crate) fn supported_environment() -> bool {
    // Preserve inherited Git discovery, namespace and command configuration.
    ![
        "GIT_DIR",
        "GIT_COMMON_DIR",
        "GIT_WORK_TREE",
        "GIT_NAMESPACE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
    ]
    .iter()
    .any(|key| std::env::var_os(key).is_some())
}

#[rustler::nif(schedule = "DirtyIo")]
fn loose_refs<'a>(env: Env<'a>, path: Binary<'a>) -> Term<'a> {
    if !supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    let pid = env.pid();
    match collect(path, &|| pid.is_alive(env)) {
        Some(refs) => (crate::ok(), refs).encode(env),
        None => crate::fallback_git().encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn bounded_complete_or_fallback_scan() {
        let root = crate::test_support::TestDirectory::new();
        fs::create_dir_all(root.join("refs/heads")).unwrap();
        fs::create_dir(root.join("objects")).unwrap();
        fs::write(
            root.join("config"),
            "[core]\n bare = true\n repositoryformatversion = 0\n",
        )
        .unwrap();
        fs::write(root.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        let reference = root.join("refs/heads/main");
        fs::write(&reference, format!("{}\n", "1".repeat(40))).unwrap();
        assert_eq!(
            collect(&root, &|| true).unwrap()["refs/heads/main"],
            "1".repeat(40)
        );
        assert!(collect(&root, &|| false).is_none());
        fs::write(&reference, vec![b'1'; 4096]).unwrap();
        assert!(collect(&root, &|| true).is_none());
        fs::remove_file(&reference).unwrap();
        symlink(root.join("config"), &reference).unwrap();
        assert!(collect(&root, &|| true).is_none());
        fs::remove_file(&reference).unwrap();
        fs::write(root.join("packed-refs"), "").unwrap();
        assert!(collect(&root, &|| true).is_none());
        fs::remove_file(root.join("packed-refs")).unwrap();
        // Exercise the production limit without relaxing it for tests.
        for n in 0..=MAX_REFS {
            fs::write(
                root.join(format!("refs/heads/r{n}")),
                format!("{}\n", "1".repeat(40)),
            )
            .unwrap();
        }
        assert!(collect(&root, &|| true).is_none());
        fs::remove_dir_all(root).unwrap();
    }
}
