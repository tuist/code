//! Fixed, case-sensitive plain-tree search. Fully verify streamed blob bodies,
//! including binary blobs, without buffering large objects or delta bases.
use rustler::{Binary, Encoder, Env, Term};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};
type Match = (String, u64, String);
fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
}
struct Lines<'a> {
    pattern: &'a [u8],
    first: bool,
    binary: bool,
    pending: Vec<u8>,
    number: u64,
    matches: Vec<(u64, String)>,
    limit: usize,
    bytes: usize,
}
impl<'a> Lines<'a> {
    fn line(&mut self) -> Option<()> {
        if self.matches.len() < self.limit
            && self
                .pending
                .windows(self.pattern.len())
                .any(|part| part == self.pattern)
        {
            if !self.pending.is_ascii() || self.pending.contains(&0) {
                return None;
            }
            self.bytes = self.bytes.checked_add(self.pending.len())?;
            if self.bytes > 1024 * 1024 {
                return None;
            }
            self.matches.push((
                self.number,
                std::str::from_utf8(&self.pending).ok()?.to_owned(),
            ));
        }
        self.number = self.number.checked_add(1)?;
        self.pending.clear();
        Some(())
    }
    fn chunk(&mut self, bytes: &[u8]) -> Option<()> {
        if self.first {
            self.first = false;
            self.binary = bytes[..bytes.len().min(8000)].contains(&0);
        }
        if self.binary {
            return Some(());
        }
        for byte in bytes {
            if *byte == b'\n' {
                self.line()?;
            } else {
                if self.pending.len() >= 64 * 1024 {
                    return None;
                }
                self.pending.push(*byte);
            }
        }
        Some(())
    }
    fn finish(mut self) -> Option<Vec<(u64, String)>> {
        if !self.binary && !self.pending.is_empty() {
            self.line()?;
        }
        Some(self.matches)
    }
}
fn eligible(repo: &Path) -> Option<()> {
    if ["info/attributes", "index", ".gitattributes"]
        .iter()
        .any(|name| !absent(&repo.join(name)))
        || std::env::var_os("GIT_ATTR_SOURCE").is_some()
    {
        return None;
    }
    let config = crate::config::plain_config(&repo.join("config")).ok()??;
    if config.sections().any(|section| {
        [b"grep".as_slice(), b"diff", b"attr"]
            .iter()
            .any(|name| section.header().name().eq_ignore_ascii_case(name))
    }) || config.raw_values_by("core", None, "attributesfile").is_ok()
        || config.raw_values_by("core", None, "worktree").is_ok()
    {
        return None;
    }
    Some(())
}
fn scan(
    repo: &Path,
    entries: Vec<crate::trees::Entry>,
    pattern: &[u8],
    limit: usize,
    active: &impl Fn() -> bool,
) -> Option<Vec<Match>> {
    let mut store = crate::trees::Store::open(repo, active)?;
    let mut budget = 128 * 1024 * 1024;
    let mut matches = Vec::new();
    let mut output = 0usize;
    for (mode, _, oid, _, path) in entries {
        if !active() {
            return None;
        }
        if !matches!(mode.as_str(), "100644" | "100755") {
            continue;
        }
        let wanted: [u8; 20] = gix_hash::ObjectId::from_hex(oid.as_bytes())
            .ok()?
            .as_slice()
            .try_into()
            .ok()?;
        let mut lines = Lines {
            pattern,
            first: true,
            binary: false,
            pending: Vec::new(),
            number: 1,
            matches: Vec::new(),
            limit: limit - matches.len(),
            bytes: 0,
        };
        store.stream_blob(&wanted, &mut budget, active, &mut |bytes| {
            lines.chunk(bytes)
        })?;
        for (number, text) in lines.finish()? {
            output = output.checked_add(path.len() + text.len())?;
            if output > 1024 * 1024 {
                return None;
            }
            matches.push((path.clone(), number, text));
        }
        // The wrapper returns only the first globally limited matches. All
        // attribute names were already checked before any blob was scanned.
        if matches.len() == limit {
            break;
        }
    }
    Some(matches)
}
#[rustler::nif(schedule = "DirtyIo")]
fn fixed_grep<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    revision: Binary<'a>,
    pattern: Binary<'a>,
    count: usize,
    paths: Term<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment()
        || pattern.is_empty()
        || pattern.len() > 256
        || !pattern.as_slice().is_ascii()
        || pattern
            .as_slice()
            .iter()
            .any(|b| matches!(*b, 0 | b'\n' | b'\r'))
        || count == 0
        || count > 256
    {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let active = || start.elapsed() < limit && pid.is_alive(env);
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let entries = eligible(repo).and_then(|_| {
        if revision.as_slice() != b"HEAD" {
            let head = crate::trees::listing(repo, b"HEAD", true, &active)?;
            if head
                .iter()
                .any(|entry| entry.4.split('/').any(|name| name == ".gitattributes"))
            {
                return None;
            }
        }
        crate::trees::listing(repo, revision.as_slice(), true, &active)
    });
    let Some(entries) = entries else {
        return if start.elapsed() >= limit {
            crate::timeout()
        } else {
            crate::fallback_git()
        }
        .encode(env);
    };
    if entries.iter().any(|entry| {
        entry.4.split('/').any(|name| name == ".gitattributes")
            || entry
                .4
                .as_bytes()
                .iter()
                .any(|b| b.is_ascii_control() || matches!(*b, b':' | b'\\' | b'"'))
    }) {
        return crate::fallback_git().encode(env);
    }
    let Ok(paths) = paths.decode::<rustler::ListIterator>() else {
        return crate::fallback_git().encode(env);
    };
    let mut checked = 0;
    for path in paths {
        if checked >= 2 {
            return crate::fallback_git().encode(env);
        }
        let Ok(path) = path.decode::<Binary<'_>>() else {
            return crate::fallback_git().encode(env);
        };
        if path.len() > 4096
            || path.is_empty()
            || !absent(Path::new(std::ffi::OsStr::from_bytes(path.as_slice())))
        {
            return crate::fallback_git().encode(env);
        }
        checked += 1;
    }
    if checked == 0 {
        return crate::need_attribute_paths().encode(env);
    }
    if checked != 2 {
        return crate::fallback_git().encode(env);
    }
    let result = scan(repo, entries, pattern.as_slice(), count, &active);
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(matches) => (crate::ok(), matches).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lines_keep_carriage_returns_bound_memory_and_ignore_binary_prefixes() {
        let new = || Lines {
            pattern: b"match",
            first: true,
            binary: false,
            pending: Vec::new(),
            number: 1,
            matches: Vec::new(),
            limit: 2,
            bytes: 0,
        };
        let mut lines = new();
        lines.chunk(b"match\r\nno\nmatch end").unwrap();
        assert_eq!(
            lines.finish().unwrap(),
            vec![(1, "match\r".into()), (3, "match end".into())]
        );
        let mut lines = new();
        lines.chunk(b"\0match\n").unwrap();
        assert!(lines.finish().unwrap().is_empty());
        let mut lines = new();
        assert!(lines.chunk(&vec![b'x'; 64 * 1024 + 1]).is_none());
    }
}
