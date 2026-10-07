//! Presence-only closure checks for ordinary pack-only SHA1 object directories.
//! Git's empty batch-check format requests no object type, size or contents
//! (builtin/cat-file.c batch_objects/mark_query). The reachability walk stays Git.
//! Index snapshots are bounded and owned: never mmap a mutable cache file.

use std::fs;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

use rustler::{Binary, Encoder, Env, Term};

const MAX_INDEX_BYTES: usize = 4 * 1024 * 1024;
const MAX_INDEXES: usize = 64;
const CHUNK: usize = 64 * 1024;
const TABLE: usize = 8 + 256 * 4;

fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}
fn be32(bytes: &[u8], offset: usize) -> Option<usize> {
    Some(u32::from_be_bytes(bytes.get(offset..offset + 4)?.try_into().ok()?) as usize)
}

pub(crate) struct Index {
    bytes: Vec<u8>,
    count: usize,
}
impl Index {
    pub(crate) fn load(path: &Path, budget: usize, active: &impl Fn() -> bool) -> Option<Self> {
        let mut file = crate::files::open_metadata_file(path).ok()?;
        let size = usize::try_from(file.metadata().ok()?.len()).ok()?;
        if size < TABLE + 40 || size > budget || !active() {
            return None;
        }
        let mut header = [0u8; 8];
        file.read_exact(&mut header).ok()?;
        if &header[..4] != b"\xfftOc" || header[4..] != [0, 0, 0, 2] {
            return None;
        }
        file.seek(SeekFrom::Start(0)).ok()?;
        let mut bytes = vec![0u8; size];
        for chunk in bytes.chunks_mut(CHUNK) {
            if !active() {
                return None;
            }
            file.read_exact(chunk).ok()?;
        }
        let mut sentinel = [0u8; 1];
        if file.read(&mut sentinel).ok()? != 0 {
            return None;
        }
        let count = be32(&bytes, 8 + 255 * 4)?;
        let minimum = TABLE.checked_add(count.checked_mul(28)?)?.checked_add(40)?;
        if size < minimum || (size - minimum) % 8 != 0 {
            return None;
        }
        let large_count = (size - minimum) / 8;
        if large_count > count {
            return None;
        }
        let mut hash = sha1dc::Hasher::new();
        for chunk in bytes[..size - 20].chunks(CHUNK) {
            if !active() {
                return None;
            }
            hash.update(chunk);
        }
        let digest = hash.finalize().ok()?;
        if digest.as_ref() != &bytes[size - 20..] {
            return None;
        }
        let index = Self { bytes, count };
        // Validate bucket counts and sorted names, not only the last fanout.
        let mut cursor = 0;
        let mut previous: Option<&[u8]> = None;
        for bucket in 0..256 {
            while cursor < count && usize::from(index.oid(cursor)[0]) == bucket {
                let oid = index.oid(cursor);
                if previous.is_some_and(|previous| previous > oid) {
                    return None;
                }
                previous = Some(oid);
                cursor += 1;
            }
            if be32(&index.bytes, 8 + bucket * 4)? != cursor {
                return None;
            }
        }
        if cursor != count || !active() {
            return None;
        }
        let mut pack = crate::files::open_metadata_file(&path.with_extension("pack")).ok()?;
        let length = pack.metadata().ok()?.len();
        let mut header = [0u8; 12];
        pack.read_exact(&mut header).ok()?;
        if length < 32
            || &header[..4] != b"PACK"
            || !matches!(be32(&header, 4)?, 2 | 3)
            || be32(&header, 8)? != count
        {
            return None;
        }
        pack.seek(SeekFrom::End(-20)).ok()?;
        let mut footer = [0u8; 20];
        pack.read_exact(&mut footer).ok()?;
        if footer != index.bytes[size - 40..size - 20] {
            return None;
        }
        // Validate every offset without reading object/pack contents.
        for n in 0..count {
            let encoded = be32(&index.bytes, TABLE + count * 24 + n * 4)?;
            let offset = if encoded & 0x8000_0000 == 0 {
                encoded as u64
            } else {
                let slot = encoded & 0x7fff_ffff;
                if slot >= large_count {
                    return None;
                }
                let start = TABLE + count * 28 + slot * 8;
                u64::from_be_bytes(index.bytes.get(start..start + 8)?.try_into().ok()?)
            };
            if offset < 12 || offset >= length - 20 {
                return None;
            }
        }
        Some(index)
    }
    fn oid(&self, n: usize) -> &[u8] {
        &self.bytes[TABLE + n * 20..TABLE + (n + 1) * 20]
    }
    pub(crate) fn byte_len(&self) -> usize {
        self.bytes.len()
    }
    fn contains(&self, oid: &[u8; 20]) -> bool {
        self.slot(oid).is_some()
    }
    pub(crate) fn offset(&self, oid: &[u8; 20]) -> Option<u64> {
        let slot = self.slot(oid)?;
        let encoded = be32(&self.bytes, TABLE + self.count * 24 + slot * 4)?;
        if encoded & 0x8000_0000 == 0 {
            Some(encoded as u64)
        } else {
            let start = TABLE + self.count * 28 + (encoded & 0x7fff_ffff) * 8;
            Some(u64::from_be_bytes(
                self.bytes.get(start..start + 8)?.try_into().ok()?,
            ))
        }
    }
    fn slot(&self, oid: &[u8; 20]) -> Option<usize> {
        let bucket = usize::from(oid[0]);
        let mut low = if bucket == 0 {
            0
        } else {
            be32(&self.bytes, 8 + (bucket - 1) * 4).unwrap_or(0)
        };
        let mut high = be32(&self.bytes, 8 + bucket * 4).unwrap_or(0);
        while low < high {
            let mid = low + (high - low) / 2;
            match self.oid(mid).cmp(oid) {
                std::cmp::Ordering::Less => low = mid + 1,
                std::cmp::Ordering::Greater => high = mid,
                std::cmp::Ordering::Equal => return Some(mid),
            }
        }
        None
    }
}

