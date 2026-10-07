//! Complete-or-fallback root listings with bounded, verified tree bodies.
//! Blob size lookup reads headers only, including delta result-size varints.
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

use flate2::read::ZlibDecoder;
use rustler::{Binary, Encoder, Env, Term};
#[cfg(test)]
use sha1_checked::{Digest, Sha1};

const MAX_BODY: usize = 512 * 1024;
const MAX_TREE_BYTES: usize = 4 * 1024 * 1024;
const MAX_OUTPUT: usize = 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const MAX_DEPTH: usize = 64;
pub(crate) type Entry = (String, String, String, Option<u64>, String);

struct Pack {
    file: File,
    index: crate::presence::Index,
}
pub(crate) struct Store<'a> {
    repo: &'a Path,
    packs: Vec<Pack>,
}
fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}
fn oid(bytes: &[u8]) -> Option<[u8; 20]> {
    gix_hash::ObjectId::from_hex(bytes)
        .ok()?
        .as_slice()
        .try_into()
        .ok()
}
fn hex(oid: &[u8; 20]) -> String {
    gix_hash::ObjectId::from_bytes_or_panic(oid)
        .to_hex()
        .to_string()
}
fn byte(reader: &mut impl Read) -> Option<u8> {
    let mut byte = [0u8];
    reader.read_exact(&mut byte).ok()?;
    Some(byte[0])
}
fn varint(reader: &mut impl Read) -> Option<u64> {
    let mut result = 0u64;
    for shift in (0..64).step_by(7) {
        let b = byte(reader)?;
        let part = u64::from(b & 127);
        if part > u64::MAX >> shift {
            return None;
        }
        result |= part << shift;
        if b & 128 == 0 {
            return Some(result);
        }
    }
    None
}
fn packed_header(file: &mut File, offset: u64) -> Option<(u8, u64)> {
    file.seek(SeekFrom::Start(offset)).ok()?;
    let mut b = byte(file)?;
    let kind = (b >> 4) & 7;
    let mut size = u64::from(b & 15);
    let mut shift = 4;
    while b & 128 != 0 {
        if shift >= 64 {
            return None;
        }
        b = byte(file)?;
        let part = u64::from(b & 127);
        if part > u64::MAX >> shift {
            return None;
        }
        size |= part << shift;
        shift += 7;
    }
    Some((kind, size))
}
fn loose_header(reader: &mut impl Read) -> Option<(String, u64)> {
    let mut bytes = Vec::with_capacity(128);
    for _ in 0..128 {
        let b = byte(reader)?;
        if b == 0 {
            let text = std::str::from_utf8(&bytes).ok()?;
            let (kind, size) = text.split_once(' ')?;
            let parsed = size.parse::<u64>().ok()?;
            if size != parsed.to_string() {
                return None;
            }
            return Some((kind.to_string(), parsed));
        }
        bytes.push(b);
    }
    None
}
fn read_plain(
    mut reader: impl Read,
    size: u64,
    budget: &mut usize,
    active: &impl Fn() -> bool,
) -> Option<Vec<u8>> {
    let size = usize::try_from(size).ok()?;
    if size > MAX_BODY || size > *budget || !active() {
        return None;
    }
    *budget -= size;
    let mut body = vec![0u8; size];
    for chunk in body.chunks_mut(64 * 1024) {
        if !active() {
            return None;
        }
        reader.read_exact(chunk).ok()?;
    }
    let mut sentinel = [0u8];
    if reader.read(&mut sentinel).ok()? != 0 {
        return None;
    }
    Some(body)
}
fn checked_body(
    body: Vec<u8>,
    kind: &str,
    wanted: &[u8; 20],
    active: &impl Fn() -> bool,
) -> Option<Vec<u8>> {
    let mut hash = sha1dc::Hasher::new();
    hash.update(format!("{kind} {}\0", body.len()).as_bytes());
    hash.update(&body);
    let digest = hash.finalize().ok()?;
    if digest.as_bytes() != wanted || !active() {
        return None;
    }
    Some(body)
}
// Keep compressed read-ahead bounded, avoiding a 32KiB allocation for each
// tiny packed blob while aligning larger streams with our 64KiB output chunks.
fn blob_input_buffer(size: u64) -> Vec<u8> {
    vec![0; if size <= 4096 { 4096 } else { 64 * 1024 }]
}
fn stream_plain(
    mut reader: impl Read,
    size: u64,
    wanted: &[u8; 20],
    budget: &mut usize,
    active: &impl Fn() -> bool,
    consume: &mut impl FnMut(&[u8]) -> Option<()>,
) -> Option<()> {
    if size > 64 * 1024 * 1024 || size > *budget as u64 || !active() {
        return None;
    }
    *budget -= size as usize;
    let mut hash = sha1dc::Hasher::new();
    hash.update(format!("blob {size}\0").as_bytes());
    let mut buffer = [0u8; 64 * 1024];
    let mut remaining = size;
    while remaining > 0 {
        if !active() {
            return None;
        }
        let count = remaining.min(buffer.len() as u64) as usize;
        reader.read_exact(&mut buffer[..count]).ok()?;
        hash.update(&buffer[..count]);
        consume(&buffer[..count])?;
        remaining -= count as u64;
    }
    let mut sentinel = [0u8];
    if reader.read(&mut sentinel).ok()? != 0 {
        return None;
    }
    // finalize is an error on a detected collision, including hardware paths.
    let digest = hash.finalize().ok()?;
    if digest.as_bytes() != wanted || !active() {
        return None;
    }
    Some(())
}
fn read_body(
    reader: impl Read,
    size: u64,
    kind: &str,
    wanted: &[u8; 20],
    active: &impl Fn() -> bool,
) -> Option<Vec<u8>> {
    let mut budget = MAX_BODY;
    checked_body(
        read_plain(reader, size, &mut budget, active)?,
        kind,
        wanted,
        active,
    )
}
impl<'a> Store<'a> {
    pub(crate) fn open(repo: &'a Path, active: &impl Fn() -> bool) -> Option<Self> {
        let pack_dir = repo.join("objects/pack");
        if !absent(&pack_dir.join("multi-pack-index"))
            || !fs::symlink_metadata(&pack_dir).ok()?.is_dir()
        {
            return None;
        }
        let mut packs = Vec::new();
        let mut budget = 4 * 1024 * 1024;
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
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
                || packs.len() >= 64
            {
                return None;
            }
            let index = crate::presence::Index::load(&entry.path(), budget, active)?;
            budget -= index.byte_len();
            let file =
                crate::files::open_metadata_file(&entry.path().with_extension("pack")).ok()?;
            packs.push(Pack { file, index });
        }
        Some(Self { repo, packs })
    }
    fn loose_path(&self, oid: &[u8; 20]) -> std::path::PathBuf {
        let name = hex(oid);
        self.repo.join("objects").join(&name[..2]).join(&name[2..])
    }
    fn body(
        &mut self,
        wanted: &[u8; 20],
        kind: &str,
        active: &impl Fn() -> bool,
    ) -> Option<Vec<u8>> {
        let path = self.loose_path(wanted);
        if !absent(&path) {
            let file = crate::files::open_metadata_file(&path).ok()?;
            let mut decoder = ZlibDecoder::new(file.take(1024 * 1024));
            let (actual, size) = loose_header(&mut decoder)?;
            if actual != kind {
                return None;
            }
            return read_body(decoder, size, kind, wanted, active);
        }
        for pack in &mut self.packs {
            if !active() {
                return None;
            }
            if let Some(offset) = pack.index.offset(wanted) {
                let (actual, size) = packed_header(&mut pack.file, offset)?;
                let expected = if kind == "tree" { 2 } else { 1 };
                if actual != expected {
                    return None;
                }
                return read_body(
                    ZlibDecoder::new((&mut pack.file).take(1024 * 1024)),
                    size,
                    kind,
                    wanted,
                    active,
                );
            }
        }
        None
    }
    fn expanded_oid(
        &mut self,
        wanted: &[u8; 20],
        depth: usize,
        budget: &mut usize,
        active: &impl Fn() -> bool,
    ) -> Option<(u8, Vec<u8>)> {
        if depth > MAX_DEPTH || !active() {
            return None;
        }
        let path = self.loose_path(wanted);
        if !absent(&path) {
            let file = crate::files::open_metadata_file(&path).ok()?;
            let mut decoder = ZlibDecoder::new(file.take(1024 * 1024));
            let (kind, size) = loose_header(&mut decoder)?;
            let kind = match kind.as_str() {
                "commit" => 1,
                "tree" => 2,
                "blob" => 3,
                "tag" => 4,
                _ => return None,
            };
            return Some((kind, read_plain(decoder, size, budget, active)?));
        }
        for n in 0..self.packs.len() {
            if let Some(offset) = self.packs[n].index.offset(wanted) {
                return self.expanded_pack(n, offset, depth, budget, active);
            }
        }
        None
    }
    fn expanded_pack(
        &mut self,
        n: usize,
        offset: u64,
        depth: usize,
        budget: &mut usize,
        active: &impl Fn() -> bool,
    ) -> Option<(u8, Vec<u8>)> {
        if depth > MAX_DEPTH || !active() {
            return None;
        }
        let pack = &mut self.packs[n];
        let (kind, size) = packed_header(&mut pack.file, offset)?;
        if (1..=4).contains(&kind) {
            return Some((
                kind,
                read_plain(
                    ZlibDecoder::new((&mut pack.file).take(1024 * 1024)),
                    size,
                    budget,
                    active,
                )?,
            ));
        }
        let mut base_oid = None;
        let mut base_offset = None;
        match kind {
            6 => {
                let mut b = byte(&mut pack.file)?;
                let mut distance = u64::from(b & 127);
                let mut length = 1;
                while b & 128 != 0 {
                    if length >= 10 {
                        return None;
                    }
                    b = byte(&mut pack.file)?;
                    distance = distance
                        .checked_add(1)?
                        .checked_mul(128)?
                        .checked_add(u64::from(b & 127))?;
                    length += 1;
                }
                let base = offset.checked_sub(distance)?;
                if distance == 0 || base < 12 {
                    return None;
                }
                base_offset = Some(base);
            }
            7 => {
                let mut oid = [0u8; 20];
                pack.file.read_exact(&mut oid).ok()?;
                base_oid = Some(oid);
            }
            _ => return None,
        }
        let instructions = read_plain(
            ZlibDecoder::new((&mut pack.file).take(1024 * 1024)),
            size,
            budget,
            active,
        )?;
        // Reject giant advertised bases/results BEFORE following the base.
        let header = crate::delta::header(&instructions, *budget)?;
        let (base_type, base) = if let Some(offset) = base_offset {
            self.expanded_pack(n, offset, depth + 1, budget, active)?
        } else {
            self.expanded_oid(&base_oid?, depth + 1, budget, active)?
        };
        if header.result > *budget {
            return None;
        }
        *budget -= header.result;
        Some((
            base_type,
            crate::delta::apply(&base, &instructions, header, active)?,
        ))
    }
    pub(crate) fn walk_metadata(
        &mut self,
        wanted: &[u8; 20],
        active: &impl Fn() -> bool,
    ) -> Option<(u8, u64)> {
        self.info(wanted, 0, active)
    }
    pub(crate) fn walk_body(
        &mut self,
        wanted: &[u8; 20],
        kind: u8,
        budget: &mut usize,
        active: &impl Fn() -> bool,
    ) -> Option<Vec<u8>> {
        let (actual, size) = self.info(wanted, 0, active)?;
        let cap = if kind == 1 { 64 * 1024 } else { MAX_BODY };
        if actual != kind || size > cap as u64 || size > *budget as u64 {
            return None;
        }
        let (actual, body) = self.expanded_oid(wanted, 0, budget, active)?;
        if actual != kind || body.len() > cap {
            return None;
        }
        checked_body(
            body,
            if kind == 1 { "commit" } else { "tree" },
            wanted,
            active,
        )
    }
    pub(crate) fn history_commit(
        &mut self,
        wanted: &[u8; 20],
        budget: &mut usize,
        active: &impl Fn() -> bool,
    ) -> Option<Vec<u8>> {
        let (kind, size) = self.info(wanted, 0, active)?;
        if kind != 1 || size > 64 * 1024 {
            return None;
        }
        let (kind, body) = self.expanded_oid(wanted, 0, budget, active)?;
        if kind != 1 || body.len() > 64 * 1024 {
            return None;
        }
        checked_body(body, "commit", wanted, active)
    }
    pub(crate) fn stream_blob(
        &mut self,
        wanted: &[u8; 20],
        budget: &mut usize,
        active: &impl Fn() -> bool,
        consume: &mut impl FnMut(&[u8]) -> Option<()>,
    ) -> Option<()> {
        let path = self.loose_path(wanted);
        if !absent(&path) {
            let file = crate::files::open_metadata_file(&path).ok()?;
            let mut decoder = ZlibDecoder::new(file.take(128 * 1024 * 1024));
            let (kind, size) = loose_header(&mut decoder)?;
            if kind != "blob" {
                return None;
            }
            return stream_plain(decoder, size, wanted, budget, active, consume);
        }
        for pack in &mut self.packs {
            if !active() {
                return None;
            }
            if let Some(offset) = pack.index.offset(wanted) {
                let (kind, size) = packed_header(&mut pack.file, offset)?;
                if kind == 3 {
                    return stream_plain(
                        ZlibDecoder::new_with_buf(
                            (&mut pack.file).take(128 * 1024 * 1024),
                            blob_input_buffer(size),
                        ),
                        size,
                        wanted,
                        budget,
                        active,
                        consume,
                    );
                }
                if !matches!(kind, 6 | 7) {
                    return None;
                }
                break;
            }
        }
        // Delta bodies/bases retain the existing 512KiB/4MiB guards.
        let body = self.blob(wanted, active)?;
        if body.len() > *budget {
            return None;
        }
        *budget -= body.len();
        for chunk in body.chunks(64 * 1024) {
            if !active() {
                return None;
            }
            consume(chunk)?;
        }
        Some(())
    }
    fn blob(&mut self, wanted: &[u8; 20], active: &impl Fn() -> bool) -> Option<Vec<u8>> {
        let mut budget = 4 * 1024 * 1024;
        let (kind, body) = self.expanded_oid(wanted, 0, &mut budget, active)?;
        if kind != 3 {
            return None;
        }
        checked_body(body, "blob", wanted, active)
    }
    fn size(&mut self, wanted: &[u8; 20], active: &impl Fn() -> bool) -> Option<u64> {
        self.info(wanted, 0, active).map(|(_, size)| size)
    }
    fn info(
        &mut self,
        wanted: &[u8; 20],
        depth: usize,
        active: &impl Fn() -> bool,
    ) -> Option<(u8, u64)> {
        if depth > MAX_DEPTH || !active() {
            return None;
        }
        let path = self.loose_path(wanted);
        if !absent(&path) {
            let file = crate::files::open_metadata_file(&path).ok()?;
            let (kind, size) = loose_header(&mut ZlibDecoder::new(file.take(64 * 1024)))?;
            let kind = match kind.as_str() {
                "commit" => 1,
                "tree" => 2,
                "blob" => 3,
                "tag" => 4,
                _ => return None,
            };
            return Some((kind, size));
        }
        for n in 0..self.packs.len() {
            if let Some(offset) = self.packs[n].index.offset(wanted) {
                return self.packed_info(n, offset, depth, active);
            }
        }
        None
    }
    fn packed_info(
        &mut self,
        n: usize,
        offset: u64,
        depth: usize,
        active: &impl Fn() -> bool,
    ) -> Option<(u8, u64)> {
        if depth > MAX_DEPTH || !active() {
            return None;
        }
        let pack = &mut self.packs[n];
        let (kind, delta_size) = packed_header(&mut pack.file, offset)?;
        if (1..=4).contains(&kind) {
            return Some((kind, delta_size));
        }
        let mut base_oid = None;
        let mut base_offset = None;
        match kind {
            6 => {
                let mut b = byte(&mut pack.file)?;
                let mut distance = u64::from(b & 127);
                let mut length = 1;
                while b & 128 != 0 {
                    if length >= 10 {
                        return None;
                    }
                    b = byte(&mut pack.file)?;
                    distance = distance
                        .checked_add(1)?
                        .checked_mul(128)?
                        .checked_add(u64::from(b & 127))?;
                    length += 1;
                }
                let base = offset.checked_sub(distance)?;
                if distance == 0 || base < 12 {
                    return None;
                }
                base_offset = Some(base);
            }
            7 => {
                let mut oid = [0u8; 20];
                pack.file.read_exact(&mut oid).ok()?;
                base_oid = Some(oid);
            }
            _ => return None,
        }
        if delta_size < 2 {
            return None;
        }
        // Only metadata is inflated; never allocate a delta result/base body.
        let result_size = {
            let mut decoder = ZlibDecoder::new((&mut pack.file).take(64 * 1024)).take(delta_size);
            varint(&mut decoder)?;
            varint(&mut decoder)?
        };
        let (base_type, _) = if let Some(offset) = base_offset {
            self.packed_info(n, offset, depth + 1, active)?
        } else {
            self.info(&base_oid?, depth + 1, active)?
        };
        Some((base_type, result_size))
    }
}
struct Output {
    entries: Vec<Entry>,
    bytes: usize,
    trees: usize,
    visited: usize,
}
impl Output {
    fn walk(
        &mut self,
        store: &mut Store<'_>,
        tree: &[u8; 20],
        prefix: &str,
        recursive: bool,
        depth: usize,
        active: &impl Fn() -> bool,
    ) -> Option<()> {
        if depth > MAX_DEPTH || !active() {
            return None;
        }
        let data = store.body(tree, "tree", active)?;
        self.trees = self.trees.checked_add(data.len())?;
        if self.trees > MAX_TREE_BYTES {
            return None;
        }
        for entry in gix_object::TreeRefIter::from_bytes(&data, gix_hash::Kind::Sha1) {
            if !active() {
                return None;
            }
            self.visited += 1;
            if self.visited > 8192 {
                return None;
            }
            let entry = entry.ok()?;
            let name: &[u8] = entry.filename.as_ref();
            if name.is_empty()
                || !name.is_ascii()
                || name.contains(&b'/')
                || name == b"."
                || name == b".."
            {
                return None;
            }
            let name = std::str::from_utf8(name).ok()?;
            let path = format!("{prefix}{name}");
            if path.len() > 2048 {
                return None;
            }
            let oid: [u8; 20] = entry.oid.as_bytes().try_into().ok()?;
            let mode = entry.mode.value();
            if !matches!(mode, 0o040000 | 0o100644 | 0o100755 | 0o120000 | 0o160000) {
                return None;
            }
            if mode == 0o040000 && recursive {
                self.walk(
                    store,
                    &oid,
                    &format!("{path}/"),
                    recursive,
                    depth + 1,
                    active,
                )?;
            } else {
                let (kind, size) = match mode {
                    0o040000 => ("tree", None),
                    0o160000 => ("commit", None),
                    _ => ("blob", Some(store.size(&oid, active)?)),
                };
                self.bytes = self.bytes.checked_add(path.len() + 54)?;
                if self.bytes > MAX_OUTPUT || self.entries.len() >= MAX_ENTRIES {
                    return None;
                }
                self.entries.push((
                    format!("{mode:06o}"),
                    kind.to_string(),
                    hex(&oid),
                    size,
                    path,
                ));
            }
        }
        Some(())
    }
}
pub(crate) fn listing(
    repo: &Path,
    revision: &[u8],
    recursive: bool,
    active: &impl Fn() -> bool,
) -> Option<Vec<Entry>> {
    let commit = oid(crate::resolve::resolve(repo, revision, active)?.as_bytes())?;
    let mut store = Store::open(repo, active)?;
    let body = store.body(&commit, "commit", active)?;
    let parsed = gix_object::CommitRef::from_bytes(&body, gix_hash::Kind::Sha1).ok()?;
    let tree = oid(parsed.tree)?;
    let mut output = Output {
        entries: Vec::new(),
        bytes: 0,
        trees: 0,
        visited: 0,
    };
    output.walk(&mut store, &tree, "", recursive, 0, active)?;
    Some(output.entries)
}
fn file_blob(
    repo: &Path,
    revision: &[u8],
    path: &[u8],
    active: &impl Fn() -> bool,
) -> Option<Vec<u8>> {
    if path.is_empty() || path.len() > 2048 || !path.is_ascii() {
        return None;
    }
    let text = std::str::from_utf8(path).ok()?;
    let parts: Vec<_> = text.split('/').collect();
    if parts.len() > MAX_DEPTH || parts.iter().any(|part| matches!(*part, "" | "." | "..")) {
        return None;
    }
    let commit = oid(crate::resolve::resolve(repo, revision, active)?.as_bytes())?;
    let mut store = Store::open(repo, active)?;
    let body = store.body(&commit, "commit", active)?;
    let parsed = gix_object::CommitRef::from_bytes(&body, gix_hash::Kind::Sha1).ok()?;
    let mut tree = oid(parsed.tree)?;
    let mut trees = 0usize;
    let mut visited = 0usize;
    for (depth, component) in parts.iter().enumerate() {
        let data = store.body(&tree, "tree", active)?;
        trees = trees.checked_add(data.len())?;
        if trees > MAX_TREE_BYTES || !active() {
            return None;
        }
        let mut found = None;
        for entry in gix_object::TreeRefIter::from_bytes(&data, gix_hash::Kind::Sha1) {
            visited += 1;
            if visited > 8192 || !active() {
                return None;
            }
            let entry = entry.ok()?;
            let name: &[u8] = entry.filename.as_ref();
            if name == component.as_bytes() {
                if found.is_some() {
                    return None;
                }
                found = Some((entry.mode.value(), entry.oid.as_bytes().try_into().ok()?));
            }
        }
        let (mode, target) = found?;
        if depth + 1 == parts.len() {
            if !matches!(mode, 0o100644 | 0o100755 | 0o120000) {
                return None;
            }
            return store.blob(&target, active);
        }
        if mode != 0o040000 {
            return None;
        }
        tree = target;
    }
    None
}
#[rustler::nif(schedule = "DirtyIo")]
fn read_blob<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    revision: Binary<'a>,
    path: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let result = file_blob(repo, revision.as_slice(), path.as_slice(), &|| {
        start.elapsed() < limit && pid.is_alive(env)
    });
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(body) => {
            let mut binary = rustler::NewBinary::new(env, body.len());
            binary.as_mut_slice().copy_from_slice(&body);
            (crate::ok(), Term::from(binary)).encode(env)
        }
        None => crate::fallback_git().encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn varints_reject_truncated_or_overflowing_metadata() {
        assert_eq!(varint(&mut &b"\x80\x01"[..]), Some(128));
        assert_eq!(varint(&mut &[0xffu8; 11][..]), None);
        assert_eq!(varint(&mut &[0x80u8][..]), None);
    }
    #[test]
    fn oversized_stream_never_reads_or_calls_the_consumer() {
        struct MustNotRead;
        impl Read for MustNotRead {
            fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
                panic!("read before stream size guard");
            }
        }
        let mut budget = 128 * 1024 * 1024;
        assert!(stream_plain(
            MustNotRead,
            64 * 1024 * 1024 + 1,
            &[0; 20],
            &mut budget,
            &|| true,
            &mut |_| panic!("consumed before guard")
        )
        .is_none());
        assert!(stream_plain(
            MustNotRead,
            1,
            &[0; 20],
            &mut budget,
            &|| false,
            &mut |_| panic!("consumed after cancellation")
        )
        .is_none());
    }
    #[test]
    fn accelerated_sha1_rejects_known_collisions_and_matches_the_previous_checker() {
        let vectors: [&[u8]; 2] = [
            include_bytes!("../tests/data/sha-mbles-1.bin"),
            include_bytes!("../tests/data/sha-mbles-2.bin"),
        ];
        for vector in vectors {
            for scalar in [false, true] {
                for chunk in [1, 17, 64, 65, 511] {
                    let mut fast = if scalar {
                        sha1dc::Hasher::builder().internal_scalar_backend().build()
                    } else {
                        sha1dc::Hasher::new()
                    };
                    let mut previous = Sha1::new();
                    for bytes in vector.chunks(chunk) {
                        fast.update(bytes);
                        previous.update(bytes);
                    }
                    assert!(previous.try_finalize().has_collision());
                    assert!(
                        fast.finalize().is_err(),
                        "accepted known collision scalar={scalar} chunk={chunk}"
                    );
                }
            }
            let header = format!("blob {}\0", vector.len());
            let mut fast = sha1dc::Hasher::new();
            let mut previous = Sha1::new();
            fast.update(header.as_bytes());
            previous.update(header.as_bytes());
            fast.update(vector);
            previous.update(vector);
            let old = previous.try_finalize();
            if old.has_collision() {
                assert!(fast.finalize().is_err());
            } else {
                let expected: &[u8] = old.hash().as_ref();
                assert_eq!(fast.finalize().unwrap().as_ref(), expected);
            }
        }
        for size in [0usize, 1, 55, 56, 63, 64, 65, 8000, 65535, 65536, 65537] {
            let input: Vec<u8> = (0..size)
                .map(|n| n.wrapping_mul(37).wrapping_add(11) as u8)
                .collect();
            for chunk in [1, 63, 64, 65, 4096] {
                let mut fast = sha1dc::Hasher::new();
                let mut previous = Sha1::new();
                for part in input.chunks(chunk) {
                    fast.update(part);
                    previous.update(part);
                }
                let old = previous.try_finalize();
                assert!(!old.has_collision());
                let expected: &[u8] = old.hash().as_ref();
                assert_eq!(fast.finalize().unwrap().as_ref(), expected);
            }
        }
    }
    #[test]
    fn bounded_body_verifier_matches_independent_oracle_for_all_git_object_kinds() {
        for kind in ["blob", "tree", "commit"] {
            for size in [0usize, 1, 55, 4096, 4097, 65536, 512 * 1024] {
                let data = vec![42u8; size];
                let mut previous = Sha1::new();
                previous.update(format!("{kind} {size}\0"));
                previous.update(&data);
                let digest = previous.try_finalize();
                assert!(!digest.has_collision());
                let bytes: &[u8] = digest.hash().as_ref();
                let wanted: [u8; 20] = bytes.try_into().unwrap();
                assert_eq!(
                    checked_body(data.clone(), kind, &wanted, &|| true),
                    Some(data.clone())
                );
                assert!(checked_body(data.clone(), kind, &wanted, &|| false).is_none());
                let mut wrong = wanted;
                wrong[0] ^= 1;
                assert!(checked_body(data, kind, &wrong, &|| true).is_none());
            }
        }
    }
    #[test]
    fn blob_compressed_read_ahead_is_bounded_independently_of_object_size() {
        assert_eq!(blob_input_buffer(0).len(), 4096);
        assert_eq!(blob_input_buffer(4096).len(), 4096);
        assert_eq!(blob_input_buffer(4097).len(), 64 * 1024);
        assert_eq!(blob_input_buffer(u64::MAX).len(), 64 * 1024);
    }
    #[test]
    fn streaming_deflate_verifies_every_chunk_and_rejects_corruption() {
        use std::io::Write;
        for size in [4096, 4097, 128 * 1024 + 1] {
            let body = vec![b'x'; size];
            let mut hash = Sha1::new();
            hash.update(format!("blob {}\0", body.len()));
            hash.update(&body);
            let digest = hash.try_finalize();
            let bytes: &[u8] = digest.hash().as_ref();
            let wanted: [u8; 20] = bytes.try_into().unwrap();
            let mut encoder =
                flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(&body).unwrap();
            let encoded = encoder.finish().unwrap();
            let mut budget = body.len();
            let mut offset = 0;
            assert!(stream_plain(
                ZlibDecoder::new_with_buf(encoded.as_slice(), blob_input_buffer(body.len() as u64)),
                body.len() as u64,
                &wanted,
                &mut budget,
                &|| true,
                &mut |chunk| {
                    assert!(chunk.len() <= 64 * 1024);
                    assert_eq!(chunk, &body[offset..offset + chunk.len()]);
                    offset += chunk.len();
                    Some(())
                }
            )
            .is_some());
            assert_eq!(offset, body.len());
            assert_eq!(budget, 0);
            let mut corrupted = encoded;
            *corrupted.last_mut().unwrap() ^= 1;
            let mut budget = body.len();
            assert!(stream_plain(
                ZlibDecoder::new_with_buf(
                    corrupted.as_slice(),
                    blob_input_buffer(body.len() as u64)
                ),
                body.len() as u64,
                &wanted,
                &mut budget,
                &|| true,
                &mut |_| Some(())
            )
            .is_none());
            for removed in 1..=6 {
                let mut budget = body.len();
                assert!(
                    stream_plain(
                        ZlibDecoder::new_with_buf(
                            &corrupted[..corrupted.len() - removed],
                            blob_input_buffer(body.len() as u64)
                        ),
                        body.len() as u64,
                        &wanted,
                        &mut budget,
                        &|| true,
                        &mut |_| Some(())
                    )
                    .is_none(),
                    "accepted truncated stream missing {removed} bytes"
                );
            }
        }
    }
    #[test]
    fn oversized_tree_never_reads_body() {
        struct MustNotRead;
        impl Read for MustNotRead {
            fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
                panic!("read before tree size guard");
            }
        }
        assert!(read_body(
            MustNotRead,
            (MAX_BODY + 1) as u64,
            "tree",
            &[0; 20],
            &|| true
        )
        .is_none());
        assert!(read_body(MustNotRead, 100, "tree", &[0; 20], &|| false).is_none());
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn root_tree<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    revision: Binary<'a>,
    recursive: bool,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let result = listing(repo, revision.as_slice(), recursive, &|| {
        start.elapsed() < limit && pid.is_alive(env)
    });
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(entries) => (crate::ok(), entries).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
