//! Shared product and project-management logic exposed to each Tuist Code application.

pub mod agent;

use core::ffi::c_char;
use std::{
    ffi::CStr,
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

/// The product name used by Tuist Code applications.
pub const APP_NAME: &str = "Tuist Code";

/// The primary Tuist brand colour, represented as an RGB hexadecimal value.
pub const BRAND_COLOR: u32 = 0x6F2CFF;

/// The outcome of a shared project operation.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectOperationStatus {
    Success = 0,
    InvalidInput = 1,
    NotGitRepository = 2,
    InvalidDestination = 3,
    DestinationExists = 4,
    GitUnavailable = 5,
    CloneFailed = 6,
    OutputBufferTooSmall = 7,
}

impl ProjectOperationStatus {
    const fn from_error(error: ProjectOperationError) -> Self {
        match error {
            ProjectOperationError::InvalidInput => Self::InvalidInput,
            ProjectOperationError::NotGitRepository => Self::NotGitRepository,
            ProjectOperationError::InvalidDestination => Self::InvalidDestination,
            ProjectOperationError::DestinationExists => Self::DestinationExists,
            ProjectOperationError::GitUnavailable => Self::GitUnavailable,
            ProjectOperationError::CloneFailed => Self::CloneFailed,
        }
    }
}

/// A recoverable error from a shared project operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectOperationError {
    InvalidInput,
    NotGitRepository,
    InvalidDestination,
    DestinationExists,
    GitUnavailable,
    CloneFailed,
}

/// The outcome of a shared worktree operation.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorktreeOperationStatus {
    Success = 0,
    InvalidInput = 1,
    NotGitRepository = 2,
    InvalidDestination = 3,
    DestinationExists = 4,
    GitUnavailable = 5,
    CreationFailed = 6,
    OutputBufferTooSmall = 7,
}

impl WorktreeOperationStatus {
    const fn from_error(error: WorktreeOperationError) -> Self {
        match error {
            WorktreeOperationError::InvalidInput => Self::InvalidInput,
            WorktreeOperationError::NotGitRepository => Self::NotGitRepository,
            WorktreeOperationError::InvalidDestination => Self::InvalidDestination,
            WorktreeOperationError::DestinationExists => Self::DestinationExists,
            WorktreeOperationError::GitUnavailable => Self::GitUnavailable,
            WorktreeOperationError::CreationFailed => Self::CreationFailed,
        }
    }
}

/// A recoverable error from a shared worktree operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorktreeOperationError {
    InvalidInput,
    NotGitRepository,
    InvalidDestination,
    DestinationExists,
    GitUnavailable,
    CreationFailed,
}

/// A programming capability available to an agent session.
///
/// This is deliberately owned by the shared Rust library so desktop, iOS, and
/// Android clients advertise the same tool names and safety rules.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentTool {
    Read,
    List,
    Ls,
    Glob,
    Find,
    Grep,
    Write,
    Edit,
    ApplyPatch,
    Shell,
    Bash,
    GitStatus,
    GitDiff,
    AskUser,
}

impl AgentTool {
    pub const fn identifier(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::List => "list",
            Self::Ls => "ls",
            Self::Glob => "glob",
            Self::Find => "find",
            Self::Grep => "grep",
            Self::Write => "write",
            Self::Edit => "edit",
            Self::ApplyPatch => "apply_patch",
            Self::Shell => "shell",
            Self::Bash => "bash",
            Self::GitStatus => "git_status",
            Self::GitDiff => "git_diff",
            Self::AskUser => "ask_user",
        }
    }

    pub const fn requires_approval(self) -> bool {
        matches!(
            self,
            Self::Write | Self::Edit | Self::ApplyPatch | Self::Shell | Self::Bash
        )
    }

    fn from_identifier(value: &str) -> Option<Self> {
        match value {
            "read" => Some(Self::Read),
            "list" => Some(Self::List),
            "ls" => Some(Self::Ls),
            "glob" => Some(Self::Glob),
            "find" => Some(Self::Find),
            "grep" => Some(Self::Grep),
            "write" => Some(Self::Write),
            "edit" => Some(Self::Edit),
            "apply_patch" => Some(Self::ApplyPatch),
            "shell" => Some(Self::Shell),
            "bash" => Some(Self::Bash),
            "git_status" => Some(Self::GitStatus),
            "git_diff" => Some(Self::GitDiff),
            "ask_user" => Some(Self::AskUser),
            _ => None,
        }
    }
}

/// The request shape shared by the local agent runners.
///
/// User-interface clients decode provider tool calls into this type, obtain an
/// approval for mutating operations, and then call `execute_agent_tool`.
pub enum AgentToolRequest<'a> {
    Read {
        path: &'a str,
        offset: usize,
        limit: usize,
    },
    List {
        path: &'a str,
    },
    Glob {
        pattern: &'a str,
    },
    Grep {
        pattern: &'a str,
    },
    Write {
        path: &'a str,
        content: &'a str,
    },
    Edit {
        path: &'a str,
        old_text: &'a str,
        new_text: &'a str,
    },
    ApplyPatch {
        patch: &'a str,
    },
    Shell {
        command: &'a str,
    },
    GitStatus,
    GitDiff,
    AskUser {
        question: &'a str,
    },
}

impl AgentToolRequest<'_> {
    pub const fn tool(&self) -> AgentTool {
        match self {
            Self::Read { .. } => AgentTool::Read,
            Self::List { .. } => AgentTool::List,
            Self::Glob { .. } => AgentTool::Glob,
            Self::Grep { .. } => AgentTool::Grep,
            Self::Write { .. } => AgentTool::Write,
            Self::Edit { .. } => AgentTool::Edit,
            Self::ApplyPatch { .. } => AgentTool::ApplyPatch,
            Self::Shell { .. } => AgentTool::Shell,
            Self::GitStatus => AgentTool::GitStatus,
            Self::GitDiff => AgentTool::GitDiff,
            Self::AskUser { .. } => AgentTool::AskUser,
        }
    }
}

/// A tool result which may ask a client to collect a response from its human.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentToolResult {
    Output(String),
    NeedsUserInput(String),
}

/// A recoverable problem when the shared agent tool runtime cannot act.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentToolError {
    InvalidRoot,
    InvalidPath,
    NotFound,
    NotText,
    EditDidNotMatch,
    CommandFailed,
    Io,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentToolOperationStatus {
    Success = 0,
    InvalidInput = 1,
    Failed = 2,
    OutputBufferTooSmall = 3,
    NeedsUserInput = 4,
}

