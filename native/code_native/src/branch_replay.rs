//! First HEAD branch publication only, including both initial reflogs.
//! Existing logs, other refs/targets, hooks and uncertainty stay on Git.
use crate::replay::{c, dir, read_ref, same_dir, same_root, Lock, Replay, Work};
use rustler::{Binary, Encoder, Env, ResourceArc, Term};
use std::ffi::CString;
use std::fs::{self, File};
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, Instant};
fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
}
fn mkdir(fd: i32, name: &[u8], mode: u32) -> Option<()> {
    let name = c(name)?;
    (unsafe { libc::mkdirat(fd, name.as_ptr(), mode as libc::mode_t) } == 0).then_some(())
}
fn write(fd: i32, name: &[u8], data: &[u8]) -> Option<()> {
    let name = c(name)?;
    let raw = unsafe {
        libc::openat(
            fd,
            name.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o666,
        )
    };
    if raw < 0 {
        return None;
    }
    let mut file = unsafe { File::from_raw_fd(raw) };
    file.write_all(data).ok()
}
fn unlink(fd: i32, name: &[u8], directory: bool) {
    if let Some(name) = c(name) {
        unsafe {
            libc::unlinkat(
                fd,
                name.as_ptr(),
                if directory { libc::AT_REMOVEDIR } else { 0 },
            );
        }
    }
}
struct Logs {
    root: File,
    dir: File,
    name: CString,
    branch: Vec<u8>,
    published: bool,
}
impl Drop for Logs {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        let fd = self.dir.as_raw_fd();
        unlink(fd, b"HEAD", false);
        if let Some(refs) = dir(fd, &c(b"refs").unwrap(), false) {
            if let Some(heads) = dir(refs.as_raw_fd(), &c(b"heads").unwrap(), false) {
                unlink(heads.as_raw_fd(), &self.branch, false);
            }
            unlink(refs.as_raw_fd(), b"heads", true);
        }
        unlink(fd, b"refs", true);
        let mut current = unsafe { std::mem::zeroed::<libc::stat>() };
        if let Ok(own) = self.dir.metadata() {
            if unsafe {
                libc::fstatat(
                    self.root.as_raw_fd(),
                    self.name.as_ptr(),
                    &mut current,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0
                && own.dev() == current.st_dev as u64
                && own.ino() == current.st_ino as u64
            {
                unsafe {
                    libc::unlinkat(
                        self.root.as_raw_fd(),
                        self.name.as_ptr(),
                        libc::AT_REMOVEDIR,
                    );
                }
            }
        }
    }
}
fn rename(fd: i32, source: &CString, target: &CString) -> bool {
    #[cfg(target_os = "linux")]
    let status = unsafe {
        libc::renameat2(
            fd,
            source.as_ptr(),
            fd,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let status =
        unsafe { libc::renameatx_np(fd, source.as_ptr(), fd, target.as_ptr(), libc::RENAME_EXCL) };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let status = -1;
    status == 0
}
fn identity(value: &[u8]) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value.is_ascii()
        && value.first().is_some_and(|b| !b.is_ascii_whitespace())
        && value.last().is_some_and(|b| !b.is_ascii_whitespace())
        && !value
            .iter()
            .any(|b| b.is_ascii_control() || matches!(*b, b'<' | b'>'))
}
fn zone(value: &[u8]) -> bool {
    value.len() == 5
        && matches!(value[0], b'+' | b'-')
        && value[1..].iter().all(u8::is_ascii_digit)
        && value != b"-0000"
        && std::str::from_utf8(&value[1..3])
            .ok()
            .and_then(|s| s.parse::<u8>().ok())
            .is_some_and(|hours| hours <= 23)
        && std::str::from_utf8(&value[3..])
            .ok()
            .and_then(|s| s.parse::<u8>().ok())
            .is_some_and(|minutes| minutes <= 59)
}
fn publish(
    repo: &Path,
    root: &File,
    reference: &[u8],
    new: &[u8],
    name: &[u8],
    email: &[u8],
    seconds: u64,
    timezone: &[u8],
    stage: &[u8],
    active: &impl Fn() -> bool,
) -> Option<Result<(), ()>> {
    if !active()
        || !crate::refs::supported_environment()
        || std::env::var_os("GIT_COMMITTER_DATE").is_some()
        || std::env::var_os("GIT_REFLOG_ACTION").is_some()
        || !identity(name)
        || !identity(email)
        || seconds > i64::MAX as u64
        || !zone(timezone)
        || !absent(&repo.join("logs"))
        || !absent(&repo.join("hooks/reference-transaction"))
    {
        return None;
    }
    let branch = reference.strip_prefix(b"refs/heads/")?;
    if branch.is_empty()
        || branch.len() > 200
        || !branch.is_ascii()
        || branch.contains(&b'/')
        || gix_validate::reference::name(reference.into()).is_err()
    {
        return None;
    }
    if new.len() != 40
        || !new
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        || stage.len() > 96
        || !stage.starts_with(b".code-reflog-")
        || stage
            .iter()
            .any(|b| !b.is_ascii_alphanumeric() && !matches!(*b, b'.' | b'-' | b'_'))
    {
        return None;
    }
    crate::refs::eligible(repo)?;
    let config = crate::config::plain_config(&repo.join("config")).ok()??;
    let values = config
        .raw_values_by("core", None, "logallrefupdates")
        .ok()?;
    if values.len() != 1 {
        return None;
    }
    let value: &[u8] = values[0].as_ref();
    if value != b"true" {
        return None;
    }
    for key in [
        "hookspath",
        "fsync",
        "fsyncmethod",
        "sharedrepository",
        "worktree",
    ] {
        if config.raw_values_by("core", None, key).is_ok() {
            return None;
        }
    }
    if crate::resolve::resolve(repo, new, active)?.as_bytes() != new {
        return None;
    }
    let refs = dir(root.as_raw_fd(), &c(b"refs")?, false)?;
    let heads = dir(refs.as_raw_fd(), &c(b"heads")?, false)?;
    let mut lock_name = branch.to_vec();
    lock_name.extend_from_slice(b".lock");
    let mut branch_lock = Lock::new(&heads, &lock_name)?;
    let _head_lock = Lock::new(root, b"HEAD.lock")?;
    let mut expected = b"ref: ".to_vec();
    expected.extend_from_slice(reference);
    expected.push(b'\n');
    if read_ref(root.as_raw_fd(), b"HEAD")?.as_deref() != Some(expected.as_slice())
        || read_ref(heads.as_raw_fd(), branch)?.is_some()
    {
        return None;
    }
    let branch_target = c(branch)?;
    let logs_target = c(b"logs")?;
    branch_lock.file.write_all(new).ok()?;
    branch_lock.file.write_all(b"\n").ok()?;
    mkdir(root.as_raw_fd(), stage, 0o700)?;
    let stage = c(stage)?;
    let stage_dir = dir(root.as_raw_fd(), &stage, false)?;
    let mut logs = Logs {
        root: root.try_clone().ok()?,
        dir: stage_dir,
        name: stage,
        branch: branch.to_vec(),
        published: false,
    };
    mkdir(logs.dir.as_raw_fd(), b"refs", 0o777)?;
    let log_refs = dir(logs.dir.as_raw_fd(), &c(b"refs")?, false)?;
    mkdir(log_refs.as_raw_fd(), b"heads", 0o777)?;
    let log_heads = dir(log_refs.as_raw_fd(), &c(b"heads")?, false)?;
    let mut line = b"0000000000000000000000000000000000000000 ".to_vec();
    line.extend_from_slice(new);
    line.push(b' ');
    line.extend_from_slice(name);
    line.extend_from_slice(b" <");
    line.extend_from_slice(email);
    line.extend_from_slice(format!("> {seconds} ").as_bytes());
    line.extend_from_slice(timezone);
    // Git omits the message delimiter entirely for an empty update-ref message.
    line.push(b'\n');
    write(logs.dir.as_raw_fd(), b"HEAD", &line)?;
    write(log_heads.as_raw_fd(), branch, &line)?;
    let mode = log_refs.metadata().ok()?.permissions().mode() & 0o777;
    if unsafe { libc::fchmod(logs.dir.as_raw_fd(), mode as libc::mode_t) } != 0 {
        return None;
    }
    if !active() {
        return None;
    }
    let (Ok(owned), Ok(current)) = (root.metadata(), fs::metadata(repo)) else {
        return Some(Err(()));
    };
    if owned.dev() != current.dev()
        || owned.ino() != current.ino()
        || !same_dir(&refs, root, b"refs")
        || !same_dir(&heads, &refs, b"heads")
    {
        return Some(Err(()));
    }
    if !rename(root.as_raw_fd(), &logs.name, &logs_target) {
        return None;
    }
    logs.published = true;
    if !active() || !rename(heads.as_raw_fd(), &branch_lock.name, &branch_target) {
        return Some(Err(()));
    }
    branch_lock.disarmed = true;
    let (Ok(owned), Ok(current)) = (root.metadata(), fs::metadata(repo)) else {
        return Some(Err(()));
    };
    if owned.dev() != current.dev()
        || owned.ino() != current.ino()
        || !same_dir(&refs, root, b"refs")
        || !same_dir(&heads, &refs, b"heads")
        || !same_dir(&logs.dir, root, b"logs")
        || !same_dir(&log_refs, &logs.dir, b"refs")
        || !same_dir(&log_heads, &log_refs, b"heads")
    {
        return Some(Err(()));
    }
    Some(Ok(()))
}
#[rustler::nif(schedule = "DirtyIo")]
fn local_git_date<'a>(env: Env<'a>) -> Term<'a> {
    unsafe extern "C" {
        fn tzset();
    }
    unsafe {
        tzset();
    }
    let seconds = unsafe { libc::time(std::ptr::null_mut()) };
    if seconds < 0 {
        return crate::fallback_git().encode(env);
    }
    let mut local = unsafe { std::mem::zeroed::<libc::tm>() };
    if unsafe { libc::localtime_r(&seconds, &mut local) }.is_null() {
        return crate::fallback_git().encode(env);
    }
    let offset = local.tm_gmtoff;
    if offset % 60 != 0 || offset.abs() > 23 * 3600 + 59 * 60 {
        return crate::fallback_git().encode(env);
    }
    let minutes = offset.abs() / 60;
    let timezone = format!(
        "{}{:02}{:02}",
        if offset < 0 { '-' } else { '+' },
        minutes / 60,
        minutes % 60
    );
    (crate::ok(), seconds as u64, timezone).encode(env)
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_branch<'a>(
    env: Env<'a>,
    gate: ResourceArc<Replay>,
    updates: Term<'a>,
    name: Binary<'a>,
    email: Binary<'a>,
    seconds: u64,
    timezone: Binary<'a>,
    stage: Binary<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let active = || start.elapsed() < limit && pid.is_alive(env);
    let result = (|| {
        let mut values = updates.decode::<rustler::ListIterator>().ok()?;
        let (reference, old, new): (Binary<'_>, Binary<'_>, Binary<'_>) =
            values.next()?.decode().ok()?;
        if values.next().is_some() || old.as_slice() != b"0000000000000000000000000000000000000000"
        {
            return None;
        }
        let Some(work) = Work::begin(gate) else {
            return Some(Err(()));
        };
        if !same_root(work.root(), work.repo()) {
            return Some(Err(()));
        }
        let result = publish(
            work.repo(),
            work.root(),
            reference.as_slice(),
            new.as_slice(),
            name.as_slice(),
            email.as_slice(),
            seconds,
            timezone.as_slice(),
            stage.as_slice(),
            &active,
        );
        if !same_root(work.root(), work.repo()) {
            Some(Err(()))
        } else {
            result
        }
    })();
    match result {
        Some(Ok(())) => crate::ok().encode(env),
        Some(Err(())) => crate::error().encode(env),
        None => if start.elapsed() >= limit {
            crate::timeout()
        } else {
            crate::fallback_git()
        }
        .encode(env),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::replay::tests::{fixture, root};
    use std::sync::atomic::{AtomicBool, Ordering};
    #[test]
    fn cancellation_after_logs_never_reports_success_or_removes_published_cache_metadata() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        let active = || !repo.join("logs").exists();
        assert!(matches!(
            publish(
                &repo,
                &fd,
                b"refs/heads/main",
                &oid,
                b"Code",
                b"code@localhost",
                946684800,
                b"+0000",
                b".code-reflog-cancel",
                &active
            ),
            Some(Err(()))
        ));
        assert!(repo.join("logs/HEAD").exists());
        assert!(!repo.join("refs/heads/main").exists());
        assert!(!repo.join("refs/heads/main.lock").exists());
        assert!(!repo.join("HEAD.lock").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn replacement_after_log_publication_is_never_overwritten_or_cleaned() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        let swapped = AtomicBool::new(false);
        let active = || {
            if repo.join("logs").exists() && !swapped.swap(true, Ordering::Relaxed) {
                fs::rename(&repo, root.join("old")).unwrap();
                fixture(&repo);
                fs::create_dir(repo.join("logs")).unwrap();
                for name in [
                    "HEAD",
                    "HEAD.lock",
                    "refs/heads/main",
                    "refs/heads/main.lock",
                    "logs/HEAD",
                ] {
                    fs::write(repo.join(name), b"replacement owner").unwrap();
                }
            }
            true
        };
        assert!(matches!(
            publish(
                &repo,
                &fd,
                b"refs/heads/main",
                &oid,
                b"Code",
                b"code@localhost",
                946684800,
                b"+0000",
                b".code-reflog-aba",
                &active
            ),
            Some(Err(()))
        ));
        for name in [
            "HEAD",
            "HEAD.lock",
            "refs/heads/main",
            "refs/heads/main.lock",
            "logs/HEAD",
        ] {
            assert_eq!(fs::read(repo.join(name)).unwrap(), b"replacement owner");
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn detached_heads_cannot_report_success_or_clean_replacement_locks() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        let swapped = AtomicBool::new(false);
        let active = || {
            if repo.join("logs").exists() && !swapped.swap(true, Ordering::Relaxed) {
                fs::rename(repo.join("refs/heads"), repo.join("refs/old-heads")).unwrap();
                fs::create_dir(repo.join("refs/heads")).unwrap();
                for name in ["main", "main.lock"] {
                    fs::write(repo.join("refs/heads").join(name), b"replacement owner").unwrap();
                }
            }
            true
        };
        assert!(matches!(
            publish(
                &repo,
                &fd,
                b"refs/heads/main",
                &oid,
                b"Code",
                b"code@localhost",
                946684800,
                b"+0000",
                b".code-reflog-detached",
                &active
            ),
            Some(Err(()))
        ));
        for name in ["main", "main.lock"] {
            assert_eq!(
                fs::read(repo.join("refs/heads").join(name)).unwrap(),
                b"replacement owner"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn identity_and_offsets_are_conservative() {
        assert!(identity(b"Code"));
        assert!(!identity(b" Code "));
        assert!(!identity(b"bad<name"));
        assert!(zone(b"+0530"));
        assert!(zone(b"-0700"));
        assert!(!zone(b"-0000"));
        assert!(!zone(b"+2460"));
    }
}
