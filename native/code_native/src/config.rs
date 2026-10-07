//! Conservative fast path for Code's small, plain local Git configurations.
//! Includes, worktree configuration and uncertain parses go back to Git.

use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use rustler::Binary;

const MAX_CONFIG_BYTES: usize = 64 * 1024;

pub(crate) fn plain_config(path: &Path) -> io::Result<Option<gix_config::File>> {
    let file = match crate::files::open_metadata_file(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::InvalidData => return Ok(None),
        Err(error) => return Err(error),
    };
    // take() also bounds a config that grows after stat. Parser allocations
    // are bounded by this input cap, not by repository or pack size.
    let mut bytes = Vec::new();
    file.take((MAX_CONFIG_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_CONFIG_BYTES {
        return Ok(None);
    }
    let Ok(config) = gix_config::File::from_bytes_no_includes(
        bytes.as_slice(),
        gix_config::file::Metadata::api(),
        Default::default(),
    ) else {
        return Ok(None);
    };
    if config.sections().any(|section| {
        let header = section.header();
        let name = header.name();
        name.eq_ignore_ascii_case(b"include") || name.eq_ignore_ascii_case(b"includeIf")
    }) || config.raw_values("extensions.worktreeConfig").is_ok()
        || path.with_file_name("config.worktree").exists()
    {
        return Ok(None);
    }
    Ok(Some(config))
}

fn matches_config(path: &Path, settings: &[(&str, &[u8])]) -> io::Result<bool> {
    let Some(config) = plain_config(path)? else {
        return Ok(false);
    };
    Ok(settings.iter().all(|(key, expected)| {
        let Some((section, name)) = key.split_once('.') else {
            return false;
        };
        // raw_values_by does not use AsKey's panicking conversion for invalid
        // keys. Reject duplicate values even when the final value matches.
        match config.raw_values_by(section, None, name) {
            Ok(values) if values.len() == 1 => {
                let actual: &[u8] = values[0].as_ref();
                actual == *expected
            }
            _ => false,
        }
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_config_matches(path: Binary<'_>, settings: Vec<(Binary<'_>, Binary<'_>)>) -> bool {
    // Git.run disables global/system configuration, but inherited command
    // configuration can still override the local file. Never ignore it.
    if ["GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"]
        .iter()
        .any(|key| std::env::var_os(key).is_some())
    {
        return false;
    }
    let Some(settings): Option<Vec<_>> = settings
        .iter()
        .map(|(key, value)| {
            std::str::from_utf8(key.as_slice())
                .ok()
                .map(|key| (key, value.as_slice()))
        })
        .collect()
    else {
        return false;
    };
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    matches_config(path, &settings).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn configuration_fast_path_is_bounded_and_conservative() {
        let dir = crate::test_support::TestDirectory::new();
        let path = dir.join("config");
        let settings = [("transfer.hideRefs", b"refs/code".as_slice())];
        for (input, expected) in [
            ("[transfer]\n hideRefs = refs/code\n", true),
            ("[TRANSFER]\n HIDEREFS = \"refs/code\" # comment\n", true),
            ("[transfer]\n hideRefs = !refs/code\n hideRefs = refs/code\n", false),
            ("[transfer]\n hideRefs = refs/code\n[include]\n path = missing\n", false),
            ("[transfer]\n hideRefs = refs/code\n[includeIf \"onbranch:never\"]\n path = missing\n", false),
            ("[transfer]\n hideRefs = refs/code\n[extensions]\n worktreeConfig = false\n", false),
            ("[broken", false),
            ("", false),
        ] {
            fs::write(&path, input).unwrap();
            assert_eq!(matches_config(&path, &settings).unwrap(), expected, "{input}");
        }
        fs::write(&path, vec![b' '; MAX_CONFIG_BYTES + 1]).unwrap();
        assert!(!matches_config(&path, &settings).unwrap());
        fs::write(&path, "[transfer]\n hideRefs = refs/code\n").unwrap();
        fs::write(dir.join("config.worktree"), "").unwrap();
        assert!(!matches_config(&path, &settings).unwrap());
        assert!(!matches_config(&dir, &settings).unwrap());
        fs::remove_dir_all(&dir).unwrap();
        assert!(matches_config(&path, &settings).is_err());
    }
}
