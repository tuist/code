//! Conservative read-only commit resolution. Never inflate deltas or blobs.
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

use bstr::ByteSlice;
use flate2::read::ZlibDecoder;
use rustler::{Binary, Encoder, Env, Term};

const MAX_COMMIT: usize = 64 * 1024;
const MAX_COMPRESSED: u64 = 1024 * 1024;
const MAX_INDEX_BYTES: usize = 4 * 1024 * 1024;

fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}
fn small_file(path: &Path, limit: usize) -> Option<Vec<u8>> {
    let file = crate::files::open_metadata_file(path).ok()?;
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64).read_to_end(&mut bytes).ok()?;
    (bytes.len() <= limit).then_some(bytes)
}
fn oid(bytes: &[u8]) -> Option<[u8; 20]> {
    if bytes.len() != 40
        || !bytes
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
    {
        return None;
    }
    gix_hash::ObjectId::from_hex(bytes)
        .ok()?
        .as_slice()
        .try_into()
        .ok()
}
fn target(repo: &Path, revision: &[u8]) -> Option<[u8; 20]> {
    if let Some(oid) = oid(revision) {
        return Some(oid);
    }
    let head;
    let name = if revision == b"HEAD" {
        head = small_file(&repo.join("HEAD"), 1024)?;
        head.strip_prefix(b"ref: ")?.strip_suffix(b"\n")?
    } else {
        revision
    };
    if name.len() > 1024
        || !name.starts_with(b"refs/")
        || !name.is_ascii()
        || gix_validate::reference::name(name.as_bstr()).is_err()
    {
        return None;
    }
    let name = std::str::from_utf8(name).ok()?;
    let mut parent = repo.to_path_buf();
    let mut components = name.split('/').peekable();
    while let Some(component) = components.next() {
        parent.push(component);
        if components.peek().is_some() && !fs::symlink_metadata(&parent).ok()?.is_dir() {
            return None;
        }
    }
    let bytes = small_file(&parent, 41)?;
    oid(bytes.strip_suffix(b"\n")?)
}
fn body(mut decoder: impl Read, size: usize, active: &impl Fn() -> bool) -> Option<Vec<u8>> {
    if size > MAX_COMMIT || !active() {
        return None;
    }
    let mut body = vec![0u8; size];
    decoder.read_exact(&mut body).ok()?;
    let mut sentinel = [0u8; 1];
    if decoder.read(&mut sentinel).ok()? != 0 || !active() {
        return None;
    }
    Some(body)
}
fn loose(path: &Path, active: &impl Fn() -> bool) -> Option<Vec<u8>> {
    let file = crate::files::open_metadata_file(path).ok()?;
    let mut decoder = ZlibDecoder::new(file.take(MAX_COMPRESSED));
    let mut header = Vec::with_capacity(128);
    for _ in 0..128 {
        if !active() {
            return None;
        }
        let mut byte = [0u8; 1];
        decoder.read_exact(&mut byte).ok()?;
        if byte[0] == 0 {
            let size = header.strip_prefix(b"commit ")?;
            let text = std::str::from_utf8(size).ok()?;
            let size = text.parse::<usize>().ok()?;
            if text != size.to_string() {
                return None;
            }
            return body(decoder, size, active);
        }
        header.push(byte[0]);
    }
    None
}
fn packed(path: &Path, offset: u64, active: &impl Fn() -> bool) -> Option<Vec<u8>> {
    let mut file = crate::files::open_metadata_file(path).ok()?;
    file.seek(SeekFrom::Start(offset)).ok()?;
    let mut byte = [0u8; 1];
    file.read_exact(&mut byte).ok()?;
    // Reject trees/blobs/tags and both delta forms before any decompression.
    if (byte[0] >> 4) & 7 != 1 {
        return None;
    }
    let mut size = usize::from(byte[0] & 15);
    let mut shift = 4u32;
    while byte[0] & 128 != 0 {
        if shift >= usize::BITS || !active() {
            return None;
        }
        file.read_exact(&mut byte).ok()?;
        let piece = usize::from(byte[0] & 127);
        if piece > (usize::MAX >> shift) {
            return None;
        }
        size |= piece << shift;
        shift += 7;
    }
    if size > MAX_COMMIT {
        return None;
    }
    body(ZlibDecoder::new(file.take(MAX_COMPRESSED)), size, active)
}
fn commit(repo: &Path, oid: &[u8; 20], active: &impl Fn() -> bool) -> Option<Vec<u8>> {
    let hex = gix_hash::ObjectId::from_bytes_or_panic(oid)
        .to_hex()
        .to_string();
    let loose_path = repo.join("objects").join(&hex[..2]).join(&hex[2..]);
    if !absent(&loose_path) {
        return loose(&loose_path, active);
    }
    let pack_dir = repo.join("objects/pack");
    if !absent(&pack_dir.join("multi-pack-index"))
        || !fs::symlink_metadata(&pack_dir).ok()?.is_dir()
    {
        return None;
    }
    let mut budget = MAX_INDEX_BYTES;
    let mut indexes = 0;
    for (visited, entry) in fs::read_dir(&pack_dir).ok()?.enumerate() {
        if visited >= 1024 || !active() {
            return None;
        }
        let entry = entry.ok()?;
        let name = entry.file_name();
        let name = name.to_str()?;
        if !name.starts_with("pack-") || !name.ends_with(".idx") {
            continue;
        }
        if name.len() != 49
            || !name.as_bytes()[5..45]
                .iter()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
        {
            return None;
        }
        indexes += 1;
        if indexes > 64 {
            return None;
        }
        let index = crate::presence::Index::load(&entry.path(), budget, active)?;
        budget -= index.byte_len();
        if let Some(offset) = index.offset(oid) {
            return packed(&entry.path().with_extension("pack"), offset, active);
        }
    }
    None
}
pub(crate) fn plain_target(
    repo: &Path,
    revision: &[u8],
    active: &impl Fn() -> bool,
) -> Option<[u8; 20]> {
    if !active() {
        return None;
    }
    crate::refs::eligible(repo)?;
    let config = crate::config::plain_config(&repo.join("config")).ok()??;
    if config
        .sections()
        .any(|section| section.header().name().eq_ignore_ascii_case(b"remote"))
        || std::env::var_os("GIT_REPLACE_REF_BASE").is_some()
    {
        return None;
    }
    for name in [
        "refs/replace",
        "info/grafts",
        "objects/info/alternates",
        "objects/info/http-alternates",
    ] {
        if !absent(&repo.join(name)) {
            return None;
        }
    }
    target(repo, revision)
}