/// Lists the tools shared by all supported native clients.
pub const fn agent_tools() -> [AgentTool; 14] {
    [
        AgentTool::Read,
        AgentTool::List,
        AgentTool::Ls,
        AgentTool::Glob,
        AgentTool::Find,
        AgentTool::Grep,
        AgentTool::Write,
        AgentTool::Edit,
        AgentTool::ApplyPatch,
        AgentTool::Shell,
        AgentTool::Bash,
        AgentTool::GitStatus,
        AgentTool::GitDiff,
        AgentTool::AskUser,
    ]
}

/// Serializes the shared tool inventory for native presentation and providers.
pub fn agent_tool_catalog_json() -> String {
    let tools = agent_tools()
        .iter()
        .map(|tool| {
            format!(
                r#"{{"name":"{}","requires_approval":{}}}"#,
                tool.identifier(),
                tool.requires_approval()
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("[{tools}]")
}

/// Executes a shared programming tool inside one project worktree.
///
/// Paths are always resolved beneath `worktree_root`; callers must collect an
/// explicit human approval before passing a mutating request to this function.
pub fn execute_agent_tool(
    worktree_root: &Path,
    request: AgentToolRequest<'_>,
) -> Result<AgentToolResult, AgentToolError> {
    let root = worktree_root
        .canonicalize()
        .map_err(|_| AgentToolError::InvalidRoot)?;
    if !root.is_dir() {
        return Err(AgentToolError::InvalidRoot);
    }

    match request {
        AgentToolRequest::Read {
            path,
            offset,
            limit,
        } => {
            let path = agent_path(&root, path)?;
            let contents = fs::read_to_string(path).map_err(agent_io_error)?;
            let lines = contents.lines().skip(offset).take(limit.min(2_000));
            Ok(AgentToolResult::Output(
                lines.collect::<Vec<_>>().join("\n"),
            ))
        }
        AgentToolRequest::List { path } => {
            let path = agent_path(&root, path)?;
            let mut entries = fs::read_dir(path)
                .map_err(agent_io_error)?
                .filter_map(Result::ok)
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            entries.sort();
            Ok(AgentToolResult::Output(entries.join("\n")))
        }
        AgentToolRequest::Glob { pattern } => {
            let mut paths = Vec::new();
            collect_agent_paths(&root, &root, pattern, &mut paths)?;
            paths.sort();
            Ok(AgentToolResult::Output(paths.join("\n")))
        }
        AgentToolRequest::Grep { pattern } => {
            let mut matches = Vec::new();
            grep_agent_files(&root, &root, pattern, &mut matches)?;
            Ok(AgentToolResult::Output(matches.join("\n")))
        }
        AgentToolRequest::Write { path, content } => {
            let path = agent_write_path(&root, path)?;
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|_| AgentToolError::Io)?;
                let parent = parent.canonicalize().map_err(agent_io_error)?;
                if !parent.starts_with(&root) {
                    return Err(AgentToolError::InvalidPath);
                }
            }
            fs::write(path, content).map_err(|_| AgentToolError::Io)?;
            Ok(AgentToolResult::Output("File written.".to_owned()))
        }
        AgentToolRequest::Edit {
            path,
            old_text,
            new_text,
        } => {
            let path = agent_path(&root, path)?;
            let contents = fs::read_to_string(&path).map_err(agent_io_error)?;
            if old_text.is_empty() {
                return Err(AgentToolError::EditDidNotMatch);
            }
            let occurrences = contents.matches(old_text).count();
            if occurrences != 1 {
                return Err(AgentToolError::EditDidNotMatch);
            }
            fs::write(path, contents.replacen(old_text, new_text, 1))
                .map_err(|_| AgentToolError::Io)?;
            Ok(AgentToolResult::Output("File edited.".to_owned()))
        }
        AgentToolRequest::ApplyPatch { patch } => {
            let patch_path = root.join(format!(
                ".tuist-code-agent-{}.patch",
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| AgentToolError::Io)?
                    .as_nanos()
            ));
            fs::write(&patch_path, patch).map_err(|_| AgentToolError::Io)?;
            let output = Command::new("git")
                .args(["apply", "--whitespace=nowarn"])
                .arg(&patch_path)
                .current_dir(&root)
                .output()
                .map_err(|_| AgentToolError::CommandFailed)?;
            let _ = fs::remove_file(patch_path);
            command_result(output)
        }
        AgentToolRequest::Shell { command } => {
            let output = Command::new("/bin/sh")
                .args(["-lc", command])
                .current_dir(&root)
                .output()
                .map_err(|_| AgentToolError::CommandFailed)?;
            command_result(output)
        }
        AgentToolRequest::GitStatus => {
            let output = Command::new("git")
                .args(["status", "--short", "--branch"])
                .current_dir(&root)
                .output()
                .map_err(|_| AgentToolError::CommandFailed)?;
            command_result(output)
        }
        AgentToolRequest::GitDiff => {
            let output = Command::new("git")
                .args(["diff", "--no-ext-diff"])
                .current_dir(&root)
                .output()
                .map_err(|_| AgentToolError::CommandFailed)?;
            command_result(output)
        }
        AgentToolRequest::AskUser { question } => {
            Ok(AgentToolResult::NeedsUserInput(question.to_owned()))
        }
    }
}

fn agent_path(root: &Path, requested: &str) -> Result<PathBuf, AgentToolError> {
    let candidate = agent_write_path(root, requested)?;
    let resolved = candidate.canonicalize().map_err(agent_io_error)?;
    if resolved.starts_with(root) {
        Ok(resolved)
    } else {
        Err(AgentToolError::InvalidPath)
    }
}

fn agent_write_path(root: &Path, requested: &str) -> Result<PathBuf, AgentToolError> {
    let requested = Path::new(requested);
    if requested.as_os_str().is_empty()
        || requested.is_absolute()
        || requested.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    {
        return Err(AgentToolError::InvalidPath);
    }
    Ok(root.join(requested))
}

fn collect_agent_paths(
    root: &Path,
    directory: &Path,
    pattern: &str,
    paths: &mut Vec<String>,
) -> Result<(), AgentToolError> {
    for entry in fs::read_dir(directory)
        .map_err(agent_io_error)?
        .filter_map(Result::ok)
    {
        let path = entry.path();
        let file_type = entry.file_type().map_err(agent_io_error)?;
        if entry.file_name() == ".git" || file_type.is_symlink() {
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .map_err(|_| AgentToolError::InvalidPath)?
            .to_string_lossy()
            .into_owned();
        if glob_matches(pattern, &relative) {
            paths.push(relative.clone());
        }
        if file_type.is_dir() {
            collect_agent_paths(root, &path, pattern, paths)?;
        }
    }
    Ok(())
}

fn grep_agent_files(
    root: &Path,
    directory: &Path,
    pattern: &str,
    matches: &mut Vec<String>,
) -> Result<(), AgentToolError> {
    for entry in fs::read_dir(directory)
        .map_err(agent_io_error)?
        .filter_map(Result::ok)
    {
        if matches.len() >= 200 {
            return Ok(());
        }
        let path = entry.path();
        let file_type = entry.file_type().map_err(agent_io_error)?;
        if entry.file_name() == ".git" || file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            grep_agent_files(root, &path, pattern, matches)?;
            continue;
        }
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        let relative = path
            .strip_prefix(root)
            .map_err(|_| AgentToolError::InvalidPath)?
            .to_string_lossy();
        for (index, line) in contents.lines().enumerate() {
            if line.contains(pattern) {
                matches.push(format!("{}:{}:{}", relative, index + 1, line));
                if matches.len() >= 200 {
                    return Ok(());
                }
            }
        }
    }
    Ok(())
}

