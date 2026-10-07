//! Capped read-only object enumeration for walks without exclusions/overlays.
use rustler::{Binary, Encoder, Env, Term};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};
const MAX_IDS: usize = 8192;
fn oid(bytes: &[u8]) -> Option<[u8; 20]> {
    gix_hash::ObjectId::from_hex(bytes)
        .ok()?
        .as_slice()
        .try_into()
        .ok()
}
fn enumerate(repo: &Path, tips: Term<'_>, active: &impl Fn() -> bool) -> Option<Vec<[u8; 20]>> {
    if !matches!(fs::symlink_metadata(repo.join("shallow")), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
    {
        return None;
    }
    // Share all config/ref/object-layout guards, but don't require any refs
    // to supply a tip: the WAL supplies full object IDs for these walks.
    let mut queue = VecDeque::new();
    for (count, tip) in tips.decode::<rustler::ListIterator>().ok()?.enumerate() {
        if count >= MAX_IDS || !active() {
            return None;
        }
        let tip: Binary<'_> = tip.decode().ok()?;
        if tip.len() != 40 {
            return None;
        }
        queue.push_back((
            crate::resolve::plain_target(repo, tip.as_slice(), active)?,
            1u8,
        ));
    }
    let mut store = crate::trees::Store::open(repo, active)?;
    let mut seen = HashMap::new();
    let mut output = Vec::new();
    let mut budget = 4 * 1024 * 1024;
    while let Some((wanted, kind)) = queue.pop_front() {
        if !active() {
            return None;
        }
        if let Some(actual) = seen.get(&wanted) {
            if *actual != kind {
                return None;
            }
            continue;
        }
        if seen.len() >= MAX_IDS {
            return None;
        }
        seen.insert(wanted, kind);
        output.push(wanted);
        match kind {
            1 => {
                let body = store.walk_body(&wanted, kind, &mut budget, active)?;
                let commit = gix_object::CommitRef::from_bytes(&body, gix_hash::Kind::Sha1).ok()?;
                queue.push_back((oid(commit.tree)?, 2));
                for parent in &commit.parents {
                    queue.push_back((oid(parent)?, 1));
                }
            }
            2 => {
                let body = store.walk_body(&wanted, kind, &mut budget, active)?;
                for entry in gix_object::TreeRefIter::from_bytes(&body, gix_hash::Kind::Sha1) {
                    let entry = entry.ok()?;
                    let child = entry.oid.as_bytes().try_into().ok()?;
                    let kind = match entry.mode.value() {
                        0o040000 => 2,
                        0o100644 | 0o100755 | 0o120000 => 3,
                        0o160000 => continue,
                        _ => return None,
                    };
                    if queue.len() >= MAX_IDS || !active() {
                        return None;
                    }
                    queue.push_back((child, kind));
                }
            }
            3 => {
                if store.walk_metadata(&wanted, active)?.0 != 3 {
                    return None;
                }
            }
            _ => return None,
        }
        if queue.len() > MAX_IDS {
            return None;
        }
    }
    Some(output)
}
#[rustler::nif(schedule = "DirtyIo")]
fn plain_walk<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    tips: Term<'a>,
    output: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let active = || start.elapsed() < limit && pid.is_alive(env);
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let result = enumerate(repo, tips, &active);
    let result = result.and_then(|oids| {
        if !active() {
            return None;
        }
        let output = Path::new(std::ffi::OsStr::from_bytes(output.as_slice()));
        // O_EXCL: only this caller's fresh, unique scratch can be written.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(output)
            .ok()?;
        for oid in &oids {
            if !active() {
                return None;
            }
            writeln!(
                file,
                "{}",
                gix_hash::ObjectId::from_bytes_or_panic(oid).to_hex()
            )
            .ok()?;
        }
        Some(oids.len())
    });
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(count) => (crate::ok(), count).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
