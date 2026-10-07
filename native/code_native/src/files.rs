//! Bounded file work. Pack bytes never enter the BEAM or an unbounded Vec.
use std::fs::File;
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use rustler::{Atom, Binary, Encoder, Env, LocalPid, ResourceArc, Term};
use sha2::{Digest, Sha256};
use std::sync::Mutex;
use std::time::{Duration, Instant};

rustler::atoms! { ok, error, enoent, eacces, eisdir, enotdir, einval, eio, invalid_pack, more, timeout }

const HASH_CHUNK: usize = 64 * 1024;

#[cfg(test)]
fn hash_reader(mut reader: impl Read) -> io::Result<(String, u64)> {
    let mut buffer = vec![0; HASH_CHUNK];
    let mut hash = Sha256::new();
    let mut size = 0;
    loop {
        let n = match reader.read(&mut buffer) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        size += n as u64;
    }
    // Only the 64-byte digest crosses the NIF boundary, never file chunks.
    Ok((hex_digest(&hash.finalize()), size))
}

fn hex_digest(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        result.push(HEX[(byte >> 4) as usize] as char);
        result.push(HEX[(byte & 15) as usize] as char);
    }
    result
}

const HASH_QUANTUM: usize = 4 * 1024 * 1024;
struct HashProgress {
    file: File,
    hash: Sha256,
    size: u64,
}
pub struct FileHash {
    owner: LocalPid,
    deadline: Instant,
    state: Mutex<Option<HashProgress>>,
}
#[rustler::resource_impl]
impl rustler::Resource for FileHash {}

fn hash_slice(
    reader: &mut impl Read,
    hash: &mut Sha256,
    size: &mut u64,
    active: &impl Fn() -> bool,
) -> io::Result<bool> {
    let mut buffer = [0; HASH_CHUNK];
    let mut processed = 0;
    while processed < HASH_QUANTUM {
        if !active() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        let n = match reader.read(&mut buffer) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            return Ok(true);
        }
        hash.update(&buffer[..n]);
        *size += n as u64;
        processed += n;
    }
    Ok(false)
}

fn io_error_atom(e: &io::Error) -> Atom {
    match e.kind() {
        io::ErrorKind::NotFound => enoent(),
        io::ErrorKind::PermissionDenied => eacces(),
        io::ErrorKind::IsADirectory => eisdir(),
        io::ErrorKind::NotADirectory => enotdir(),
        io::ErrorKind::InvalidInput => einval(),
        _ => eio(),
    }
}