fn glob_matches(pattern: &str, candidate: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    let parts = pattern.split('*').collect::<Vec<_>>();
    let mut remaining = candidate;
    for (index, part) in parts.iter().enumerate() {
        if part.is_empty() {
            continue;
        }
        let Some(position) = remaining.find(part) else {
            return false;
        };
        if index == 0 && !pattern.starts_with('*') && position != 0 {
            return false;
        }
        remaining = &remaining[position + part.len()..];
    }
    pattern.ends_with('*') || remaining.is_empty()
}

fn command_result(output: std::process::Output) -> Result<AgentToolResult, AgentToolError> {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let contents = format!("{stdout}{stderr}");
    if output.status.success() {
        Ok(AgentToolResult::Output(contents))
    } else {
        Err(AgentToolError::CommandFailed)
    }
}

fn agent_io_error(error: std::io::Error) -> AgentToolError {
    match error.kind() {
        std::io::ErrorKind::NotFound => AgentToolError::NotFound,
        std::io::ErrorKind::InvalidData => AgentToolError::NotText,
        _ => AgentToolError::Io,
    }
}

/// The shared lifecycle state for an authenticated Tuist Code session.
///
/// Platform applications own their presentation and secure token storage. Rust owns
/// the state transitions so each platform follows the same authentication rules.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthenticationState {
    SignedOut = 0,
    Authenticating = 1,
    Authenticated = 2,
    Failed = 3,
}

impl AuthenticationState {
    const fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::SignedOut),
            1 => Some(Self::Authenticating),
            2 => Some(Self::Authenticated),
            3 => Some(Self::Failed),
            _ => None,
        }
    }
}

/// A product capability that a platform client may expose.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProductCapability {
    LocalProjects = 0,
    LocalSessions = 1,
    RemoteSessions = 2,
    RemoteBuilds = 3,
}

/// An inference service that can be configured for a Tuist Code installation.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceProvider {
    Together = 0,
    Fireworks = 1,
    Codex = 2,
}

impl InferenceProvider {
    const fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::Together),
            1 => Some(Self::Fireworks),
            2 => Some(Self::Codex),
            _ => None,
        }
    }

    const fn identifier(self) -> &'static str {
        match self {
            Self::Together => "together",
            Self::Fireworks => "fireworks",
            Self::Codex => "codex",
        }
    }

    const fn display_name(self) -> &'static str {
        match self {
            Self::Together => "Together AI",
            Self::Fireworks => "Fireworks AI",
            Self::Codex => "Codex",
        }
    }

    const fn authentication_kind(self) -> InferenceAuthenticationKind {
        match self {
            Self::Together | Self::Fireworks => InferenceAuthenticationKind::ApiKey,
            Self::Codex => InferenceAuthenticationKind::OAuth,
        }
    }

    const fn models_json(self) -> &'static str {
        // Model availability belongs to an authenticated account and changes
        // independently of an application release. Platform clients fetch the
        // live catalog after authentication instead of shipping a stale list.
        "[]"
    }

    fn from_identifier(value: &str) -> Option<Self> {
        match value {
            "together" => Some(Self::Together),
            "fireworks" => Some(Self::Fireworks),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }
}

/// The credential flow a provider supports in Tuist Code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceAuthenticationKind {
    ApiKey,
    OAuth,
}

impl InferenceAuthenticationKind {
    const fn identifier(self) -> &'static str {
        match self {
            Self::ApiKey => "api_key",
            Self::OAuth => "oauth",
        }
    }
}

/// The durable lifecycle state of an inference provider connection.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceProviderConnectionState {
    RequiresAuthorization = 0,
    Authorizing = 1,
    Configured = 2,
}

impl InferenceProviderConnectionState {
    const fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::RequiresAuthorization),
            1 => Some(Self::Authorizing),
            2 => Some(Self::Configured),
            _ => None,
        }
    }

    const fn identifier(self) -> &'static str {
        match self {
            Self::RequiresAuthorization => "requires_authorization",
            Self::Authorizing => "authorizing",
            Self::Configured => "configured",
        }
    }

    fn from_identifier(value: &str) -> Option<Self> {
        match value {
            "requires_authorization" => Some(Self::RequiresAuthorization),
            "authorizing" => Some(Self::Authorizing),
            "configured" => Some(Self::Configured),
            _ => None,
        }
    }
}

/// A persisted provider connection. Secrets intentionally remain outside this
/// value so platform secure storage can protect them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InferenceProviderConnection {
    pub provider: InferenceProvider,
    pub state: InferenceProviderConnectionState,
}

/// A user-configured account for an inference provider. The account identifier
/// is stable across platform clients while the credential remains in the
/// platform's secure storage.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InferenceAccount {
    pub id: String,
    pub provider: InferenceProvider,
    pub name: String,
    pub state: InferenceProviderConnectionState,
}

/// An error from the cross-platform provider registry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceProviderStoreError {
    InvalidInput,
    StorageUnavailable,
}

/// The outcome of a provider registry operation exposed to native clients.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceProviderStoreStatus {
    Success = 0,
    InvalidInput = 1,
    StorageUnavailable = 2,
    OutputBufferTooSmall = 3,
}

impl InferenceProviderStoreStatus {
    const fn from_error(error: InferenceProviderStoreError) -> Self {
        match error {
            InferenceProviderStoreError::InvalidInput => Self::InvalidInput,
            InferenceProviderStoreError::StorageUnavailable => Self::StorageUnavailable,
        }
    }
}

impl ProductCapability {
    const fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::LocalProjects),
            1 => Some(Self::LocalSessions),
            2 => Some(Self::RemoteSessions),
            3 => Some(Self::RemoteBuilds),
            _ => None,
        }
    }
}

