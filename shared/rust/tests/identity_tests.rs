use tuist_code_shared::agent::{
    AgentEvent, AgentInteraction, AgentMessage, AgentModel, AgentModelRequest, AgentModelResponse,
    AgentRunConfiguration, AgentToolCall, AgentToolInput, run_agent,
};
use tuist_code_shared::{
    APP_NAME, AgentTool, AgentToolError, AgentToolRequest, AgentToolResult, AuthenticationEvent,
    AuthenticationState, BRAND_COLOR, InferenceAccount, InferenceProvider,
    InferenceProviderConnectionState, InferenceProviderStoreError, ProductCapability,
    ProjectOperationError, WorktreeOperationError, agent_tool_catalog_json, agent_tools, app_name,
    authentication_state_after, brand_color, clone_repository, create_default_session_worktree,
    create_worktree, execute_agent_tool, inference_provider_catalog, is_capability_available,
    is_git_repository, load_inference_accounts, load_inference_provider_connections,
    project_name_from_remote, remove_inference_provider_connection, rename_session_worktree,
    save_inference_account, save_inference_provider_connection, worktree_directory_name,
};

#[derive(Default)]
struct ScriptedAgentModel {
    responses: Vec<AgentModelResponse>,
    requests: Vec<AgentModelRequest>,
}

impl AgentModel for ScriptedAgentModel {
    type Error = String;

    fn complete(&mut self, request: &AgentModelRequest) -> Result<AgentModelResponse, Self::Error> {
        self.requests.push(request.clone());
        if self.responses.is_empty() {
            return Err("No scripted response is available.".to_owned());
        }
        Ok(self.responses.remove(0))
    }
}

struct ApproveAgentMutations;

impl AgentInteraction for ApproveAgentMutations {
    fn approve(&mut self, _call: &AgentToolCall) -> bool {
        true
    }

    fn answer(&mut self, _question: &str) -> Option<String> {
        Some("Yes".to_owned())
    }
}

#[test]
fn shares_the_product_name() {
    assert_eq!(app_name(), APP_NAME);
    assert_eq!(APP_NAME, "Tuist Code");
}

#[test]
fn shares_the_tuist_brand_colour() {
    assert_eq!(brand_color(), BRAND_COLOR);
    assert_eq!(BRAND_COLOR, 0x6F2CFF);
}

#[test]
fn persists_provider_connection_mechanics_without_credentials() {
    let storage_directory = std::env::temp_dir().join(format!(
        "tuist-code-provider-store-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&storage_directory);

    assert_eq!(inference_provider_catalog().len(), 3);
    assert!(
        load_inference_provider_connections(&storage_directory)
            .unwrap()
            .is_empty()
    );

    save_inference_provider_connection(
        &storage_directory,
        InferenceProvider::Together,
        InferenceProviderConnectionState::Configured,
    )
    .unwrap();
    save_inference_provider_connection(
        &storage_directory,
        InferenceProvider::Codex,
        InferenceProviderConnectionState::Authorizing,
    )
    .unwrap();

    let connections = load_inference_provider_connections(&storage_directory).unwrap();
    assert_eq!(connections.len(), 2);
    assert!(connections.iter().any(|connection| {
        connection.provider == InferenceProvider::Together
            && connection.state == InferenceProviderConnectionState::Configured
    }));
    assert!(connections.iter().any(|connection| {
        connection.provider == InferenceProvider::Codex
            && connection.state == InferenceProviderConnectionState::Authorizing
    }));

    assert_eq!(
        save_inference_provider_connection(
            &storage_directory,
            InferenceProvider::Fireworks,
            InferenceProviderConnectionState::Authorizing,
        )
        .unwrap_err(),
        InferenceProviderStoreError::InvalidInput
    );

    remove_inference_provider_connection(&storage_directory, InferenceProvider::Together).unwrap();
    assert_eq!(
        load_inference_provider_connections(&storage_directory)
            .unwrap()
            .len(),
        1
    );
    std::fs::remove_dir_all(storage_directory).unwrap();
}

#[test]
fn persists_named_accounts_and_migrates_legacy_provider_connections() {
    let storage_directory = std::env::temp_dir().join(format!(
        "tuist-code-account-store-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&storage_directory);

    save_inference_provider_connection(
        &storage_directory,
        InferenceProvider::Codex,
        InferenceProviderConnectionState::Configured,
    )
    .unwrap();
    let migrated = load_inference_accounts(&storage_directory).unwrap();
    assert_eq!(migrated.len(), 1);
    assert_eq!(migrated[0].id, "legacy-codex");

    save_inference_account(
        &storage_directory,
        InferenceAccount {
            id: "personal-together".to_owned(),
            provider: InferenceProvider::Together,
            name: "Personal Together".to_owned(),
            state: InferenceProviderConnectionState::Configured,
        },
    )
    .unwrap();
    save_inference_account(
        &storage_directory,
        InferenceAccount {
            id: "work-together".to_owned(),
            provider: InferenceProvider::Together,
            name: "Work Together".to_owned(),
            state: InferenceProviderConnectionState::Configured,
        },
    )
    .unwrap();

    let accounts = load_inference_accounts(&storage_directory).unwrap();
    assert_eq!(accounts.len(), 3);
    assert_eq!(
        accounts
            .iter()
            .filter(|account| account.provider == InferenceProvider::Together)
            .count(),
        2
    );
    std::fs::remove_dir_all(storage_directory).unwrap();
}

#[test]
fn starts_sign_in_from_signed_out_or_failed() {
    assert_eq!(
        authentication_state_after(
            AuthenticationState::SignedOut,
            AuthenticationEvent::StartSignIn
        ),
        AuthenticationState::Authenticating
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Failed,
            AuthenticationEvent::StartSignIn
        ),
        AuthenticationState::Authenticating
    );
}

#[test]
fn completes_or_cancels_only_an_active_sign_in() {
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticating,
            AuthenticationEvent::SignInSucceeded,
        ),
        AuthenticationState::Authenticated
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticating,
            AuthenticationEvent::Cancelled
        ),
        AuthenticationState::SignedOut
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::SignedOut,
            AuthenticationEvent::SignInSucceeded
        ),
        AuthenticationState::SignedOut
    );
}

