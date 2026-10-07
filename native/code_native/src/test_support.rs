//! Test-only directory ownership: unwind and normal return both clean up.
use std::ops::Deref;
use std::path::{Path, PathBuf};

pub(crate) struct TestDirectory {
    _owner: tempfile::TempDir,
    path: PathBuf,
}
impl TestDirectory {
    pub(crate) fn new() -> Self {
        let owner = tempfile::tempdir().unwrap();
        // ABA tests rename this leaf to a sibling. Both remain owned by parent.
        let path = owner.path().join("root");
        std::fs::create_dir(&path).unwrap();
        Self {
            _owner: owner,
            path,
        }
    }
}
impl Deref for TestDirectory {
    type Target = PathBuf;
    fn deref(&self) -> &PathBuf {
        &self.path
    }
}
impl AsRef<Path> for TestDirectory {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

#[test]
fn unwinding_removes_both_the_directory_and_renamed_siblings() {
    let mut parent = PathBuf::new();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let root = TestDirectory::new();
        parent = root.parent().unwrap().to_path_buf();
        std::fs::rename(&root, root.with_extension("old")).unwrap();
        panic!("test assertion failure");
    }));
    assert!(result.is_err());
    assert!(!parent.exists());
}