/// An event reported by a platform-specific authentication implementation.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthenticationEvent {
    RestoreUnauthenticated = 0,
    RestoreAuthenticated = 1,
    StartSignIn = 2,
    SignInSucceeded = 3,
    SignInFailed = 4,
    Cancelled = 5,
    SignOut = 6,
}

impl AuthenticationEvent {
    const fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::RestoreUnauthenticated),
            1 => Some(Self::RestoreAuthenticated),
            2 => Some(Self::StartSignIn),
            3 => Some(Self::SignInSucceeded),
            4 => Some(Self::SignInFailed),
            5 => Some(Self::Cancelled),
            6 => Some(Self::SignOut),
            _ => None,
        }
    }
}

const APP_NAME_C_STRING: &[u8] = b"Tuist Code\0";

/// Returns the shared product name.
pub const fn app_name() -> &'static str {
    APP_NAME
}

/// Returns the shared primary Tuist brand colour.
pub const fn brand_color() -> u32 {
    BRAND_COLOR
}

const INFERENCE_PROVIDER_STORE_FILE: &str = "inference-providers.v1";
const INFERENCE_ACCOUNT_STORE_FILE: &str = "inference-accounts.v1";

/// Returns the providers that Tuist Code knows how to configure.
pub const fn inference_provider_catalog() -> [InferenceProvider; 3] {
    [
        InferenceProvider::Together,
        InferenceProvider::Fireworks,
        InferenceProvider::Codex,
    ]
}

/// Loads provider connections from the cross-platform registry.
///
/// The caller supplies the application-support directory for its platform.
/// Rust owns the record format, validation, and atomic update rules while each
/// platform keeps credentials in its own secure vault.
pub fn load_inference_provider_connections(
    storage_directory: &Path,
) -> Result<Vec<InferenceProviderConnection>, InferenceProviderStoreError> {
    let storage_file = storage_directory.join(INFERENCE_PROVIDER_STORE_FILE);
    if !storage_file.exists() {
        return Ok(Vec::new());
    }

    let contents = fs::read_to_string(storage_file)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    let mut connections = Vec::new();

    for line in contents.lines() {
        let Some((provider, state)) = line.split_once('\t') else {
            return Err(InferenceProviderStoreError::StorageUnavailable);
        };
        let (Some(provider), Some(state)) = (
            InferenceProvider::from_identifier(provider),
            InferenceProviderConnectionState::from_identifier(state),
        ) else {
            return Err(InferenceProviderStoreError::StorageUnavailable);
        };
        connections.push(InferenceProviderConnection { provider, state });
    }

    connections.sort_by_key(|connection| connection.provider.identifier());
    connections.dedup_by_key(|connection| connection.provider.identifier());
    Ok(connections)
}

