//! Copy only into a private pack stage, through owned descriptors and a fixed
//! buffer. Unlike CoW pathname APIs, O_EXCL returns the inode we must clean up.
use rustler::{Binary, Encoder, Env, Term};
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

rustler::atoms! { eio, enoent, eacces, eexist, ecanceled, estale, einval }
const CHUNK: usize = 64 * 1024;
fn buffer_size(size: u64) -> usize {
    if size >= 1024 * 1024 {
        CHUNK * 4
    } else {
        CHUNK
    }
}
fn failure(errno: i32) -> io::Error {
    io::Error::from_raw_os_error(errno)
}
fn owned(parent: &File, leaf: &CString, file: &File) -> bool {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            leaf.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return false;
    }
    let stat = unsafe { stat.assume_init() };
    file.metadata()
        .is_ok_and(|meta| meta.dev() == stat.st_dev as u64 && meta.ino() == stat.st_ino as u64)
}
struct Output<'a> {
    parent: &'a File,
    leaf: &'a CString,
    file: File,
    armed: bool,
}
impl Drop for Output<'_> {
    fn drop(&mut self) {
        if self.armed && owned(self.parent, self.leaf, &self.file) {
            unsafe {
                libc::unlinkat(self.parent.as_raw_fd(), self.leaf.as_ptr(), 0);
            }
        }
    }
}
fn copy(
    source: &Path,
    destination: &Path,
    device: u64,
    inode: u64,
    active: &impl Fn() -> bool,
) -> io::Result<bool> {
    if !active() {
        return Err(failure(libc::ECANCELED));
    }
    let parent_path = destination.parent().ok_or_else(|| failure(libc::EINVAL))?;
    let name =
        CString::new(parent_path.as_os_str().as_bytes()).map_err(|_| failure(libc::EINVAL))?;
    let fd = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let parent = unsafe { File::from_raw_fd(fd) };
    let identity = parent.metadata()?;
    if identity.dev() != device || identity.ino() != inode {
        return Err(failure(libc::ESTALE));
    }
    let leaf = CString::new(
        destination
            .file_name()
            .ok_or_else(|| failure(libc::EINVAL))?
            .as_bytes(),
    )
    .map_err(|_| failure(libc::EINVAL))?;
    let mut source = match crate::files::open_metadata_file(source) {
        Ok(file) => file,
        Err(_) => return Ok(false),
    };
    let original = source.metadata()?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            leaf.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut output = Output {
        parent: &parent,
        leaf: &leaf,
        file: unsafe { File::from_raw_fd(fd) },
        armed: true,
    };
    let mut buffer = vec![0; buffer_size(original.len())];
    let mut total = 0u64;
    loop {
        if !active() {
            return Err(failure(libc::ECANCELED));
        }
        let count = match source.read(&mut buffer) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            value => value?,
        };
        if count == 0 {
            break;
        }
        output.file.write_all(&buffer[..count])?;
        total = total
            .checked_add(count as u64)
            .ok_or_else(|| failure(libc::EINVAL))?;
    }
    let current = source.metadata()?;
    if total != original.len()
        || current.len() != original.len()
        || current.mtime() != original.mtime()
        || current.mtime_nsec() != original.mtime_nsec()
    {
        return Err(failure(libc::ESTALE));
    }
    if unsafe {
        libc::fchmod(
            output.file.as_raw_fd(),
            (original.mode() & 0o777) as libc::mode_t,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if !active()
        || !owned(&parent, &leaf, &output.file)
        || !fs::symlink_metadata(parent_path)
            .is_ok_and(|meta| meta.dev() == device && meta.ino() == inode)
    {
        return Err(failure(libc::ECANCELED));
    }
    output.armed = false;
    Ok(true)
}
#[rustler::nif(schedule = "DirtyIo")]
fn file_copy_regular<'a>(
    env: Env<'a>,
    source: Binary<'a>,
    destination: Binary<'a>,
    device: u64,
    inode: u64,
) -> Term<'a> {
    let source = Path::new(std::ffi::OsStr::from_bytes(source.as_slice()));
    let destination = Path::new(std::ffi::OsStr::from_bytes(destination.as_slice()));
    let pid = env.pid();
    match copy(source, destination, device, inode, &|| pid.is_alive(env)) {
        Ok(true) => crate::ok().encode(env),
        Ok(false) => crate::fallback_git().encode(env),
        Err(error) => {
            let reason = match error.raw_os_error() {
                Some(libc::ENOENT) => enoent(),
                Some(libc::EACCES) => eacces(),
                Some(libc::EEXIST) => eexist(),
                Some(libc::ECANCELED) => ecanceled(),
                Some(libc::ESTALE) => estale(),
                Some(libc::EINVAL) => einval(),
                _ => eio(),
            };
            (crate::error(), reason).encode(env)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn buffer_policy_is_fixed_and_customer_size_cannot_increase_the_bound() {
        assert_eq!(buffer_size(0), CHUNK);
        assert_eq!(buffer_size(1024 * 1024 - 1), CHUNK);
        assert_eq!(buffer_size(1024 * 1024), CHUNK * 4);
        assert_eq!(buffer_size(u64::MAX), CHUNK * 4);
    }
    #[test]
    fn snapshots_are_independent_and_cancellation_aba_collisions_fail_closed() {
        let root = crate::test_support::TestDirectory::new();
        let source = root.join("source");
        let dest = root.join("dest");
        let meta = fs::metadata(&root).unwrap();
        let data = vec![42; CHUNK * 3 + 7];
        fs::write(&source, &data).unwrap();
        assert!(copy(&source, &dest, meta.dev(), meta.ino(), &|| true).unwrap());
        assert_ne!(
            fs::metadata(&source).unwrap().ino(),
            fs::metadata(&dest).unwrap().ino()
        );
        fs::write(&source, b"changed").unwrap();
        assert_eq!(fs::read(&dest).unwrap(), data);
        assert!(copy(&source, &dest, meta.dev(), meta.ino(), &|| true).is_err());
        assert_eq!(fs::read(&dest).unwrap(), data);
        fs::remove_file(&dest).unwrap();
        fs::write(&source, &data).unwrap();
        let calls = Cell::new(0);
        assert!(copy(&source, &dest, meta.dev(), meta.ino(), &|| {
            calls.set(calls.get() + 1);
            calls.get() < 3
        })
        .is_err());
        assert!(!dest.exists());
        assert_eq!(fs::read(&source).unwrap(), data);
        let calls = Cell::new(0);
        assert!(copy(&source, &dest, meta.dev(), meta.ino(), &|| {
            calls.set(calls.get() + 1);
            if calls.get() == 2 {
                fs::remove_file(&dest).unwrap();
                fs::write(&dest, b"foreign").unwrap();
                false
            } else {
                true
            }
        })
        .is_err());
        assert_eq!(fs::read(&dest).unwrap(), b"foreign");
        fs::remove_file(&dest).unwrap();
        let old = root.with_extension("old");
        fs::rename(&root, &old).unwrap();
        fs::create_dir(&root).unwrap();
        assert!(copy(&old.join("source"), &dest, meta.dev(), meta.ino(), &|| true).is_err());
        assert!(!dest.exists());
        fs::remove_dir_all(&root).unwrap();
        fs::remove_dir_all(&old).unwrap();
    }
}
