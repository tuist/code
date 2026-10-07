//! Local replay coordination only. The WAL remains authoritative.
//! Successor convergence waits for outstanding dirty-I/O callbacks even after
//! their caller dies. Ingest and ordinary update-ref operations do not use this
//! optimization; unsupported replay retains the original supervised Git path.
use rustler::{Binary, Encoder, Env, ResourceArc, Term};
use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};
struct Gate {
    busy: Mutex<bool>,
}
#[derive(Default)]
struct State {
    released: bool,
    work: usize,
    unlocked: bool,
}
pub struct Replay {
    gate: Arc<Gate>,
    state: Mutex<State>,
    root: Mutex<Option<File>>,
    path: PathBuf,
}
#[rustler::resource_impl]
impl rustler::Resource for Replay {}
impl Replay {
    fn unlock(&self, state: &mut State) {
        if state.released && state.work == 0 && !state.unlocked {
            state.unlocked = true;
            self.root.lock().unwrap_or_else(|p| p.into_inner()).take();
            *self.gate.busy.lock().unwrap_or_else(|p| p.into_inner()) = false;
        }
    }
    fn release(&self) {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        state.released = true;
        self.unlock(&mut state);
    }
}
impl Drop for Replay {
    fn drop(&mut self) {
        self.release();
    }
}
pub struct Work {
    owner: ResourceArc<Replay>,
    file: File,
}
impl Work {
    pub(crate) fn begin(owner: ResourceArc<Replay>) -> Option<Self> {
        {
            let mut state = owner.state.lock().unwrap_or_else(|p| p.into_inner());
            if state.released || state.work >= 64 {
                return None;
            }
            state.work += 1;
        }
        let file = owner
            .root
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            .and_then(|file| file.try_clone().ok());
        match file {
            Some(file) => Some(Self { owner, file }),
            None => {
                let mut state = owner.state.lock().unwrap_or_else(|p| p.into_inner());
                state.work -= 1;
                owner.unlock(&mut state);
                None
            }
        }
    }
}
impl Work {
    pub(crate) fn repo(&self) -> &Path {
        &self.owner.path
    }
    pub(crate) fn root(&self) -> &File {
        &self.file
    }
}
impl Drop for Work {
    fn drop(&mut self) {
        let mut state = self.owner.state.lock().unwrap_or_else(|p| p.into_inner());
        state.work -= 1;
        self.owner.unlock(&mut state);
    }
}
// A lease is useful to pin replay coordination across asynchronous work. Its
// explicit close makes lifetime independent of the Erlang caller's next GC.
pub struct Lease(Mutex<Option<Work>>);
#[rustler::resource_impl]
impl rustler::Resource for Lease {}
type Key = (u64, u64);
fn registry() -> &'static Mutex<HashMap<Key, Weak<Gate>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<Key, Weak<Gate>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}
pub(crate) fn c(bytes: &[u8]) -> Option<CString> {
    CString::new(bytes).ok()
}
pub(crate) fn dir(parent: i32, name: &CString, follow: bool) -> Option<File> {
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_DIRECTORY
                | libc::O_CLOEXEC
                | if follow { 0 } else { libc::O_NOFOLLOW },
        )
    };
    (fd >= 0).then(|| unsafe { File::from_raw_fd(fd) })
}
enum Acquire {
    Busy,
    Unavailable,
    Timeout,
}
fn acquire(path: &Path, active: &impl Fn() -> bool) -> Result<Replay, Acquire> {
    if !active() {
        return Err(Acquire::Timeout);
    }
    // Follow the root only so aliases coordinate by physical inode. All
    // mutation descendants are O_NOFOLLOW, directory-fd-anchored.
    let name = c(path.as_os_str().as_bytes()).ok_or(Acquire::Unavailable)?;
    let root = dir(libc::AT_FDCWD, &name, true).ok_or(Acquire::Unavailable)?;
    let meta = root.metadata().map_err(|_| Acquire::Unavailable)?;
    let key = (meta.dev(), meta.ino());
    let gate = {
        let mut map = registry().lock().unwrap_or_else(|p| p.into_inner());
        map.retain(|_, weak| weak.strong_count() > 0);
        if let Some(gate) = map.get(&key).and_then(Weak::upgrade) {
            gate
        } else {
            if map.len() >= 4096 {
                return Err(Acquire::Unavailable);
            }
            let gate = Arc::new(Gate {
                busy: Mutex::new(false),
            });
            map.insert(key, Arc::downgrade(&gate));
            gate
        }
    };
    let mut busy = gate.busy.lock().unwrap_or_else(|p| p.into_inner());
    // Never occupy a dirty-I/O scheduler while waiting for another callback:
    // its queued mutation might otherwise be starved by waiting successors.
    if *busy {
        return Err(Acquire::Busy);
    }
    if !active() {
        return Err(Acquire::Timeout);
    }
    *busy = true;
    drop(busy);
    Ok(Replay {
        gate,
        state: Mutex::new(State::default()),
        root: Mutex::new(Some(root)),
        path: path.to_path_buf(),
    })
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_gate<'a>(env: Env<'a>, path: Binary<'a>, timeout_ms: u64) -> Term<'a> {
    if path.len() > 4096 {
        return crate::timeout().encode(env);
    }
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let result = acquire(
        Path::new(std::ffi::OsStr::from_bytes(path.as_slice())),
        &|| start.elapsed() < limit && pid.is_alive(env),
    );
    match result {
        Ok(gate) => (crate::ok(), ResourceArc::new(gate)).encode(env),
        Err(Acquire::Busy) => crate::busy().encode(env),
        Err(Acquire::Timeout) => crate::timeout().encode(env),
        Err(Acquire::Unavailable) => crate::error().encode(env),
    }
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_release(gate: ResourceArc<Replay>) -> rustler::Atom {
    gate.release();
    crate::ok()
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_lease<'a>(env: Env<'a>, gate: ResourceArc<Replay>) -> Term<'a> {
    match Work::begin(gate) {
        Some(work) => (crate::ok(), ResourceArc::new(Lease(Mutex::new(Some(work))))).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_lease_release(lease: ResourceArc<Lease>) -> rustler::Atom {
    lease.0.lock().unwrap_or_else(|p| p.into_inner()).take();
    crate::ok()
}
fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
}
// Descriptor anchoring also needs a final path-chain identity check: replacing
// only refs/tags or refs/heads must not let sync report detached writes as live.
pub(crate) fn same_dir(owned: &File, parent: &File, name: &[u8]) -> bool {
    let Some(name) = c(name) else {
        return false;
    };
    let Some(current) = dir(parent.as_raw_fd(), &name, false) else {
        return false;
    };
    let (Ok(a), Ok(b)) = (owned.metadata(), current.metadata()) else {
        return false;
    };
    a.dev() == b.dev() && a.ino() == b.ino()
}

pub(crate) fn same_root(root: &File, path: &Path) -> bool {
    let (Ok(owned), Ok(current)) = (root.metadata(), fs::metadata(path)) else {
        return false;
    };
    owned.dev() == current.dev() && owned.ino() == current.ino()
}

pub(crate) struct Lock {
    parent: File,
    pub(crate) file: File,
    pub(crate) name: CString,
    pub(crate) disarmed: bool,
}
impl Lock {
    pub(crate) fn new(parent: &File, name: &[u8]) -> Option<Self> {
        let name = c(name)?;
        let parent = parent.try_clone().ok()?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o666,
            )
        };
        (fd >= 0).then(|| Self {
            parent,
            file: unsafe { File::from_raw_fd(fd) },
            name,
            disarmed: false,
        })
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        if self.disarmed {
            return;
        }
        let mut current = unsafe { std::mem::zeroed::<libc::stat>() };
        if let Ok(owned) = self.file.metadata() {
            if unsafe {
                libc::fstatat(
                    self.parent.as_raw_fd(),
                    self.name.as_ptr(),
                    &mut current,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0
                && owned.dev() == current.st_dev as u64
                && owned.ino() == current.st_ino as u64
            {
                unsafe {
                    libc::unlinkat(self.parent.as_raw_fd(), self.name.as_ptr(), 0);
                }
            }
        }
    }
}
pub(crate) fn read_ref(fd: i32, name: &[u8]) -> Option<Option<Vec<u8>>> {
    let name = c(name)?;
    let raw = unsafe {
        libc::openat(
            fd,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        return (std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT))
            .then_some(None);
    }
    let mut file = unsafe { File::from_raw_fd(raw) };
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > 128 {
        return None;
    }
    let mut bytes = [0u8; 129];
    let count = metadata.len() as usize;
    file.read_exact(&mut bytes[..count]).ok()?;
    if file.read(&mut bytes[count..count + 1]).ok()? != 0 {
        return None;
    }
    Some(Some(bytes[..count].to_vec()))
}
struct Command {
    name: Vec<u8>,
    old: Vec<u8>,
    new: Vec<u8>,
}
fn commands(term: Term<'_>) -> Option<Vec<Command>> {
    let mut result = Vec::new();
    for value in term.decode::<rustler::ListIterator>().ok()? {
        if result.len() >= 2 {
            return None;
        }
        let (name, old, new): (Binary<'_>, Binary<'_>, Binary<'_>) = value.decode().ok()?;
        let name = name.as_slice();
        let leaf = name.strip_prefix(b"refs/tags/")?;
        if leaf.is_empty()
            || leaf.len() > 200
            || !leaf.is_ascii()
            || leaf.contains(&b'/')
            || gix_validate::reference::name(name.into()).is_err()
        {
            return None;
        }
        if ![old.as_slice(), new.as_slice()].iter().all(|oid| {
            oid.len() == 40
                && oid
                    .iter()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        }) {
            return None;
        }
        result.push(Command {
            name: leaf.to_vec(),
            old: old.as_slice().to_vec(),
            new: new.as_slice().to_vec(),
        });
    }
    if result.is_empty() {
        return None;
    }
    result.sort_by(|a, b| a.name.cmp(&b.name));
    if result.len() == 2 && result[0].name == result[1].name {
        return None;
    }
    Some(result)
}
// None: no change, retain Git. Err: publication started, fail closed so the
// cached WAL position cannot advance. Replay will converge on the next read.
fn tags(
    repo: &Path,
    root: &File,
    commands: &[Command],
    active: &impl Fn() -> bool,
) -> Option<Result<(), ()>> {
    if !active() || !crate::refs::supported_environment() {
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
    let actual: &[u8] = values[0].as_ref();
    if actual != b"true" {
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
    if !absent(&repo.join("hooks/reference-transaction")) {
        return None;
    }
    let refs = dir(root.as_raw_fd(), &c(b"refs")?, false)?;
    let tags = dir(refs.as_raw_fd(), &c(b"tags")?, false)?;
    let zero = b"0000000000000000000000000000000000000000";
    for command in commands {
        if !absent(
            &repo
                .join("logs/refs/tags")
                .join(std::ffi::OsStr::from_bytes(&command.name)),
        ) {
            return None;
        }
        if command.new != zero && command.old != zero {
            return None;
        }
        if command.new != zero {
            if crate::resolve::resolve(repo, &command.new, active)?.as_bytes() != command.new {
                return None;
            }
        }
    }
    let mut locks = Vec::new();
    for command in commands {
        let mut name = command.name.clone();
        name.extend_from_slice(b".lock");
        locks.push(Lock::new(&tags, &name)?);
    }
    for (command, lock) in commands.iter().zip(locks.iter_mut()) {
        let current = read_ref(tags.as_raw_fd(), &command.name)?;
        if command.new == zero {
            let mut expected = command.old.clone();
            expected.push(b'\n');
            if current.as_deref() != Some(expected.as_slice()) {
                return None;
            }
        } else {
            if current.is_some() {
                return None;
            }
            lock.file.write_all(&command.new).ok()?;
            lock.file.write_all(b"\n").ok()?;
        }
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
        || !same_dir(&tags, &refs, b"tags")
    {
        return Some(Err(()));
    }
    let order: Vec<usize> = (0..commands.len())
        .filter(|n| commands[*n].new != zero)
        .chain((0..commands.len()).filter(|n| commands[*n].new == zero))
        .collect();
    let mut published = false;
    for n in order {
        let command = &commands[n];
        let lock = &mut locks[n];
        if !active() {
            return Some(Err(()));
        }
        let Some(target) = c(&command.name) else {
            return Some(Err(()));
        };
        let status = if command.new == zero {
            unsafe { libc::unlinkat(tags.as_raw_fd(), target.as_ptr(), 0) }
        } else {
            // Git's ref lock excludes cooperating writers; no replacement of
            // an unexpectedly created target is ever allowed.
            #[cfg(target_os = "linux")]
            let result = unsafe {
                libc::renameat2(
                    tags.as_raw_fd(),
                    lock.name.as_ptr(),
                    tags.as_raw_fd(),
                    target.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(target_os = "macos")]
            let result = unsafe {
                libc::renameatx_np(
                    tags.as_raw_fd(),
                    lock.name.as_ptr(),
                    tags.as_raw_fd(),
                    target.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(not(any(target_os = "linux", target_os = "macos")))]
            let result = -1;
            if result == 0 {
                lock.disarmed = true;
            }
            result
        };
        if status != 0 {
            return if published { Some(Err(())) } else { None };
        }
        published = true;
    }
    let (Ok(owned), Ok(current)) = (root.metadata(), fs::metadata(repo)) else {
        return Some(Err(()));
    };
    if owned.dev() != current.dev()
        || owned.ino() != current.ino()
        || !same_dir(&refs, root, b"refs")
        || !same_dir(&tags, &refs, b"tags")
    {
        return Some(Err(()));
    }
    Some(Ok(()))
}
#[rustler::nif(schedule = "DirtyIo")]
fn replay_tags<'a>(
    env: Env<'a>,
    gate: ResourceArc<Replay>,
    updates: Term<'a>,
    timeout_ms: u64,
) -> Term<'a> {
    let start = Instant::now();
    let limit = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let active = || start.elapsed() < limit && pid.is_alive(env);
    let result = commands(updates).and_then(|commands| {
        let Some(work) = Work::begin(gate) else {
            return Some(Err(()));
        };
        if !same_root(&work.file, &work.owner.path) {
            return Some(Err(()));
        }
        let result = tags(&work.owner.path, &work.file, &commands, &active);
        if !same_root(&work.file, &work.owner.path) {
            Some(Err(()))
        } else {
            result
        }
    });
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
pub(crate) mod tests {
    use super::*;
    use flate2::write::ZlibEncoder;
    use sha1_checked::{Digest, Sha1};
    use std::sync::atomic::{AtomicBool, Ordering};
    pub(crate) fn fixture(repo: &Path) -> Vec<u8> {
        fs::create_dir_all(repo.join("objects/pack")).unwrap();
        fs::create_dir_all(repo.join("refs/tags")).unwrap();
        fs::create_dir_all(repo.join("refs/heads")).unwrap();
        fs::write(
            repo.join("config"),
            b"[core]\n bare = true\n repositoryformatversion = 0\n logallrefupdates = true\n",
        )
        .unwrap();
        fs::write(repo.join("HEAD"), b"ref: refs/heads/main\n").unwrap();
        let body=b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor Test <test@example.com> 946684800 +0000\ncommitter Test <test@example.com> 946684800 +0000\n\nreplay fixture\n";
        let mut data = format!("commit {}\0", body.len()).into_bytes();
        data.extend_from_slice(body);
        let mut hash = Sha1::new();
        hash.update(&data);
        let digest = hash.try_finalize();
        let bytes: &[u8] = digest.hash().as_ref();
        let oid = gix_hash::ObjectId::from_bytes_or_panic(bytes)
            .to_hex()
            .to_string();
        let folder = repo.join("objects").join(&oid[..2]);
        fs::create_dir_all(&folder).unwrap();
        let mut encoder = ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&data).unwrap();
        fs::write(folder.join(&oid[2..]), encoder.finish().unwrap()).unwrap();
        oid.into_bytes()
    }
    pub(crate) fn root() -> crate::test_support::TestDirectory {
        crate::test_support::TestDirectory::new()
    }
    fn batch(oid: &[u8]) -> Vec<Command> {
        vec![
            Command {
                name: b"v1".to_vec(),
                old: oid.to_vec(),
                new: vec![b'0'; 40],
            },
            Command {
                name: b"v2".to_vec(),
                old: vec![b'0'; 40],
                new: oid.to_vec(),
            },
        ]
    }
    #[test]
    fn tag_locks_are_owned_and_existing_locks_are_never_removed() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        fs::write(
            repo.join("refs/tags/v1"),
            [oid.clone(), vec![b'\n']].concat(),
        )
        .unwrap();
        fs::write(repo.join("refs/tags/v2.lock"), b"another writer").unwrap();
        assert!(tags(&repo, &fd, &batch(&oid), &|| true).is_none());
        assert_eq!(
            fs::read(repo.join("refs/tags/v2.lock")).unwrap(),
            b"another writer"
        );
        assert!(!repo.join("refs/tags/v1.lock").exists());
        assert!(repo.join("refs/tags/v1").exists());
        fs::remove_file(repo.join("refs/tags/v2.lock")).unwrap();
        assert!(matches!(
            tags(&repo, &fd, &batch(&oid), &|| true),
            Some(Ok(()))
        ));
        assert!(!repo.join("refs/tags/v1").exists());
        assert_eq!(
            fs::read(repo.join("refs/tags/v2")).unwrap(),
            [oid, vec![b'\n']].concat()
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn root_aba_during_publication_cannot_mutate_the_replacement_or_its_locks() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        fs::write(
            repo.join("refs/tags/v1"),
            [oid.clone(), vec![b'\n']].concat(),
        )
        .unwrap();
        let swapped = AtomicBool::new(false);
        let active = || {
            if repo.join("refs/tags/v2").exists() && !swapped.swap(true, Ordering::Relaxed) {
                fs::rename(&repo, root.join("old")).unwrap();
                fixture(&repo);
                for name in ["v1", "v2", "v1.lock", "v2.lock"] {
                    fs::write(repo.join("refs/tags").join(name), b"replacement owner").unwrap();
                }
            }
            true
        };
        assert!(matches!(
            tags(&repo, &fd, &batch(&oid), &active),
            Some(Err(()))
        ));
        assert!(swapped.load(Ordering::Relaxed));
        for name in ["v1", "v2", "v1.lock", "v2.lock"] {
            assert_eq!(
                fs::read(repo.join("refs/tags").join(name)).unwrap(),
                b"replacement owner"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn detached_tags_fail_closed_without_touching_the_replacement() {
        let root = root();
        let repo = root.join("repo");
        let oid = fixture(&repo);
        let fd = File::open(&repo).unwrap();
        fs::write(
            repo.join("refs/tags/v1"),
            [oid.clone(), vec![b'\n']].concat(),
        )
        .unwrap();
        let swapped = AtomicBool::new(false);
        let active = || {
            if repo.join("refs/tags/v2").exists() && !swapped.swap(true, Ordering::Relaxed) {
                fs::rename(repo.join("refs/tags"), repo.join("refs/old-tags")).unwrap();
                fs::create_dir(repo.join("refs/tags")).unwrap();
                for name in ["v1", "v2", "v1.lock", "v2.lock"] {
                    fs::write(repo.join("refs/tags").join(name), b"replacement owner").unwrap();
                }
            }
            true
        };
        assert!(matches!(
            tags(&repo, &fd, &batch(&oid), &active),
            Some(Err(()))
        ));
        for name in ["v1", "v2", "v1.lock", "v2.lock"] {
            assert_eq!(
                fs::read(repo.join("refs/tags").join(name)).unwrap(),
                b"replacement owner"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn pending_gates_return_busy_instead_of_blocking_dirty_schedulers() {
        let root = root();
        let first = acquire(&root, &|| true).ok().unwrap();
        assert!(matches!(acquire(&root, &|| true), Err(Acquire::Busy)));
        first.release();
        let next = acquire(&root, &|| true).ok().unwrap();
        drop(first);
        assert!(matches!(acquire(&root, &|| true), Err(Acquire::Busy)));
        drop(next);
        assert!(acquire(&root, &|| true).is_ok());
        fs::remove_dir_all(root).unwrap();
    }
}