/// Saves the connection state for an inference provider.
pub fn save_inference_provider_connection(
    storage_directory: &Path,
    provider: InferenceProvider,
    state: InferenceProviderConnectionState,
) -> Result<(), InferenceProviderStoreError> {
    if provider.authentication_kind() == InferenceAuthenticationKind::ApiKey
        && state != InferenceProviderConnectionState::Configured
    {
        return Err(InferenceProviderStoreError::InvalidInput);
    }

    fs::create_dir_all(storage_directory)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    let mut connections = load_inference_provider_connections(storage_directory)?;
    connections.retain(|connection| connection.provider != provider);
    connections.push(InferenceProviderConnection { provider, state });
    connections.sort_by_key(|connection| connection.provider.identifier());

    let contents = connections
        .iter()
        .map(|connection| {
            format!(
                "{}\t{}",
                connection.provider.identifier(),
                connection.state.identifier()
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let temporary_file = storage_directory.join(format!("{INFERENCE_PROVIDER_STORE_FILE}.tmp"));
    fs::write(&temporary_file, contents)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    fs::rename(
        temporary_file,
        storage_directory.join(INFERENCE_PROVIDER_STORE_FILE),
    )
    .map_err(|_| InferenceProviderStoreError::StorageUnavailable)
}

/// Removes a provider connection while leaving the platform credential vault to
/// delete the corresponding secret.
pub fn remove_inference_provider_connection(
    storage_directory: &Path,
    provider: InferenceProvider,
) -> Result<(), InferenceProviderStoreError> {
    let mut connections = load_inference_provider_connections(storage_directory)?;
    connections.retain(|connection| connection.provider != provider);

    fs::create_dir_all(storage_directory)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    let contents = connections
        .iter()
        .map(|connection| {
            format!(
                "{}\t{}",
                connection.provider.identifier(),
                connection.state.identifier()
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let temporary_file = storage_directory.join(format!("{INFERENCE_PROVIDER_STORE_FILE}.tmp"));
    fs::write(&temporary_file, contents)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    fs::rename(
        temporary_file,
        storage_directory.join(INFERENCE_PROVIDER_STORE_FILE),
    )
    .map_err(|_| InferenceProviderStoreError::StorageUnavailable)
}

/// Serializes provider definitions for native user interfaces.
pub fn inference_provider_catalog_json() -> String {
    let providers = inference_provider_catalog()
        .iter()
        .map(|provider| {
            format!(
                r#"{{"id":"{}","name":"{}","authentication":"{}","models":{}}}"#,
                provider.identifier(),
                provider.display_name(),
                provider.authentication_kind().identifier(),
                provider.models_json()
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("[{providers}]")
}

/// Serializes persisted provider connections for native user interfaces.
pub fn inference_provider_connections_json(
    storage_directory: &Path,
) -> Result<String, InferenceProviderStoreError> {
    let connections = load_inference_provider_connections(storage_directory)?;
    let connections = connections
        .iter()
        .map(|connection| {
            format!(
                r#"{{"id":"{}","state":"{}"}}"#,
                connection.provider.identifier(),
                connection.state.identifier()
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    Ok(format!("[{connections}]"))
}

/// Loads inference accounts, migrating the previous one-connection-per-provider
/// registry into named accounts the first time a client reads it.
pub fn load_inference_accounts(
    storage_directory: &Path,
) -> Result<Vec<InferenceAccount>, InferenceProviderStoreError> {
    let storage_file = storage_directory.join(INFERENCE_ACCOUNT_STORE_FILE);
    if !storage_file.exists() {
        return load_inference_provider_connections(storage_directory).map(|connections| {
            connections
                .into_iter()
                .map(|connection| InferenceAccount {
                    id: format!("legacy-{}", connection.provider.identifier()),
                    provider: connection.provider,
                    name: connection.provider.display_name().to_owned(),
                    state: connection.state,
                })
                .collect()
        });
    }

    let contents = fs::read_to_string(storage_file)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    let mut accounts = Vec::new();
    for line in contents.lines() {
        let mut fields = line.split('\t');
        let (Some(id), Some(provider), Some(name), Some(state), None) = (
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
        ) else {
            return Err(InferenceProviderStoreError::StorageUnavailable);
        };
        let (Some(provider), Some(state)) = (
            InferenceProvider::from_identifier(provider),
            InferenceProviderConnectionState::from_identifier(state),
        ) else {
            return Err(InferenceProviderStoreError::StorageUnavailable);
        };
        if !is_valid_inference_account_field(id) || !is_valid_inference_account_field(name) {
            return Err(InferenceProviderStoreError::StorageUnavailable);
        }
        accounts.push(InferenceAccount {
            id: id.to_owned(),
            provider,
            name: name.to_owned(),
            state,
        });
    }
    accounts.sort_by(|left, right| left.name.cmp(&right.name).then(left.id.cmp(&right.id)));
    accounts.dedup_by(|left, right| left.id == right.id);
    Ok(accounts)
}

/// Saves an inference account without ever serializing its credential.
pub fn save_inference_account(
    storage_directory: &Path,
    account: InferenceAccount,
) -> Result<(), InferenceProviderStoreError> {
    if !is_valid_inference_account_field(&account.id)
        || !is_valid_inference_account_field(&account.name)
        || (account.provider.authentication_kind() == InferenceAuthenticationKind::ApiKey
            && account.state != InferenceProviderConnectionState::Configured)
    {
        return Err(InferenceProviderStoreError::InvalidInput);
    }
    let mut accounts = load_inference_accounts(storage_directory)?;
    accounts.retain(|stored_account| stored_account.id != account.id);
    accounts.push(account);
    write_inference_accounts(storage_directory, &accounts)
}

/// Removes one inference account while leaving credential deletion to the
/// platform secure-storage implementation.
pub fn remove_inference_account(
    storage_directory: &Path,
    account_id: &str,
) -> Result<(), InferenceProviderStoreError> {
    if !is_valid_inference_account_field(account_id) {
        return Err(InferenceProviderStoreError::InvalidInput);
    }
    let mut accounts = load_inference_accounts(storage_directory)?;
    accounts.retain(|account| account.id != account_id);
    write_inference_accounts(storage_directory, &accounts)
}

fn is_valid_inference_account_field(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 120 && !value.contains(['\t', '\n', '\r'])
}

fn write_inference_accounts(
    storage_directory: &Path,
    accounts: &[InferenceAccount],
) -> Result<(), InferenceProviderStoreError> {
    fs::create_dir_all(storage_directory)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    let mut accounts = accounts.to_owned();
    accounts.sort_by(|left, right| left.name.cmp(&right.name).then(left.id.cmp(&right.id)));
    let contents = accounts
        .iter()
        .map(|account| {
            format!(
                "{}\t{}\t{}\t{}",
                account.id,
                account.provider.identifier(),
                account.name,
                account.state.identifier()
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let temporary_file = storage_directory.join(format!("{INFERENCE_ACCOUNT_STORE_FILE}.tmp"));
    fs::write(&temporary_file, contents)
        .map_err(|_| InferenceProviderStoreError::StorageUnavailable)?;
    fs::rename(
        temporary_file,
        storage_directory.join(INFERENCE_ACCOUNT_STORE_FILE),
    )
    .map_err(|_| InferenceProviderStoreError::StorageUnavailable)
}

/// Serializes persisted inference accounts for a native user interface.
pub fn inference_accounts_json(
    storage_directory: &Path,
) -> Result<String, InferenceProviderStoreError> {
    let accounts = load_inference_accounts(storage_directory)?;
    let accounts = accounts
        .iter()
        .map(|account| {
            format!(
                r#"{{"id":"{}","provider_id":"{}","name":"{}","state":"{}"}}"#,
                account.id,
                account.provider.identifier(),
                account.name,
                account.state.identifier()
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    Ok(format!("[{accounts}]"))
}

/// Returns whether a directory is the root of a Git repository or Git worktree.
pub fn is_git_repository(directory: &Path) -> bool {
    directory.is_dir() && directory.join(".git").exists()
}

/// Derives the directory name Git uses when cloning a remote repository.
pub fn project_name_from_remote(remote: &str) -> Result<String, ProjectOperationError> {
    let remote = remote.trim();
    let repository_name = remote
        .trim_end_matches('/')
        .rsplit(|character| character == '/' || character == ':')
        .next()
        .unwrap_or_default();
    let repository_name = repository_name
        .strip_suffix(".git")
        .unwrap_or(repository_name);

    if repository_name.is_empty()
        || matches!(repository_name, "." | "..")
        || repository_name.contains('/')
        || repository_name.contains('\\')
    {
        return Err(ProjectOperationError::InvalidInput);
    }

    Ok(repository_name.to_owned())
}

/// Clones a remote Git repository into a new directory below `destination_parent`.
///
/// The operation is intentionally implemented here so every native client follows the
/// same validation, destination naming, and Git invocation rules.
pub fn clone_repository(
    remote: &str,
    destination_parent: &Path,
) -> Result<PathBuf, ProjectOperationError> {
    let project_name = project_name_from_remote(remote)?;

    if !destination_parent.is_dir() {
        return Err(ProjectOperationError::InvalidDestination);
    }

    let destination = destination_parent.join(project_name);
    if destination.exists() {
        return Err(ProjectOperationError::DestinationExists);
    }

    let status = Command::new("git")
        .arg("clone")
        .arg("--")
        .arg(remote.trim())
        .arg(&destination)
        .status()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                ProjectOperationError::GitUnavailable
            } else {
                ProjectOperationError::CloneFailed
            }
        })?;

    if !status.success() || !is_git_repository(&destination) {
        return Err(ProjectOperationError::CloneFailed);
    }

    Ok(destination)
}

/// Derives a safe directory name for a worktree from its Git branch name.
pub fn worktree_directory_name(branch: &str) -> Result<String, WorktreeOperationError> {
    let branch = branch.trim();
    if branch.is_empty()
        || branch == "HEAD"
        || branch.starts_with('-')
        || branch.starts_with('/')
        || branch.ends_with('/')
        || branch.starts_with('.')
        || branch.ends_with('.')
        || branch.contains("..")
        || branch.contains("@{")
        || branch.chars().any(|character| {
            character.is_control()
                || matches!(character, ' ' | '~' | '^' | ':' | '?' | '*' | '[' | '\\')
        })
    {
        return Err(WorktreeOperationError::InvalidInput);
    }

    let directory_name = branch.replace('/', "-");
    if directory_name.is_empty() {
        return Err(WorktreeOperationError::InvalidInput);
    }

    Ok(directory_name)
}

/// Creates a new Git worktree on a new branch below `destination_parent`.
///
/// A session is represented by the returned worktree directory. Keeping this in the
/// shared library gives each platform identical branch, path, and Git rules.
pub fn create_worktree(
    repository: &Path,
    branch: &str,
    destination_parent: &Path,
) -> Result<PathBuf, WorktreeOperationError> {
    if !is_git_repository(repository) {
        return Err(WorktreeOperationError::NotGitRepository);
    }

    if !destination_parent.is_dir() {
        return Err(WorktreeOperationError::InvalidDestination);
    }

    let worktree_directory = destination_parent.join(worktree_directory_name(branch)?);
    if worktree_directory.exists() {
        return Err(WorktreeOperationError::DestinationExists);
    }

    let status = Command::new("git")
        .arg("worktree")
        .arg("add")
        .arg("-b")
        .arg(branch.trim())
        .arg(&worktree_directory)
        .arg("HEAD")
        .current_dir(repository)
        .status()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                WorktreeOperationError::GitUnavailable
            } else {
                WorktreeOperationError::CreationFailed
            }
        })?;

    if !status.success() || !is_git_repository(&worktree_directory) {
        return Err(WorktreeOperationError::CreationFailed);
    }

    Ok(worktree_directory)
}

/// Creates an immediately usable local session worktree for a repository.
///
/// The generated branch and directory are deliberately temporary identifiers. An
/// agent can rename the session and worktree once it understands the task. The
/// worktree lives beside the repository under `.tuist-code-worktrees`, keeping
/// generated session directories out of the repository itself.
pub fn create_default_session_worktree(
    repository: &Path,
) -> Result<PathBuf, WorktreeOperationError> {
    if !is_git_repository(repository) {
        return Err(WorktreeOperationError::NotGitRepository);
    }

    let Some(repository_parent) = repository.parent() else {
        return Err(WorktreeOperationError::InvalidDestination);
    };
    let Some(repository_name) = repository.file_name() else {
        return Err(WorktreeOperationError::InvalidDestination);
    };

    let destination_parent = repository_parent
        .join(".tuist-code-worktrees")
        .join(repository_name);
    fs::create_dir_all(&destination_parent)
        .map_err(|_| WorktreeOperationError::InvalidDestination)?;

    let identifier = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| WorktreeOperationError::CreationFailed)?
        .as_nanos();
    let branch = format!("tuist-code/session-{identifier}");
    create_worktree(repository, &branch, &destination_parent)
}

/// Renames a session's worktree directory without changing its Git branch.
///
/// Session titles are application metadata, but validating it here ensures every
/// platform accepts the same agent supplied title. The worktree move itself is
/// performed by Git so its metadata stays consistent.
pub fn rename_session_worktree(
    repository: &Path,
    current_worktree: &Path,
    session_title: &str,
    new_worktree_name: &str,
) -> Result<PathBuf, WorktreeOperationError> {
    let session_title = session_title.trim();
    if session_title.is_empty()
        || session_title.len() > 120
        || session_title.chars().any(char::is_control)
    {
        return Err(WorktreeOperationError::InvalidInput);
    }

    if !is_git_repository(repository) || !is_git_repository(current_worktree) {
        return Err(WorktreeOperationError::NotGitRepository);
    }

    let Some(destination_parent) = current_worktree.parent() else {
        return Err(WorktreeOperationError::InvalidDestination);
    };
    let worktree_directory_name = worktree_directory_name(new_worktree_name)?;
    let destination = destination_parent.join(worktree_directory_name);

    if destination == current_worktree {
        return Ok(destination);
    }
    if destination.exists() {
        return Err(WorktreeOperationError::DestinationExists);
    }

    let status = Command::new("git")
        .arg("worktree")
        .arg("move")
        .arg(current_worktree)
        .arg(&destination)
        .current_dir(repository)
        .status()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                WorktreeOperationError::GitUnavailable
            } else {
                WorktreeOperationError::CreationFailed
            }
        })?;

    if !status.success() || !is_git_repository(&destination) {
        return Err(WorktreeOperationError::CreationFailed);
    }

    Ok(destination)
}

/// Applies an authentication event to the current shared authentication state.
pub fn authentication_state_after(
    state: AuthenticationState,
    event: AuthenticationEvent,
) -> AuthenticationState {
    match event {
        AuthenticationEvent::RestoreUnauthenticated | AuthenticationEvent::SignOut => {
            AuthenticationState::SignedOut
        }
        AuthenticationEvent::RestoreAuthenticated => AuthenticationState::Authenticated,
        AuthenticationEvent::StartSignIn
            if matches!(
                state,
                AuthenticationState::SignedOut | AuthenticationState::Failed
            ) =>
        {
            AuthenticationState::Authenticating
        }
        AuthenticationEvent::SignInSucceeded if state == AuthenticationState::Authenticating => {
            AuthenticationState::Authenticated
        }
        AuthenticationEvent::SignInFailed => AuthenticationState::Failed,
        AuthenticationEvent::Cancelled if state == AuthenticationState::Authenticating => {
            AuthenticationState::SignedOut
        }
        _ => state,
    }
}

/// Returns whether an account state may use a product capability.
///
/// Local repository and worktree actions are deliberately available without an
/// account. Tuist-backed sessions and builds require authentication.
pub fn is_capability_available(
    authentication_state: AuthenticationState,
    capability: ProductCapability,
) -> bool {
    match capability {
        ProductCapability::LocalProjects | ProductCapability::LocalSessions => true,
        ProductCapability::RemoteSessions | ProductCapability::RemoteBuilds => {
            authentication_state == AuthenticationState::Authenticated
        }
    }
}

/// Exposes the product name to Apple application code.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_app_name() -> *const c_char {
    APP_NAME_C_STRING.as_ptr().cast()
}

/// Exposes the primary brand colour to native applications.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_brand_color() -> u32 {
    brand_color()
}

/// Validates a local directory as a Git repository for any platform client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_validate_git_repository(directory_path: *const c_char) -> i32 {
    let Ok(directory_path) = c_string(directory_path) else {
        return ProjectOperationStatus::InvalidInput as i32;
    };

    if is_git_repository(Path::new(&directory_path)) {
        ProjectOperationStatus::Success as i32
    } else {
        ProjectOperationStatus::NotGitRepository as i32
    }
}

/// Clones a remote Git repository and writes the created project directory to `output_path`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_clone_git_repository(
    remote: *const c_char,
    destination_parent: *const c_char,
    output_path: *mut c_char,
    output_path_capacity: usize,
) -> i32 {
    let (Ok(remote), Ok(destination_parent)) = (c_string(remote), c_string(destination_parent))
    else {
        return ProjectOperationStatus::InvalidInput as i32;
    };

    let destination = match clone_repository(&remote, Path::new(&destination_parent)) {
        Ok(destination) => destination,
        Err(error) => return ProjectOperationStatus::from_error(error) as i32,
    };

    match write_c_string(
        &destination.to_string_lossy(),
        output_path,
        output_path_capacity,
    ) {
        Ok(()) => ProjectOperationStatus::Success as i32,
        Err(()) => ProjectOperationStatus::OutputBufferTooSmall as i32,
    }
}

/// Creates a Git worktree for a project session and writes its directory to `output_path`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_create_git_worktree(
    repository: *const c_char,
    branch: *const c_char,
    destination_parent: *const c_char,
    output_path: *mut c_char,
    output_path_capacity: usize,
) -> i32 {
    let (Ok(repository), Ok(branch), Ok(destination_parent)) = (
        c_string(repository),
        c_string(branch),
        c_string(destination_parent),
    ) else {
        return WorktreeOperationStatus::InvalidInput as i32;
    };

    let worktree = match create_worktree(
        Path::new(&repository),
        &branch,
        Path::new(&destination_parent),
    ) {
        Ok(worktree) => worktree,
        Err(error) => return WorktreeOperationStatus::from_error(error) as i32,
    };

    match write_c_string(
        &worktree.to_string_lossy(),
        output_path,
        output_path_capacity,
    ) {
        Ok(()) => WorktreeOperationStatus::Success as i32,
        Err(()) => WorktreeOperationStatus::OutputBufferTooSmall as i32,
    }
}

/// Creates a session worktree using the shared default location and writes its
/// directory to `output_path`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_create_default_session_worktree(
    repository: *const c_char,
    output_path: *mut c_char,
    output_path_capacity: usize,
) -> i32 {
    let Ok(repository) = c_string(repository) else {
        return WorktreeOperationStatus::InvalidInput as i32;
    };

    let worktree = match create_default_session_worktree(Path::new(&repository)) {
        Ok(worktree) => worktree,
        Err(error) => return WorktreeOperationStatus::from_error(error) as i32,
    };

    match write_c_string(
        &worktree.to_string_lossy(),
        output_path,
        output_path_capacity,
    ) {
        Ok(()) => WorktreeOperationStatus::Success as i32,
        Err(()) => WorktreeOperationStatus::OutputBufferTooSmall as i32,
    }
}

/// Renames a session worktree and writes the new directory to `output_path`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_rename_session_worktree(
    repository: *const c_char,
    current_worktree: *const c_char,
    session_title: *const c_char,
    new_worktree_name: *const c_char,
    output_path: *mut c_char,
    output_path_capacity: usize,
) -> i32 {
    let (Ok(repository), Ok(current_worktree), Ok(session_title), Ok(new_worktree_name)) = (
        c_string(repository),
        c_string(current_worktree),
        c_string(session_title),
        c_string(new_worktree_name),
    ) else {
        return WorktreeOperationStatus::InvalidInput as i32;
    };

    let worktree = match rename_session_worktree(
        Path::new(&repository),
        Path::new(&current_worktree),
        &session_title,
        &new_worktree_name,
    ) {
        Ok(worktree) => worktree,
        Err(error) => return WorktreeOperationStatus::from_error(error) as i32,
    };

    match write_c_string(
        &worktree.to_string_lossy(),
        output_path,
        output_path_capacity,
    ) {
        Ok(()) => WorktreeOperationStatus::Success as i32,
        Err(()) => WorktreeOperationStatus::OutputBufferTooSmall as i32,
    }
}

/// Writes the supported inference-provider catalog as JSON for a native client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_inference_provider_catalog(
    output: *mut c_char,
    output_capacity: usize,
) -> i32 {
    match write_c_string(&inference_provider_catalog_json(), output, output_capacity) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(()) => InferenceProviderStoreStatus::OutputBufferTooSmall as i32,
    }
}