pub(crate) fn resolve(repo: &Path, revision: &[u8], active: &impl Fn() -> bool) -> Option<String> {
    let oid = plain_target(repo, revision, active)?;
    let data = commit(repo, &oid, active)?;
    let parsed = gix_object::CommitRef::from_bytes(&data, gix_hash::Kind::Sha1).ok()?;
    parsed.author().ok()?.time().ok()?;
    parsed.committer().ok()?.time().ok()?;
    let mut hash = sha1dc::Hasher::new();
    hash.update(format!("commit {}\0", data.len()).as_bytes());
    hash.update(&data);
    let digest = hash.finalize().ok()?;
    if digest.as_bytes() != &oid || !active() {
        return None;
    }
    Some(
        gix_hash::ObjectId::from_bytes_or_panic(&oid)
            .to_hex()
            .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oversized_or_cancelled_body_never_reads_or_allocates_object() {
        struct MustNotRead;
        impl Read for MustNotRead {
            fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
                panic!("body read before size/cancellation guard");
            }
        }
        assert!(body(MustNotRead, MAX_COMMIT + 1, &|| true).is_none());
        assert!(body(MustNotRead, 100, &|| false).is_none());
        assert_eq!(body(&b"abc"[..], 3, &|| true), Some(b"abc".to_vec()));
        assert!(body(&b"abcx"[..], 3, &|| true).is_none());
        assert!(body(&b"ab"[..], 3, &|| true).is_none());
    }
    #[test]
    fn revision_hashes_are_exact_and_lowercase() {
        assert!(oid(b"1111111111111111111111111111111111111111").is_some());
        assert!(oid(b"1111111").is_none());
        assert!(oid(b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").is_none());
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn resolve_commit<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    revision: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let result = resolve(repo, revision.as_slice(), &|| {
        start.elapsed() < limit && pid.is_alive(env)
    });
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(oid) => (crate::ok(), oid).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
