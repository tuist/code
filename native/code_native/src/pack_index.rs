//! Bounded install-time SHA1-v2 index checks. Pack bytes are already verified
//! against the WAL digest. Read only pack header/trailer, never its body.
use rustler::{Binary, Encoder, Env, Term};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
const LIMIT: u64 = 4 * 1024 * 1024;
const CHUNK: usize = 64 * 1024;

fn matches(
    pack_path: &Path,
    index_path: &Path,
    active: &impl Fn() -> bool,
) -> io::Result<Option<bool>> {
    let mut index = crate::files::open_metadata_file(index_path)?;
    let size = index.metadata()?.len();
    if size > LIMIT {
        return Ok(None);
    }
    if size < 1072 || !active() {
        return Ok(Some(false));
    }
    let mut head = [0u8; 1032];
    index.read_exact(&mut head)?;
    if &head[..8] != b"\xfftOc\0\0\0\x02" {
        return Ok(None);
    }
    let count = u32::from_be_bytes(head[1028..].try_into().unwrap());
    let minimum = 1072 + u64::from(count) * 28;
    if size < minimum || (size - minimum) % 8 != 0 {
        return Ok(Some(false));
    }
    let mut pack = crate::files::open_metadata_file(pack_path)?;
    let pack_size = pack.metadata()?.len();
    if pack_size < 32 {
        return Ok(Some(false));
    }
    let mut header = [0u8; 12];
    pack.read_exact(&mut header)?;
    if &header[..4] != b"PACK" || header[8..] != count.to_be_bytes() {
        return Ok(Some(false));
    }
    index.seek(SeekFrom::End(-40))?;
    let mut recorded = [0u8; 40];
    index.read_exact(&mut recorded)?;
    pack.seek(SeekFrom::End(-20))?;
    let mut pack_trailer = [0u8; 20];
    pack.read_exact(&mut pack_trailer)?;
    if recorded[..20] != pack_trailer || !active() {
        return Ok(Some(false));
    }
    index.seek(SeekFrom::Start(0))?;
    let mut hash = sha1dc::Hasher::new();
    let mut buffer = vec![0u8; CHUNK];
    let mut remaining = size - 20;
    while remaining != 0 {
        if !active() {
            return Ok(Some(false));
        }
        let n = remaining.min(CHUNK as u64) as usize;
        index.read_exact(&mut buffer[..n])?;
        hash.update(&buffer[..n]);
        remaining -= n as u64;
    }
    let mut final_footer = [0u8; 20];
    index.read_exact(&mut final_footer)?;
    let mut sentinel = [0u8];
    if index.read(&mut sentinel)? != 0
        || final_footer != recorded[20..]
        || pack.metadata()?.len() != pack_size
        || !active()
    {
        return Ok(Some(false));
    }
    Ok(Some(
        hash.finalize()
            .is_ok_and(|digest| digest.as_bytes() == &final_footer),
    ))
}

#[rustler::nif(schedule = "DirtyIo")]
fn file_index_matches<'a>(env: Env<'a>, pack: Binary<'a>, index: Binary<'a>) -> Term<'a> {
    let pack = Path::new(std::ffi::OsStr::from_bytes(pack.as_slice()));
    let index = Path::new(std::ffi::OsStr::from_bytes(index.as_slice()));
    let pid = env.pid();
    match matches(pack, index, &|| pid.is_alive(env)) {
        Ok(Some(value)) => value.encode(env),
        Ok(None) => crate::fallback_git().encode(env),
        Err(_) => false.encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha1_checked::{Digest, Sha1};
    use std::fs;

    fn digest(bytes: &[u8]) -> [u8; 20] {
        let mut hash = Sha1::new();
        hash.update(bytes);
        let result = hash.try_finalize();
        let bytes: &[u8] = result.hash().as_ref();
        bytes.try_into().unwrap()
    }
    #[test]
    fn header_footer_and_checksum_checks_are_bounded_and_fail_closed() {
        let root = crate::test_support::TestDirectory::new();
        let pack = root.join("file.pack");
        let idx = root.join("unrelated-name.idx");
        let mut body = b"PACK\0\0\0\x02\0\0\0\0".to_vec();
        let trailer = digest(&body);
        body.extend_from_slice(&trailer);
        fs::write(&pack, body).unwrap();
        let mut bytes = b"\xfftOc\0\0\0\x02".to_vec();
        bytes.extend_from_slice(&[0; 1024]);
        bytes.extend_from_slice(&trailer);
        let checksum = digest(&bytes);
        bytes.extend_from_slice(&checksum);
        fs::write(&idx, &bytes).unwrap();
        assert_eq!(matches(&pack, &idx, &|| true).unwrap(), Some(true));
        assert_eq!(matches(&pack, &idx, &|| false).unwrap(), Some(false));
        *bytes.last_mut().unwrap() ^= 1;
        fs::write(&idx, &bytes).unwrap();
        assert_eq!(matches(&pack, &idx, &|| true).unwrap(), Some(false));
        fs::OpenOptions::new()
            .write(true)
            .open(&idx)
            .unwrap()
            .set_len(LIMIT + 1)
            .unwrap();
        assert_eq!(matches(&pack, &idx, &|| true).unwrap(), None);
        fs::remove_dir_all(root).unwrap();
    }
}