/// Writes the shared agent tool inventory as JSON for native clients.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_agent_tool_catalog(
    output: *mut c_char,
    output_capacity: usize,
) -> i32 {
    match write_c_string(&agent_tool_catalog_json(), output, output_capacity) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(()) => InferenceProviderStoreStatus::OutputBufferTooSmall as i32,
    }
}

/// Returns whether the named agent tool needs explicit user approval before it
/// may execute. The platform client presents that approval; Rust owns the
/// classification so every client follows the same rule.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_agent_tool_requires_approval(tool: *const c_char) -> i32 {
    let Ok(tool) = c_string(tool) else {
        return 1;
    };
    AgentTool::from_identifier(&tool)
        .map(AgentTool::requires_approval)
        .unwrap_or(true) as i32
}

/// Executes one programming tool within a session worktree.
///
/// `path`, `value`, and `replacement` are interpreted by the named tool:
/// - read: path, offset, limit
/// - list, glob, grep: value
/// - write: path and value
/// - edit: path, value (old text), replacement (new text)
/// - apply_patch, shell, ask_user: value
/// - git_status, git_diff: no additional values
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_execute_agent_tool(
    worktree_root: *const c_char,
    tool: *const c_char,
    path: *const c_char,
    value: *const c_char,
    replacement: *const c_char,
    offset: usize,
    limit: usize,
    output: *mut c_char,
    output_capacity: usize,
) -> i32 {
    let (Ok(worktree_root), Ok(tool), Ok(path), Ok(value), Ok(replacement)) = (
        c_string(worktree_root),
        c_string(tool),
        c_string(path),
        c_string(value),
        c_string(replacement),
    ) else {
        return AgentToolOperationStatus::InvalidInput as i32;
    };

    let request = match tool.as_str() {
        "read" => AgentToolRequest::Read {
            path: &path,
            offset,
            limit,
        },
        "list" | "ls" => AgentToolRequest::List { path: &value },
        "glob" | "find" => AgentToolRequest::Glob { pattern: &value },
        "grep" => AgentToolRequest::Grep { pattern: &value },
        "write" => AgentToolRequest::Write {
            path: &path,
            content: &value,
        },
        "edit" => AgentToolRequest::Edit {
            path: &path,
            old_text: &value,
            new_text: &replacement,
        },
        "apply_patch" => AgentToolRequest::ApplyPatch { patch: &value },
        "shell" | "bash" => AgentToolRequest::Shell { command: &value },
        "git_status" => AgentToolRequest::GitStatus,
        "git_diff" => AgentToolRequest::GitDiff,
        "ask_user" => AgentToolRequest::AskUser { question: &value },
        _ => return AgentToolOperationStatus::InvalidInput as i32,
    };

    match execute_agent_tool(Path::new(&worktree_root), request) {
        Ok(AgentToolResult::Output(result)) => {
            match write_c_string(&result, output, output_capacity) {
                Ok(()) => AgentToolOperationStatus::Success as i32,
                Err(()) => AgentToolOperationStatus::OutputBufferTooSmall as i32,
            }
        }
        Ok(AgentToolResult::NeedsUserInput(question)) => {
            match write_c_string(&question, output, output_capacity) {
                Ok(()) => AgentToolOperationStatus::NeedsUserInput as i32,
                Err(()) => AgentToolOperationStatus::OutputBufferTooSmall as i32,
            }
        }
        Err(error) => match write_c_string(&format!("{error:?}"), output, output_capacity) {
            Ok(()) => AgentToolOperationStatus::Failed as i32,
            Err(()) => AgentToolOperationStatus::OutputBufferTooSmall as i32,
        },
    }
}

