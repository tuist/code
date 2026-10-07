//! Complete-or-fallback log for plain, linear histories with canonical messages.
//! Git retains merge ordering, path filtering, encoding and rich rev syntax.
use rustler::{Binary, Encoder, Env, Term};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{Duration, Instant};

type Commit = (String, String, String, String, String, String, String);
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
fn text(bytes: &[u8]) -> Option<&str> {
    if !bytes.is_ascii() || bytes.iter().any(|byte| matches!(byte, 0 | 0x1e | 0x1f)) {
        return None;
    }
    std::str::from_utf8(bytes).ok()
}
fn message(bytes: &[u8]) -> Option<(String, String)> {
    let message = text(bytes)?;
    let (subject, rest) = message.split_once('\n').unwrap_or((message, ""));
    if subject.is_empty() || subject.trim() != subject || subject.chars().any(|c| c.is_control()) {
        return None;
    }
    let body = if rest.is_empty() {
        ""
    } else {
        let body = rest.strip_prefix('\n')?;
        // Git's paragraph handling is richer. Defer non-canonical separators.
        if body.starts_with('\n') || body.starts_with(' ') || body.starts_with('\t') {
            return None;
        }
        body
    };
    Some((subject.to_string(), body.to_string()))
}
fn date(time: &str) -> Option<String> {
    let (seconds, zone) = time.split_once(' ')?;
    if zone.len() != 5
        || !matches!(zone.as_bytes()[0], b'+' | b'-')
        || zone == "-0000"
        || !zone.as_bytes()[1..].iter().all(u8::is_ascii_digit)
    {
        return None;
    }
    let hours = zone[1..3].parse::<i32>().ok()?;
    let minutes = zone[3..5].parse::<i32>().ok()?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    if !seconds.as_bytes().iter().all(u8::is_ascii_digit) {
        return None;
    }
    let seconds = seconds.parse::<i64>().ok()?;
    let offset = (hours * 60 + minutes) * 60 * if zone.starts_with('-') { -1 } else { 1 };
    gix_date::Time { seconds, offset }
        .format(gix_date::time::format::ISO8601_STRICT)
        .ok()
}
fn history(
    repo: &Path,
    revision: &[u8],
    limit: usize,
    active: &impl Fn() -> bool,
) -> Option<Vec<Commit>> {
    if limit > 256 || !absent(&repo.join("shallow")) {
        return None;
    }
    let config = crate::config::plain_config(&repo.join("config")).ok()??;
    if config.sections().any(|section| {
        [
            b"log".as_slice(),
            b"i18n".as_slice(),
            b"mailmap".as_slice(),
            b"notes".as_slice(),
        ]
        .iter()
        .any(|name| section.header().name().eq_ignore_ascii_case(name))
    }) {
        return None;
    }
    let mut current = crate::resolve::plain_target(repo, revision, active)?;
    let mut store = crate::trees::Store::open(repo, active)?;
    let mut results = Vec::new();
    let mut budget = 4 * 1024 * 1024;
    let mut output_bytes = 0usize;
    if limit == 0 {
        let body = store.history_commit(&current, &mut budget, active)?;
        gix_object::CommitRef::from_bytes(&body, gix_hash::Kind::Sha1).ok()?;
    }
    for _ in 0..limit {
        if !active() {
            return None;
        }
        let body = store.history_commit(&current, &mut budget, active)?;
        let commit = gix_object::CommitRef::from_bytes(&body, gix_hash::Kind::Sha1).ok()?;
        if commit.parents.len() > 1 || !commit.extra_headers.is_empty() {
            return None;
        }
        let author = commit.author().ok()?;
        let committer = commit.committer().ok()?;
        let name = text(author.name.as_ref())?.to_string();
        let email = text(author.email.as_ref())?.to_string();
        let authored = date(author.time)?;
        let committed = date(committer.time)?;
        let (subject, message) = message(commit.message.as_ref())?;
        output_bytes = output_bytes.checked_add(
            name.len()
                + email.len()
                + authored.len()
                + committed.len()
                + subject.len()
                + message.len()
                + 40,
        )?;
        if output_bytes > 1024 * 1024 {
            return None;
        }
        results.push((
            gix_hash::ObjectId::from_bytes_or_panic(&current)
                .to_hex()
                .to_string(),
            name,
            email,
            authored,
            committed,
            subject,
            message,
        ));
        if let Some(parent) = commit.parents.first() {
            current = oid(parent)?;
            // Git parses the immediate parent while scheduling a commit, even
            // when max-count will stop output before that parent is returned.
            if results.len() == limit {
                let parent = store.history_commit(&current, &mut budget, active)?;
                gix_object::CommitRef::from_bytes(&parent, gix_hash::Kind::Sha1).ok()?;
            }
        } else {
            break;
        }
    }
    Some(results)
}
#[rustler::nif(schedule = "DirtyIo")]
fn linear_log<'a>(
    env: Env<'a>,
    repo: Binary<'a>,
    revision: Binary<'a>,
    limit: usize,
    timeout_ms: u64,
) -> Term<'a> {
    if !crate::refs::supported_environment() {
        return crate::fallback_git().encode(env);
    }
    let start = Instant::now();
    let maximum = Duration::from_millis(timeout_ms);
    let pid = env.pid();
    let repo = Path::new(std::ffi::OsStr::from_bytes(repo.as_slice()));
    let result = history(repo, revision.as_slice(), limit, &|| {
        start.elapsed() < maximum && pid.is_alive(env)
    });
    if start.elapsed() >= maximum {
        return crate::timeout().encode(env);
    }
    match result {
        Some(commits) => (crate::ok(), commits).encode(env),
        None => crate::fallback_git().encode(env),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn canonical_messages_and_dates_only() {
        assert_eq!(message(b"subject\n"), Some(("subject".into(), "".into())));
        assert_eq!(
            message(b"subject\n\nbody\n"),
            Some(("subject".into(), "body\n".into()))
        );
        for bytes in [
            &b"leading\ncontinued\n"[..],
            &b" title \n"[..],
            &b"\nempty\n"[..],
            &b"record\x1e"[..],
        ] {
            assert!(message(bytes).is_none());
        }
        assert_eq!(date("0 +0530"), Some("1970-01-01T05:30:00+05:30".into()));
        assert!(date("0 -0000").is_none());
        assert!(date("0 +9999").is_none());
    }
}