#[test]
fn restores_and_signs_out_deterministically() {
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticating,
            AuthenticationEvent::RestoreAuthenticated,
        ),
        AuthenticationState::Authenticated
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticated,
            AuthenticationEvent::RestoreUnauthenticated,
        ),
        AuthenticationState::SignedOut
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticated,
            AuthenticationEvent::SignOut
        ),
        AuthenticationState::SignedOut
    );
}

#[test]
fn records_failures_from_any_platform_step() {
    assert_eq!(
        authentication_state_after(
            AuthenticationState::SignedOut,
            AuthenticationEvent::SignInFailed
        ),
        AuthenticationState::Failed
    );
    assert_eq!(
        authentication_state_after(
            AuthenticationState::Authenticating,
            AuthenticationEvent::SignInFailed,
        ),
        AuthenticationState::Failed
    );
}

#[test]
fn keeps_local_capabilities_available_without_an_account() {
    assert!(is_capability_available(
        AuthenticationState::SignedOut,
        ProductCapability::LocalProjects
    ));
    assert!(is_capability_available(
        AuthenticationState::Failed,
        ProductCapability::LocalSessions
    ));
}

#[test]
fn requires_an_authenticated_tuist_account_for_remote_capabilities() {
    assert!(!is_capability_available(
        AuthenticationState::SignedOut,
        ProductCapability::RemoteSessions
    ));
    assert!(!is_capability_available(
        AuthenticationState::Authenticating,
        ProductCapability::RemoteBuilds
    ));
    assert!(is_capability_available(
        AuthenticationState::Authenticated,
        ProductCapability::RemoteSessions
    ));
    assert!(is_capability_available(
        AuthenticationState::Authenticated,
        ProductCapability::RemoteBuilds
    ));
}