/// Writes the persisted inference-provider connections as JSON for a native client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_inference_provider_connections(
    storage_directory: *const c_char,
    output: *mut c_char,
    output_capacity: usize,
) -> i32 {
    let Ok(storage_directory) = c_string(storage_directory) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let connections = match inference_provider_connections_json(Path::new(&storage_directory)) {
        Ok(connections) => connections,
        Err(error) => return InferenceProviderStoreStatus::from_error(error) as i32,
    };

    match write_c_string(&connections, output, output_capacity) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(()) => InferenceProviderStoreStatus::OutputBufferTooSmall as i32,
    }
}

/// Persists an inference-provider connection state without persisting a secret.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_save_inference_provider_connection(
    storage_directory: *const c_char,
    provider: *const c_char,
    state: *const c_char,
) -> i32 {
    let (Ok(storage_directory), Ok(provider), Ok(state)) = (
        c_string(storage_directory),
        c_string(provider),
        c_string(state),
    ) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let (Some(provider), Some(state)) = (
        InferenceProvider::from_identifier(&provider),
        InferenceProviderConnectionState::from_identifier(&state),
    ) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };

    match save_inference_provider_connection(Path::new(&storage_directory), provider, state) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(error) => InferenceProviderStoreStatus::from_error(error) as i32,
    }
}