// Rolling suffix: neither complete stdout nor even one long line is buffered.
fn line_counts(mut reader: impl Read, active: &impl Fn() -> bool) -> io::Result<(u64, u64)> {
    let mut buffer = vec![0u8; HASH_CHUNK];
    let (mut total, mut missing, mut tail, mut nonempty) = (0u64, 0u64, 0u64, false);
    loop {
        if !active() {
            return Err(io::ErrorKind::Interrupted.into());
        }
        let n = match reader.read(&mut buffer) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            break;
        }
        for &byte in &buffer[..n] {
            if byte == b'\n' {
                total += u64::from(nonempty);
                missing += u64::from(tail == u64::from_be_bytes(*b" missing"));
                tail = 0;
                nonempty = false;
            } else {
                tail = (tail << 8) | u64::from(byte);
                nonempty = true;
            }
        }
    }
    Ok((
        total + u64::from(nonempty),
        missing + u64::from(tail == u64::from_be_bytes(*b" missing")),
    ))
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_line_counts<'a>(env: Env<'a>, path: Binary<'a>) -> Term<'a> {
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    let pid = env.pid();
    match open_metadata_file(path).and_then(|file| line_counts(file, &|| pid.is_alive(env))) {
        Ok((total, missing)) => (ok(), total, missing).encode(env),
        Err(error) => (self::error(), io_error_atom(&error)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_sha256_start<'a>(env: Env<'a>, path: Binary<'a>) -> Term<'a> {
    use std::os::unix::fs::OpenOptionsExt;
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    let result = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .and_then(|file| {
            let meta = file.metadata()?;
            if meta.is_dir() {
                return Err(io::ErrorKind::IsADirectory.into());
            }
            if !meta.is_file() {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            Ok(file)
        });
    match result {
        Ok(file) => (
            ok(),
            ResourceArc::new(FileHash {
                owner: env.pid(),
                deadline: Instant::now() + Duration::from_secs(1800),
                state: Mutex::new(Some(HashProgress {
                    file,
                    hash: Sha256::new(),
                    size: 0,
                })),
            }),
        )
            .encode(env),
        Err(reason) => (error(), io_error_atom(&reason)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_sha256_step<'a>(env: Env<'a>, resource: ResourceArc<FileHash>) -> Term<'a> {
    if resource.owner != env.pid() {
        return (error(), eacces()).encode(env);
    }
    let Ok(mut state) = resource.state.try_lock() else {
        return (error(), eio()).encode(env);
    };
    let Some(progress) = state.as_mut() else {
        return (error(), einval()).encode(env);
    };
    let result = hash_slice(
        &mut progress.file,
        &mut progress.hash,
        &mut progress.size,
        &|| resource.owner.is_alive(env) && Instant::now() < resource.deadline,
    );
    match result {
        Ok(false) => more().encode(env),
        Ok(true) => {
            let progress = state.take().unwrap();
            (ok(), hex_digest(&progress.hash.finalize()), progress.size).encode(env)
        }
        Err(reason) => {
            state.take();
            let code = if reason.kind() == io::ErrorKind::TimedOut {
                timeout()
            } else {
                io_error_atom(&reason)
            };
            (error(), code).encode(env)
        }
    }
}

// Compare a cache file without copying its contents into a BEAM binary.
// Failure means "not known to match", so Git still performs the validating write.
pub(crate) fn open_metadata_file(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "not a regular metadata file",
        ));
    }
    Ok(file)
}

fn matches_file(path: &Path, expected: &[u8]) -> io::Result<bool> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.len() != expected.len() as u64 {
        return Ok(false);
    }
    let mut buffer = [0u8; 1024];
    for chunk in expected.chunks(buffer.len()) {
        file.read_exact(&mut buffer[..chunk.len()])?;
        if &buffer[..chunk.len()] != chunk {
            return Ok(false);
        }
    }
    // Check EOF, too: the file may have grown since the metadata read.
    Ok(file.read(&mut buffer[..1])? == 0)
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_matches(path: Binary<'_>, expected: Binary<'_>) -> bool {
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    matches_file(path, expected.as_slice()).unwrap_or(false)
}

// pack-objects can legitimately create an empty pack for a ref-only update.
// Only inspect its fixed header: no pack data is copied into the BEAM.
fn pack_count(mut reader: impl Read) -> io::Result<u32> {
    let mut header = [0; 12];
    reader.read_exact(&mut header)?;
    let version = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
    if &header[..4] != b"PACK" || !matches!(version, 2 | 3) {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(u32::from_be_bytes([
        header[8], header[9], header[10], header[11],
    ]))
}

// A v1 SHA1 index is at least 1024 fanout bytes + 24 per object +
// two 20-byte checksums. V2 and SHA256 indexes are larger. If this
// lower bound dominates the pack, retaining a separate hint costs more
// bytes and requests than the data it accelerates. Never read a pack body.
#[rustler::nif(schedule = "DirtyIo")]
fn file_pack_hint_omit(env: Env<'_>, path: Binary<'_>) -> bool {
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    let result = (|| {
        if !env.pid().is_alive(env) {
            return None;
        }
        let file = open_metadata_file(path).ok()?;
        let size = file.metadata().ok()?.len();
        let count = pack_count(file).ok()?;
        Some(size <= 1064 + u64::from(count) * 24)
    })();
    result.unwrap_or(false)
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_pack_count<'a>(env: Env<'a>, path: Binary<'a>) -> Term<'a> {
    let path = Path::new(std::ffi::OsStr::from_bytes(path.as_slice()));
    match File::open(path).and_then(pack_count) {
        Ok(count) => (ok(), count).encode(env),
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::UnexpectedEof
            ) =>
        {
            (error(), invalid_pack()).encode(env)
        }
        Err(e) => (error(), io_error_atom(&e)).encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_counts_handle_chunks_long_lines_and_unterminated_output() {
        assert_eq!(line_counts(&b"\n\n"[..], &|| true).unwrap(), (0, 0));
        assert_eq!(
            line_counts(&b"x missing\n\ny missing"[..], &|| true).unwrap(),
            (2, 2)
        );
        for offset in HASH_CHUNK - 8..HASH_CHUNK + 2 {
            let mut data = vec![b'x'; offset];
            data.extend_from_slice(b" missing\nnext missing");
            assert_eq!(line_counts(&data[..], &|| true).unwrap(), (2, 2));
        }
        struct Million {
            remaining: usize,
            pos: usize,
        }
        impl Read for Million {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(out.len() <= HASH_CHUNK);
                let pattern = b"oid missing\n";
                let n = out.len().min(self.remaining);
                for byte in &mut out[..n] {
                    *byte = pattern[self.pos % pattern.len()];
                    self.pos += 1;
                }
                self.remaining -= n;
                Ok(n)
            }
        }
        assert_eq!(
            line_counts(
                Million {
                    remaining: b"oid missing\n".len() * 1_000_000,
                    pos: 0
                },
                &|| true
            )
            .unwrap(),
            (1_000_000, 1_000_000)
        );
        assert!(line_counts(&b"anything"[..], &|| false).is_err());
    }

    #[test]
    fn pack_count_validates_fixed_headers() {
        assert_eq!(pack_count(&b"PACK\0\0\0\x02\0\0\0\0"[..]).unwrap(), 0);
        assert_eq!(pack_count(&b"PACK\0\0\0\x03\0\0\0\x05"[..]).unwrap(), 5);
        assert!(pack_count(&b"PACK\0\0\0\x01\0\0\0\0"[..]).is_err());
        assert!(pack_count(&b"NOPE\0\0\0\x02\0\0\0\0"[..]).is_err());
        assert!(pack_count(&b"PACK"[..]).is_err());
    }

    #[test]
    fn hash_calls_have_a_fixed_work_quantum_and_cancellation() {
        let bytes = vec![42; HASH_QUANTUM + HASH_CHUNK];
        let mut reader = &bytes[..];
        let mut hash = Sha256::new();
        let mut size = 0;
        assert!(!hash_slice(&mut reader, &mut hash, &mut size, &|| true).unwrap());
        assert_eq!(size, HASH_QUANTUM as u64);
        assert_eq!(reader.len(), HASH_CHUNK);
        assert!(hash_slice(&mut reader, &mut hash, &mut size, &|| false).is_err());
        assert_eq!(reader.len(), HASH_CHUNK);
        assert!(hash_slice(&mut reader, &mut hash, &mut size, &|| true).unwrap());
        assert_eq!(size, bytes.len() as u64);
        assert_eq!(hash.finalize(), Sha256::digest(bytes));
    }

    #[test]
    fn hashes_empty_and_known_bytes() {
        assert_eq!(
            hash_reader(&b""[..]).unwrap(),
            (
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
                0
            )
        );
        assert_eq!(
            hash_reader(&b"abc"[..]).unwrap(),
            (
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
                3
            )
        );
    }

    #[test]
    fn reads_are_bounded_and_interrupted_reads_are_retried() {
        struct Reader {
            remaining: usize,
            interrupted: bool,
        }
        impl Read for Reader {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(out.len() <= HASH_CHUNK);
                if !self.interrupted {
                    self.interrupted = true;
                    return Err(io::ErrorKind::Interrupted.into());
                }
                let n = out.len().min(self.remaining);
                out[..n].fill(42);
                self.remaining -= n;
                Ok(n)
            }
        }
        let size = HASH_CHUNK * 5 + 13;
        let (digest, count) = hash_reader(Reader {
            remaining: size,
            interrupted: false,
        })
        .unwrap();
        assert_eq!(count, size as u64);
        assert_eq!(digest, hex_digest(&Sha256::digest(vec![42; size])));
    }
}