#[test]
fn recognises_git_repositories_by_their_git_marker() {
    let repository =
        std::env::temp_dir().join(format!("tuist-code-repository-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&repository);
    std::fs::create_dir_all(&repository).unwrap();

    assert!(!is_git_repository(&repository));

    std::fs::create_dir(repository.join(".git")).unwrap();
    assert!(is_git_repository(&repository));

    std::fs::remove_dir_all(repository).unwrap();
}

#[test]
fn derives_project_names_from_https_and_ssh_remotes() {
    assert_eq!(
        project_name_from_remote("https://github.com/tuist/code.git").unwrap(),
        "code"
    );
    assert_eq!(
        project_name_from_remote("git@github.com:tuist/code.git").unwrap(),
        "code"
    );
    assert_eq!(
        project_name_from_remote("https://github.com/tuist/code/").unwrap(),
        "code"
    );
    assert_eq!(
        project_name_from_remote("/").unwrap_err(),
        ProjectOperationError::InvalidInput
    );
}

#[test]
fn clones_a_repository_into_a_destination_directory() {
    let fixture_root =
        std::env::temp_dir().join(format!("tuist-code-clone-test-{}", std::process::id()));
    let source = fixture_root.join("source.git");
    let destination_parent = fixture_root.join("destination");
    let _ = std::fs::remove_dir_all(&fixture_root);
    std::fs::create_dir_all(&destination_parent).unwrap();

    let initialize_source = std::process::Command::new("git")
        .args(["init", "--bare"])
        .arg(&source)
        .status()
        .unwrap();
    assert!(initialize_source.success());

    let clone = clone_repository(source.to_str().unwrap(), &destination_parent).unwrap();
    assert_eq!(clone, destination_parent.join("source"));
    assert!(is_git_repository(&clone));

    std::fs::remove_dir_all(fixture_root).unwrap();
}

#[test]
fn derives_safe_worktree_directory_names() {
    assert_eq!(
        worktree_directory_name("feature/session").unwrap(),
        "feature-session"
    );
    assert_eq!(
        worktree_directory_name("feature..session").unwrap_err(),
        WorktreeOperationError::InvalidInput
    );
}

#[test]
fn creates_a_worktree_for_a_new_session_branch() {
    let fixture_root =
        std::env::temp_dir().join(format!("tuist-code-worktree-test-{}", std::process::id()));
    let repository = fixture_root.join("repository");
    let destination_parent = fixture_root.join("sessions");
    let _ = std::fs::remove_dir_all(&fixture_root);
    std::fs::create_dir_all(&destination_parent).unwrap();

    let initialize_repository = std::process::Command::new("git")
        .arg("init")
        .arg(&repository)
        .status()
        .unwrap();
    assert!(initialize_repository.success());

    let initial_commit = std::process::Command::new("git")
        .args([
            "-C",
            repository.to_str().unwrap(),
            "-c",
            "user.name=Tuist Code",
            "-c",
            "user.email=tuist-code@example.com",
            "commit",
            "--allow-empty",
            "--message",
            "Initial commit",
        ])
        .status()
        .unwrap();
    assert!(initial_commit.success());

    let worktree = create_worktree(&repository, "feature/session", &destination_parent).unwrap();
    assert_eq!(worktree, destination_parent.join("feature-session"));
    assert!(is_git_repository(&worktree));

    let remove_worktree = std::process::Command::new("git")
        .args([
            "-C",
            repository.to_str().unwrap(),
            "worktree",
            "remove",
            "--force",
        ])
        .arg(&worktree)
        .status()
        .unwrap();
    assert!(remove_worktree.success());
    std::fs::remove_dir_all(fixture_root).unwrap();
}

#[test]
fn creates_and_renames_an_immediate_session_worktree() {
    let fixture_root = std::env::temp_dir().join(format!(
        "tuist-code-default-session-test-{}",
        std::process::id()
    ));
    let repository = fixture_root.join("repository");
    let _ = std::fs::remove_dir_all(&fixture_root);

    let initialize_repository = std::process::Command::new("git")
        .arg("init")
        .arg(&repository)
        .status()
        .unwrap();
    assert!(initialize_repository.success());

    let initial_commit = std::process::Command::new("git")
        .args([
            "-C",
            repository.to_str().unwrap(),
            "-c",
            "user.name=Tuist Code",
            "-c",
            "user.email=tuist-code@example.com",
            "commit",
            "--allow-empty",
            "--message",
            "Initial commit",
        ])
        .status()
        .unwrap();
    assert!(initial_commit.success());

    let worktree = create_default_session_worktree(&repository).unwrap();
    assert!(is_git_repository(&worktree));
    assert_eq!(
        worktree.parent().unwrap(),
        fixture_root
            .join(".tuist-code-worktrees")
            .join("repository")
    );

    let renamed_worktree = rename_session_worktree(
        &repository,
        &worktree,
        "Build the session screen",
        "build-session-screen",
    )
    .unwrap();
    assert_eq!(
        renamed_worktree,
        fixture_root
            .join(".tuist-code-worktrees")
            .join("repository")
            .join("build-session-screen")
    );
    assert!(!worktree.exists());
    assert!(is_git_repository(&renamed_worktree));

    let remove_worktree = std::process::Command::new("git")
        .args([
            "-C",
            repository.to_str().unwrap(),
            "worktree",
            "remove",
            "--force",
        ])
        .arg(&renamed_worktree)
        .status()
        .unwrap();
    assert!(remove_worktree.success());
    std::fs::remove_dir_all(fixture_root).unwrap();
}

#[test]
fn shares_a_coding_agent_tool_contract_with_explicit_mutation_rules() {
    let tools = agent_tools();
    assert!(tools.contains(&AgentTool::Read));
    assert!(tools.contains(&AgentTool::Ls));
    assert!(tools.contains(&AgentTool::Grep));
    assert!(tools.contains(&AgentTool::ApplyPatch));
    assert!(tools.contains(&AgentTool::Shell));
    assert!(AgentTool::Write.requires_approval());
    assert!(AgentTool::Shell.requires_approval());
    assert!(AgentTool::Bash.requires_approval());
    assert!(!AgentTool::Read.requires_approval());
    assert!(agent_tool_catalog_json().contains("\"name\":\"ask_user\""));
}

#[test]
fn executes_shared_file_tools_only_inside_the_session_worktree() {
    let fixture_root =
        std::env::temp_dir().join(format!("tuist-code-agent-tool-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&fixture_root);
    std::fs::create_dir_all(&fixture_root).unwrap();

    assert_eq!(
        execute_agent_tool(
            &fixture_root,
            AgentToolRequest::Write {
                path: "Sources/example.txt",
                content: "first line\nfind me",
            },
        )
        .unwrap(),
        AgentToolResult::Output("File written.".to_owned())
    );
    assert_eq!(
        execute_agent_tool(
            &fixture_root,
            AgentToolRequest::Read {
                path: "Sources/example.txt",
                offset: 1,
                limit: 20,
            },
        )
        .unwrap(),
        AgentToolResult::Output("find me".to_owned())
    );
    assert!(matches!(
        execute_agent_tool(
            &fixture_root,
            AgentToolRequest::Grep { pattern: "find" },
        )
        .unwrap(),
        AgentToolResult::Output(output) if output.contains("Sources/example.txt:2:find me")
    ));
    assert_eq!(
        execute_agent_tool(
            &fixture_root,
            AgentToolRequest::Read {
                path: "../outside.txt",
                offset: 0,
                limit: 20,
            },
        )
        .unwrap_err(),
        AgentToolError::InvalidPath
    );

    std::fs::remove_dir_all(fixture_root).unwrap();
}

#[test]
fn runs_the_agent_loop_headlessly_with_rust_owning_history_and_tool_execution() {
    let fixture_root =
        std::env::temp_dir().join(format!("tuist-code-agent-loop-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&fixture_root);
    std::fs::create_dir_all(&fixture_root).unwrap();

    let mut model = ScriptedAgentModel {
        responses: vec![
            AgentModelResponse {
                content: Some("I will create the requested note.".to_owned()),
                tool_calls: vec![AgentToolCall {
                    id: "write-note".to_owned(),
                    input: AgentToolInput::Write {
                        path: "notes.txt".to_owned(),
                        content: "Created by the Rust agent loop.\n".to_owned(),
                    },
                }],
            },
            AgentModelResponse {
                content: Some("The note is ready.".to_owned()),
                tool_calls: vec![],
            },
        ],
        ..Default::default()
    };
    let mut interaction = ApproveAgentMutations;
    let mut events = Vec::new();

    let messages = run_agent(
        AgentRunConfiguration::new(&fixture_root, "You are a coding agent.", "Create a note."),
        &mut model,
        &mut interaction,
        |event| events.push(event),
    )
    .unwrap();

    assert_eq!(model.requests.len(), 2);
    assert!(matches!(
        model.requests[1].messages.last(),
        Some(AgentMessage::Tool { call_id, content })
            if call_id == "write-note" && content == "File written."
    ));
    assert_eq!(
        std::fs::read_to_string(fixture_root.join("notes.txt")).unwrap(),
        "Created by the Rust agent loop.\n"
    );
    assert!(events.contains(&AgentEvent::ApprovalRequested {
        tool: AgentTool::Write,
        summary: "notes.txt".to_owned(),
    }));
    assert!(events.contains(&AgentEvent::ToolCompleted {
        tool: AgentTool::Write,
        output: "File written.".to_owned(),
    }));
    assert!(events.contains(&AgentEvent::Completed));

    std::fs::remove_dir_all(fixture_root).unwrap();
}