/// Removes a persisted inference-provider connection.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_remove_inference_provider_connection(
    storage_directory: *const c_char,
    provider: *const c_char,
) -> i32 {
    let (Ok(storage_directory), Ok(provider)) = (c_string(storage_directory), c_string(provider))
    else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let Some(provider) = InferenceProvider::from_identifier(&provider) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };

    match remove_inference_provider_connection(Path::new(&storage_directory), provider) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(error) => InferenceProviderStoreStatus::from_error(error) as i32,
    }
}

/// Writes persisted inference accounts as JSON for a native client.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_inference_accounts(
    storage_directory: *const c_char,
    output: *mut c_char,
    output_capacity: usize,
) -> i32 {
    let Ok(storage_directory) = c_string(storage_directory) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let accounts = match inference_accounts_json(Path::new(&storage_directory)) {
        Ok(accounts) => accounts,
        Err(error) => return InferenceProviderStoreStatus::from_error(error) as i32,
    };
    match write_c_string(&accounts, output, output_capacity) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(()) => InferenceProviderStoreStatus::OutputBufferTooSmall as i32,
    }
}

/// Persists an inference account without ever receiving its credential.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_save_inference_account(
    storage_directory: *const c_char,
    account_id: *const c_char,
    provider: *const c_char,
    name: *const c_char,
    state: *const c_char,
) -> i32 {
    let (Ok(storage_directory), Ok(account_id), Ok(provider), Ok(name), Ok(state)) = (
        c_string(storage_directory),
        c_string(account_id),
        c_string(provider),
        c_string(name),
        c_string(state),
    ) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let (Some(provider), Some(state)) = (
        InferenceProvider::from_identifier(&provider),
        InferenceProviderConnectionState::from_identifier(&state),
    ) else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    let account = InferenceAccount {
        id: account_id,
        provider,
        name,
        state,
    };
    match save_inference_account(Path::new(&storage_directory), account) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(error) => InferenceProviderStoreStatus::from_error(error) as i32,
    }
}

/// Removes an inference account from the cross-platform registry.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tuist_code_remove_inference_account(
    storage_directory: *const c_char,
    account_id: *const c_char,
) -> i32 {
    let (Ok(storage_directory), Ok(account_id)) =
        (c_string(storage_directory), c_string(account_id))
    else {
        return InferenceProviderStoreStatus::InvalidInput as i32;
    };
    match remove_inference_account(Path::new(&storage_directory), &account_id) {
        Ok(()) => InferenceProviderStoreStatus::Success as i32,
        Err(error) => InferenceProviderStoreStatus::from_error(error) as i32,
    }
}

/// Exposes the shared authentication state machine to Apple application code.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_authentication_state_after(state: i32, event: i32) -> i32 {
    let state = AuthenticationState::from_raw(state).unwrap_or(AuthenticationState::SignedOut);
    let Some(event) = AuthenticationEvent::from_raw(event) else {
        return state as i32;
    };
    authentication_state_after(state, event) as i32
}

/// Exposes cross-platform capability availability to native application code.
#[unsafe(no_mangle)]
pub extern "C" fn tuist_code_capability_is_available(state: i32, capability: i32) -> i32 {
    let authentication_state =
        AuthenticationState::from_raw(state).unwrap_or(AuthenticationState::SignedOut);
    let Some(capability) = ProductCapability::from_raw(capability) else {
        return 0;
    };
    is_capability_available(authentication_state, capability) as i32
}

fn c_string(pointer: *const c_char) -> Result<String, ProjectOperationError> {
    if pointer.is_null() {
        return Err(ProjectOperationError::InvalidInput);
    }

    // SAFETY: The client supplies a non-null pointer to a NUL-terminated C string.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| ProjectOperationError::InvalidInput)
}

fn write_c_string(value: &str, output: *mut c_char, capacity: usize) -> Result<(), ()> {
    if output.is_null() || value.len() + 1 > capacity {
        return Err(());
    }

    // SAFETY: The caller guarantees that `output` points to writable memory with `capacity` bytes.
    let output = unsafe { std::slice::from_raw_parts_mut(output.cast::<u8>(), capacity) };
    output[..value.len()].copy_from_slice(value.as_bytes());
    output[value.len()] = 0;
    Ok(())
}

/// Exposes the primary brand colour to Android application code.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_tuist_code_MainActivity_brandColor(
    _environment: *mut core::ffi::c_void,
    _instance: *mut core::ffi::c_void,
) -> i32 {
    brand_color() as i32
}

/// Exposes the shared authentication state machine to Android application code.
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_tuist_code_MainActivity_authenticationStateAfter(
    _environment: *mut core::ffi::c_void,
    _instance: *mut core::ffi::c_void,
    state: i32,
    event: i32,
) -> i32 {
    tuist_code_authentication_state_after(state, event)
}