fn packed_only(path: &Path) -> Option<()> {
    for entry in fs::read_dir(path).ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name();
        if !entry.file_type().ok()?.is_dir() || !matches!(name.to_str()?, "pack" | "info") {
            return None;
        }
    }
    for name in ["info/alternates", "info/http-alternates"] {
        if !absent(&path.join(name)) {
            return None;
        }
    }
    Some(())
}

fn count_missing(
    repo: &Path,
    listed: &Path,
    objects: &Path,
    active: &impl Fn() -> bool,
) -> Option<u64> {
    crate::refs::eligible(repo)?;
    let config = crate::config::plain_config(&repo.join("config")).ok()??;
    // Do not bypass replacement objects or lazy fetching from a promisor.
    if config
        .sections()
        .any(|section| section.header().name().eq_ignore_ascii_case(b"remote"))
        || !absent(&repo.join("refs/replace"))
        || std::env::var_os("GIT_REPLACE_REF_BASE").is_some()
        || !active()
    {
        return None;
    }
    packed_only(objects)?;
    if !absent(&objects.join("pack/multi-pack-index")) {
        return None;
    }
    let mut indexes = Vec::new();
    let mut budget = MAX_INDEX_BYTES;
    match fs::read_dir(objects.join("pack")) {
        Ok(entries) => {
            let mut visited = 0;
            for entry in entries {
                visited += 1;
                if visited > 1024 || !active() {
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
                if indexes.len() == MAX_INDEXES {
                    return None;
                }
                let index = Index::load(&entry.path(), budget, active)?;
                budget -= index.bytes.len();
                indexes.push(index);
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return None,
    }
    let file = crate::files::open_metadata_file(listed).ok()?;
    let mut input = BufReader::with_capacity(CHUNK, file);
    let mut missing = 0u64;
    let mut recent = 0;
    loop {
        if !active() {
            return None;
        }
        let mut row = [0u8; 41];
        if input.read(&mut row[..1]).ok()? == 0 {
            break;
        }
        input.read_exact(&mut row[1..]).ok()?;
        if row[40] != b'\n' {
            return None;
        }
        let mut oid = [0u8; 20];
        for (n, byte) in oid.iter_mut().enumerate() {
            fn nibble(byte: u8) -> Option<u8> {
                match byte {
                    b'0'..=b'9' => Some(byte - b'0'),
                    b'a'..=b'f' => Some(byte - b'a' + 10),
                    _ => None,
                }
            }
            *byte = nibble(row[n * 2])? * 16 + nibble(row[n * 2 + 1])?;
        }
        let mut found = !indexes.is_empty() && indexes[recent].contains(&oid);
        if !found {
            for (n, index) in indexes.iter().enumerate() {
                if index.contains(&oid) {
                    recent = n;
                    found = true;
                    break;
                }
            }
        }
        missing += u64::from(!found);
    }
    Some(missing)
}

#[rustler::nif(schedule = "DirtyIo")]
fn packed_missing<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    listed: Binary<'a>,
    objects: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let listed = Path::new(std::ffi::OsStr::from_bytes(listed.as_slice()));
    let objects = Path::new(std::ffi::OsStr::from_bytes(objects.as_slice()));
    let pid = env.pid();
    let result = count_missing(repo, listed, objects, &|| {
        start.elapsed() < limit && pid.is_alive(env)
    });
    if start.elapsed() >= limit {
        return crate::timeout().encode(env);
    }
    match result {
        Some(count) => (crate::ok(), count).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
