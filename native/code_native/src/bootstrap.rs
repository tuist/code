//! Fresh bare caches are assembled under a private, directory-fd-anchored
//! sibling and published with NOREPLACE. No writes target an existing cache.
use rustler::{Binary, Encoder, Env, Term};
use std::ffi::{CString, OsStr};
use std::fs::File;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};
fn name(bytes: &[u8]) -> Option<CString> {
    CString::new(bytes).ok()
}
fn open_dir(parent: i32, name: &CString) -> Option<File> {
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    (fd >= 0).then(|| unsafe { File::from_raw_fd(fd) })
}
fn mkdir(parent: i32, bytes: &[u8], mode: u32) -> Option<()> {
    let n = name(bytes)?;
    (unsafe { libc::mkdirat(parent, n.as_ptr(), mode as libc::mode_t) } == 0).then_some(())
}
fn write(parent: i32, bytes: &[u8], body: &[u8]) -> Option<()> {
    let n = name(bytes)?;
    let fd = unsafe {
        libc::openat(
            parent,
            n.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o666,
        )
    };
    if fd < 0 {
        return None;
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    file.write_all(body).ok()
}
fn unlink(parent: i32, bytes: &[u8], directory: bool) {
    if let Some(n) = name(bytes) {
        unsafe {
            libc::unlinkat(
                parent,
                n.as_ptr(),
                if directory { libc::AT_REMOVEDIR } else { 0 },
            );
        }
    }
}
struct Stage {
    parent: File,
    dir: File,
    name: CString,
    published: bool,
}
impl Drop for Stage {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        let fd = self.dir.as_raw_fd();
        for file in [
            b"HEAD".as_slice(),
            b"config",
            b".CoDe-Probe",
            b".code-symlink",
            "é".as_bytes(),
        ] {
            unlink(fd, file, false);
        }
        if let Some(objects) = open_dir(fd, &name(b"objects").unwrap()) {
            unlink(objects.as_raw_fd(), b"pack", true);
            unlink(objects.as_raw_fd(), b"info", true);
        }
        if let Some(refs) = open_dir(fd, &name(b"refs").unwrap()) {
            unlink(refs.as_raw_fd(), b"heads", true);
            unlink(refs.as_raw_fd(), b"tags", true);
        }
        unlink(fd, b"objects", true);
        unlink(fd, b"refs", true);
        // Never remove a different sibling that acquired this name after us.
        let mut own = unsafe { std::mem::zeroed::<libc::stat>() };
        let mut current = unsafe { std::mem::zeroed::<libc::stat>() };
        if unsafe { libc::fstat(fd, &mut own) } == 0
            && unsafe {
                libc::fstatat(
                    self.parent.as_raw_fd(),
                    self.name.as_ptr(),
                    &mut current,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0
            && own.st_dev == current.st_dev
            && own.st_ino == current.st_ino
        {
            unsafe {
                libc::unlinkat(
                    self.parent.as_raw_fd(),
                    self.name.as_ptr(),
                    libc::AT_REMOVEDIR,
                );
            }
        }
    }
}
fn exists(fd: i32, bytes: &[u8]) -> Option<bool> {
    let n = name(bytes)?;
    let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstatat(fd, n.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) } == 0 {
        return Some(true);
    }
    (std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)).then_some(false)
}
fn publish(stage: &mut Stage, target: &CString) -> Option<()> {
    let fd = stage.parent.as_raw_fd();
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            fd,
            stage.name.as_ptr(),
            fd,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            fd,
            stage.name.as_ptr(),
            fd,
            target.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let result = -1;
    if result != 0 {
        return None;
    }
    stage.published = true;
    Some(())
}
fn create(
    path: &Path,
    head: &[u8],
    config: &[u8],
    sibling: &[u8],
    active: &impl Fn() -> bool,
) -> Option<()> {
    if !active()
        || config.len() > 64 * 1024
        || head.len() > 1024
        || !head.starts_with(b"refs/heads/")
        || !head.is_ascii()
        || gix_validate::reference::name(head.into()).is_err()
        || sibling.len() > 96
        || !sibling.starts_with(b".code-init-")
        || sibling
            .iter()
            .any(|b| !b.is_ascii_alphanumeric() && *b != b'.' && *b != b'-' && *b != b'_')
    {
        return None;
    }
    let parent_name = name(path.parent()?.as_os_str().as_bytes())?;
    let parent = open_dir(libc::AT_FDCWD, &parent_name)?;
    let target = name(path.file_name()?.as_bytes())?;
    if exists(parent.as_raw_fd(), target.as_bytes())? {
        return None;
    }
    mkdir(parent.as_raw_fd(), sibling, 0o700)?;
    let sibling = name(sibling)?;
    let dir = open_dir(parent.as_raw_fd(), &sibling)?;
    let mut stage = Stage {
        parent,
        dir,
        name: sibling,
        published: false,
    };
    let fd = stage.dir.as_raw_fd();
    // Probe only the private stage through its fd. A path-based capability
    // probe could write into a replacement cache after caller cancellation.
    write(fd, b".CoDe-Probe", b"")?;
    let probe = name(b".CoDe-Probe")?;
    let raw = unsafe {
        libc::openat(
            fd,
            probe.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        return None;
    }
    let probe_file = unsafe { File::from_raw_fd(raw) };
    let chmod = unsafe { libc::fchmod(probe_file.as_raw_fd(), 0o755) } == 0;
    let executable = chmod && probe_file.metadata().ok()?.permissions().mode() & 0o111 == 0o111;
    let ignore_case = exists(fd, b".code-probe")?;
    unlink(fd, b".CoDe-Probe", false);
    let symlink_name = name(b".code-symlink")?;
    let symlink_ok = unsafe { libc::symlinkat(target.as_ptr(), fd, symlink_name.as_ptr()) } == 0;
    unlink(fd, b".code-symlink", false);
    write(fd, "é".as_bytes(), b"")?;
    let precompose = exists(fd, "e\u{301}".as_bytes())?;
    unlink(fd, "é".as_bytes(), false);
    for directory in [b"objects".as_slice(), b"refs"] {
        mkdir(fd, directory, 0o777)?;
    }
    let objects = open_dir(fd, &name(b"objects")?)?;
    let refs = open_dir(fd, &name(b"refs")?)?;
    for directory in [b"info".as_slice(), b"pack"] {
        mkdir(objects.as_raw_fd(), directory, 0o777)?;
    }
    for directory in [b"heads".as_slice(), b"tags"] {
        mkdir(refs.as_raw_fd(), directory, 0o777)?;
    }
    let mut content = format!("[core]\n repositoryformatversion = 0\n bare = true\n filemode = {}\n ignorecase = {}\n symlinks = {}\n",executable,ignore_case,symlink_ok).into_bytes();
    #[cfg(target_os = "macos")]
    content.extend_from_slice(format!(" precomposeunicode = {}\n", precompose).as_bytes());
    #[cfg(not(target_os = "macos"))]
    let _ = precompose;
    content.extend_from_slice(config);
    write(fd, b"config", &content)?;
    let mut value = b"ref: ".to_vec();
    value.extend_from_slice(head);
    value.push(b'\n');
    write(fd, b"HEAD", &value)?;
    if !active() {
        return None;
    }
    // Match Git's directory permission policy without consulting/changing the
    // process-global umask. The parent's freshly created objects dir carries it.
    let mode = objects.metadata().ok()?.permissions().mode() & 0o777;
    if unsafe { libc::fchmod(fd, mode as libc::mode_t) } != 0 || !active() {
        return None;
    }
    publish(&mut stage, &target)
}
use std::os::unix::fs::PermissionsExt;
#[rustler::nif(schedule = "DirtyIo")]
fn fresh_bare<'a>(
    env: Env<'a>,
    path: Binary<'a>,
    head: Binary<'a>,
    config: Binary<'a>,
    sibling: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment()
        || ["GIT_DEFAULT_HASH", "GIT_DEFAULT_REF_FORMAT"]
            .iter()
            .any(|key| std::env::var_os(key).is_some())
    {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let active = || start.elapsed() < limit && pid.is_alive(env);
    let path = Path::new(OsStr::from_bytes(path.as_slice()));
    // After publication there are no further writes or path-based cleanup,
    // even if the caller dies or the cache is deleted/recreated before return.
    match create(
        path,
        head.as_slice(),
        config.as_slice(),
        sibling.as_slice(),
        &active,
    ) {
        Some(()) => crate::ok().encode(env),
        None => crate::fallback_git().encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    fn root() -> crate::test_support::TestDirectory {
        crate::test_support::TestDirectory::new()
    }
    #[test]
    fn existing_and_cancelled_targets_are_untouched() {
        let root = root();
        let target = root.join("repo");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("HEAD"), b"winner").unwrap();
        assert!(create(
            &target,
            b"refs/heads/main",
            b"",
            b".code-init-existing",
            &|| true
        )
        .is_none());
        assert_eq!(fs::read(target.join("HEAD")).unwrap(), b"winner");
        let calls = AtomicUsize::new(0);
        assert!(create(
            &root.join("cancelled"),
            b"refs/heads/main",
            b"",
            b".code-init-cancelled",
            &|| calls.fetch_add(1, Ordering::Relaxed) == 0
        )
        .is_none());
        assert!(!root.join("cancelled").exists());
        assert!(!root.join(".code-init-cancelled").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn no_replace_refuses_a_winner_created_during_staging() {
        let root = root();
        let target = root.join("repo");
        let calls = AtomicUsize::new(0);
        let active = || {
            if calls.fetch_add(1, Ordering::Relaxed) == 1 {
                fs::create_dir(&target).unwrap();
                fs::write(target.join("HEAD"), b"new replica").unwrap();
            }
            true
        };
        assert!(create(
            &target,
            b"refs/heads/main",
            b"",
            b".code-init-race",
            &active
        )
        .is_none());
        assert_eq!(fs::read(target.join("HEAD")).unwrap(), b"new replica");
        assert!(!root.join(".code-init-race").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn parent_directory_aba_never_writes_the_replacement() {
        let root = root();
        let parent = root.join("parent");
        fs::create_dir(&parent).unwrap();
        let target = parent.join("repo");
        let calls = AtomicUsize::new(0);
        let active = || {
            if calls.fetch_add(1, Ordering::Relaxed) == 1 {
                fs::rename(&parent, root.join("old")).unwrap();
                fs::create_dir(&parent).unwrap();
                fs::create_dir(&target).unwrap();
                fs::write(target.join("HEAD"), b"replacement").unwrap();
            }
            true
        };
        assert!(create(&target, b"refs/heads/main", b"", b".code-init-aba", &active).is_some());
        assert_eq!(fs::read(target.join("HEAD")).unwrap(), b"replacement");
        assert_eq!(
            fs::read(root.join("old/repo/HEAD")).unwrap(),
            b"ref: refs/heads/main\n"
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn published_stage_cleanup_is_disarmed() {
        let root = root();
        fs::create_dir(root.join(".code-init-owned")).unwrap();
        let parent = File::open(&root).unwrap();
        let dir = File::open(root.join(".code-init-owned")).unwrap();
        let mut stage = Stage {
            parent,
            dir,
            name: name(b".code-init-owned").unwrap(),
            published: false,
        };
        publish(&mut stage, &name(b"repo").unwrap()).unwrap();
        fs::create_dir(root.join(".code-init-owned")).unwrap();
        fs::write(root.join(".code-init-owned/HEAD"), b"another owner").unwrap();
        drop(stage);
        assert_eq!(
            fs::read(root.join(".code-init-owned/HEAD")).unwrap(),
            b"another owner"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
