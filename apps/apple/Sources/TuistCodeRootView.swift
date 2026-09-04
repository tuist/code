import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

#if os(macOS)
import AppKit
#endif

@_silgen_name("tuist_code_app_name")
private func tuistCodeAppName() -> UnsafePointer<CChar>

@_silgen_name("tuist_code_authentication_state_after")
private func tuistCodeAuthenticationStateAfter(_ state: Int32, _ event: Int32) -> Int32

@_silgen_name("tuist_code_capability_is_available")
private func tuistCodeCapabilityIsAvailable(_ state: Int32, _ capability: Int32) -> Int32

@_silgen_name("tuist_code_validate_git_repository")
private func tuistCodeValidateGitRepository(_ directoryPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("tuist_code_clone_git_repository")
private func tuistCodeCloneGitRepository(
    _ remote: UnsafePointer<CChar>,
    _ destinationParent: UnsafePointer<CChar>,
    _ outputPath: UnsafeMutablePointer<CChar>,
    _ outputPathCapacity: Int
) -> Int32

@_silgen_name("tuist_code_create_default_session_worktree")
private func tuistCodeCreateDefaultSessionWorktree(
    _ repository: UnsafePointer<CChar>,
    _ outputPath: UnsafeMutablePointer<CChar>,
    _ outputPathCapacity: Int
) -> Int32

@_silgen_name("tuist_code_rename_session_worktree")
private func tuistCodeRenameSessionWorktree(
    _ repository: UnsafePointer<CChar>,
    _ currentWorktree: UnsafePointer<CChar>,
    _ sessionTitle: UnsafePointer<CChar>,
    _ newWorktreeName: UnsafePointer<CChar>,
    _ outputPath: UnsafeMutablePointer<CChar>,
    _ outputPathCapacity: Int
) -> Int32

@_silgen_name("tuist_code_inference_provider_catalog")
private func tuistCodeInferenceProviderCatalog(
    _ output: UnsafeMutablePointer<CChar>,
    _ outputCapacity: Int
) -> Int32

@_silgen_name("tuist_code_inference_provider_connections")
private func tuistCodeInferenceProviderConnections(
    _ storageDirectory: UnsafePointer<CChar>,
    _ output: UnsafeMutablePointer<CChar>,
    _ outputCapacity: Int
) -> Int32

@_silgen_name("tuist_code_save_inference_provider_connection")
private func tuistCodeSaveInferenceProviderConnection(
    _ storageDirectory: UnsafePointer<CChar>,
    _ provider: UnsafePointer<CChar>,
    _ state: UnsafePointer<CChar>
) -> Int32

@_silgen_name("tuist_code_remove_inference_provider_connection")
private func tuistCodeRemoveInferenceProviderConnection(
    _ storageDirectory: UnsafePointer<CChar>,
    _ provider: UnsafePointer<CChar>
) -> Int32

@_silgen_name("tuist_code_inference_accounts")
private func tuistCodeInferenceAccounts(
    _ storageDirectory: UnsafePointer<CChar>,
    _ output: UnsafeMutablePointer<CChar>,
    _ outputCapacity: Int
) -> Int32

@_silgen_name("tuist_code_save_inference_account")
private func tuistCodeSaveInferenceAccount(
    _ storageDirectory: UnsafePointer<CChar>,
    _ accountID: UnsafePointer<CChar>,
    _ provider: UnsafePointer<CChar>,
    _ name: UnsafePointer<CChar>,
    _ state: UnsafePointer<CChar>
) -> Int32

@_silgen_name("tuist_code_remove_inference_account")
private func tuistCodeRemoveInferenceAccount(
    _ storageDirectory: UnsafePointer<CChar>,
    _ accountID: UnsafePointer<CChar>
) -> Int32

@_silgen_name("tuist_code_agent_tool_requires_approval")
private func tuistCodeAgentToolRequiresApproval(_ tool: UnsafePointer<CChar>) -> Int32

@_silgen_name("tuist_code_execute_agent_tool")
private func tuistCodeExecuteAgentTool(
    _ worktreeRoot: UnsafePointer<CChar>,
    _ tool: UnsafePointer<CChar>,
    _ path: UnsafePointer<CChar>,
    _ value: UnsafePointer<CChar>,
    _ replacement: UnsafePointer<CChar>,
    _ offset: Int,
    _ limit: Int,
    _ output: UnsafeMutablePointer<CChar>,
    _ outputCapacity: Int
) -> Int32

struct TuistCodeRootView: View {
    @StateObject private var authentication = AuthenticationService()
    @Environment(\.tuistCodeTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private let name = String(cString: tuistCodeAppName())

    private var palette: TuistCodeThemePalette {
        theme.palette(for: colorScheme)
    }

    var body: some View {
        WorkspaceHarnessView(
            name: name,
            origin: authentication.configuration.origin,
            authenticationState: authentication.state,
            authenticationErrorMessage: authentication.errorMessage,
            connectToTuist: authentication.signIn,
            signOut: authentication.signOut
        )
        .tint(palette.accent)
    }
}

private struct WorkspaceHarnessView: View {
    let name: String
    let origin: URL
    let authenticationState: AuthenticationState
    let authenticationErrorMessage: String?
    let connectToTuist: () -> Void
    let signOut: () -> Void

    @EnvironmentObject private var inferenceAccounts: InferenceAccountStore
    @EnvironmentObject private var agentRuntime: AgentSessionRuntimeStore
    @StateObject private var workspaceStore = WorkspaceStore()
    @State private var selectedWorkspaceID: Workspace.ID?
    @State private var selectedProjectIDs = [Workspace.ID: LocalProject.ID]()
    @State private var selectedNavigationItem: WorkspaceNavigationItem?
    @State private var expandedWorkspaceIDs = Set<Workspace.ID>()
    @State private var expandedProjectIDs = Set<LocalProject.ID>()
    @State private var isAddingWorkspace = false
    @State private var isCloningRepository = false
    @State private var cloneDestinationWorkspaceID: Workspace.ID?
    @State private var activeSessionTarget: AgentSessionTarget?
    @State private var sessionPendingDeletion: AgentSessionTarget?

    private var selectedWorkspace: Workspace? {
        workspaceStore.workspaces.first(where: { $0.id == selectedWorkspaceID })
    }

    private var selectedProjectID: LocalProject.ID? {
        guard let selectedWorkspaceID else { return nil }
        return selectedProjectIDs[selectedWorkspaceID]
    }

    private var selectedProject: LocalProject? {
        selectedWorkspace?.projects.first(where: { $0.id == selectedProjectID })
    }

    private var activeWorktreeSession: (worktree: ProjectWorktree, session: AgentSession)? {
        guard let activeSessionTarget,
              activeSessionTarget.workspaceID == selectedWorkspaceID,
              activeSessionTarget.projectID == selectedProjectID
        else {
            return nil
        }
        guard let worktree = selectedProject?.worktrees.first(where: { $0.id == activeSessionTarget.worktreeID }),
              let session = worktree.sessions.first(where: { $0.id == activeSessionTarget.sessionID })
        else {
            return nil
        }
        return (worktree, session)
    }

    private var remoteSessionsAreAvailable: Bool {
        SharedCapabilityService.remoteSessionsAreAvailable(for: authenticationState)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedNavigationItem) {
                Section("Workspaces") {
                    ForEach(workspaceStore.workspaces) { workspace in
                        DisclosureGroup(
                            isExpanded: workspaceExpansionBinding(for: workspace.id)
                        ) {
                            ForEach(workspace.projects) { project in
                                DisclosureGroup(
                                    isExpanded: projectExpansionBinding(for: project.id)
                                ) {
                                    if project.worktrees.isEmpty {
                                        Text("No sessions")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(project.worktrees) { worktree in
                                            if worktree.sessions.isEmpty {
                                                Button {
                                                    createAdditionalSession(
                                                        in: worktree,
                                                        for: project,
                                                        workspaceID: workspace.id
                                                    )
                                                } label: {
                                                    Label("New Session", systemImage: "plus")
                                                }
                                                .buttonStyle(.plain)
                                                .help("Start a new session in \(worktree.name)")
                                            } else {
                                                ForEach(worktree.sessions) { session in
                                                    let target = AgentSessionTarget(
                                                        workspaceID: workspace.id,
                                                        projectID: project.id,
                                                        worktreeID: worktree.id,
                                                        sessionID: session.id
                                                    )
                                                    Label(session.title, systemImage: "sparkles")
                                                        .help("Worktree: \(worktree.name)")
                                                        .tag(
                                                            WorkspaceNavigationItem.session(
                                                                workspaceID: workspace.id,
                                                                projectID: project.id,
                                                                worktreeID: worktree.id,
                                                                sessionID: session.id
                                                            )
                                                        )
                                                        .contextMenu {
                                                            Button(
                                                                "Delete Session",
                                                                systemImage: "trash",
                                                                role: .destructive
                                                            ) {
                                                                requestSessionDeletion(target)
                                                            }
                                                        }
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Label(project.name, systemImage: "folder")
                                }
                                .tag(
                                    WorkspaceNavigationItem.project(
                                        workspaceID: workspace.id,
                                        projectID: project.id
                                    )
                                )
                            }
                        } label: {
                            Label(workspace.name, systemImage: "square.stack.3d.up")
                        }
                        .tag(WorkspaceNavigationItem.workspace(workspace.id))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(name)
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            #if os(macOS)
            .onDeleteCommand {
                deleteSelectedSession()
            }
            #endif
        } detail: {
            if let project = selectedProject, let activeWorktreeSession {
                AgentSessionView(
                    project: project,
                    worktree: activeWorktreeSession.worktree,
                    session: activeWorktreeSession.session,
                    close: {
                        activeSessionTarget = nil
                        if let selectedWorkspaceID {
                            selectedNavigationItem = .project(
                                workspaceID: selectedWorkspaceID,
                                projectID: project.id
                            )
                        }
                    },
                    newSession: {
                        createAdditionalSession(in: activeWorktreeSession.worktree, for: project)
                    },
                    start: { prompt, configuration in
                        startAgentSession(
                            with: prompt,
                            configuration: configuration,
                            for: activeWorktreeSession.session
                        )
                    }
                )
            } else {
                ProjectSessionsView(
                    project: selectedProject,
                    createWorktree: createNewWorktree,
                    remoteSessionsAreAvailable: remoteSessionsAreAvailable
                )
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Workspace") {
                        isAddingWorkspace = true
                    }

                    if let selectedWorkspace {
                        Divider()

                        Button("Add Local Repository") {
                            addLocalProject(to: selectedWorkspace.id)
                        }
                        Button("Clone Repository") {
                            presentCloneRepository(in: selectedWorkspace.id)
                        }
                    }
                } label: {
                    Label("Add Workspace or Project", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    if authenticationState == .authenticated {
                        Label("Connected to Tuist", systemImage: "checkmark.circle.fill")
                        Text(origin.host() ?? origin.absoluteString)
                        Divider()
                        Button("Sign out", role: .destructive, action: signOut)
                        Divider()
                    } else {
                        Text("Work locally without an account.")
                        Button("Connect to Tuist", action: connectToTuist)
                            .disabled(authenticationState == .authenticating)
                            .accessibilityIdentifier("tuist-login-button")
                        Text("Connect to unlock remote sessions and remote builds.")
                        if authenticationState == .authenticating {
                            ProgressView("Connecting to Tuist")
                        }
                        if let authenticationErrorMessage {
                            Text(authenticationErrorMessage)
                        }
                    }
                } label: {
                    Label(
                        authenticationState == .authenticated ? "Account" : "Connect to Tuist",
                        systemImage: authenticationState == .authenticated
                            ? "person.crop.circle"
                            : "person.crop.circle.badge.plus"
                    )
                }
            }
        }
        .onAppear {
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = workspaceStore.workspaces.first?.id
            }
            if let selectedWorkspaceID {
                selectedNavigationItem = .workspace(selectedWorkspaceID)
                expandedWorkspaceIDs.insert(selectedWorkspaceID)
            }
        }
        .onChange(of: selectedNavigationItem) { _, item in
            guard let item else { return }

            switch item {
            case let .workspace(workspaceID):
                activeSessionTarget = nil
                selectedWorkspaceID = workspaceID
                expandedWorkspaceIDs.insert(workspaceID)
            case let .project(workspaceID, projectID):
                activeSessionTarget = nil
                selectedWorkspaceID = workspaceID
                selectedProjectIDs[workspaceID] = projectID
                expandedWorkspaceIDs.insert(workspaceID)
                expandedProjectIDs.insert(projectID)
            case let .session(workspaceID, projectID, worktreeID, sessionID):
                selectedWorkspaceID = workspaceID
                selectedProjectIDs[workspaceID] = projectID
                expandedWorkspaceIDs.insert(workspaceID)
                expandedProjectIDs.insert(projectID)
                activeSessionTarget = AgentSessionTarget(
                    workspaceID: workspaceID,
                    projectID: projectID,
                    worktreeID: worktreeID,
                    sessionID: sessionID
                )
            }
        }
        .sheet(isPresented: $isAddingWorkspace) {
            NewWorkspaceSheet { name in
                let workspace = workspaceStore.addWorkspace(named: name)
                selectedWorkspaceID = workspace.id
                selectedNavigationItem = .workspace(workspace.id)
                expandedWorkspaceIDs.insert(workspace.id)
            }
        }
        .sheet(isPresented: $isCloningRepository, onDismiss: {
            cloneDestinationWorkspaceID = nil
        }) {
            CloneRepositorySheet { remote, destinationParent in
                guard let workspaceID = cloneDestinationWorkspaceID else { return false }
                return cloneRepository(remote, into: destinationParent, in: workspaceID)
            }
        }
        .alert(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionPendingDeletion = nil
                    }
                }
            ),
            presenting: sessionPendingDeletion
        ) { target in
            Button("Delete", role: .destructive) {
                deleteSession(target)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(sessionDeletionMessage(for: target))
        }
        .alert(
            "Unable to complete request",
            isPresented: Binding(
                get: { workspaceStore.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        workspaceStore.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                workspaceStore.errorMessage = nil
            }
        } message: {
            Text(workspaceStore.errorMessage ?? "")
        }
    }

    private func addLocalProject(to workspaceID: Workspace.ID) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Add Local Repository"
        panel.message = "Choose a folder that contains a Git repository."
        panel.prompt = "Add Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        guard let project = workspaceStore.addLocalProject(at: directoryURL, to: workspaceID) else {
            return
        }
        selectedProjectIDs[workspaceID] = project.id
        selectedNavigationItem = .project(workspaceID: workspaceID, projectID: project.id)
        expandedWorkspaceIDs.insert(workspaceID)
        expandedProjectIDs.insert(project.id)
        #else
        workspaceStore.errorMessage = "Adding local repositories is available in the macOS app."
        #endif
    }

    private func presentCloneRepository(in workspaceID: Workspace.ID) {
        cloneDestinationWorkspaceID = workspaceID
        isCloningRepository = true
    }

    private func cloneRepository(
        _ remote: String,
        into destinationParent: URL,
        in workspaceID: Workspace.ID
    ) -> Bool {
        guard let project = workspaceStore.cloneRepository(
            remote,
            into: destinationParent,
            workspaceID: workspaceID
        ) else {
            return false
        }
        selectedProjectIDs[workspaceID] = project.id
        selectedNavigationItem = .project(workspaceID: workspaceID, projectID: project.id)
        expandedWorkspaceIDs.insert(workspaceID)
        expandedProjectIDs.insert(project.id)
        return true
    }

    private func createNewWorktree(for project: LocalProject) {
        guard let workspaceID = selectedWorkspaceID else { return }
        guard let worktree = workspaceStore.createWorktree(
            in: workspaceID,
            projectID: project.id
        ) else {
            return
        }
        guard let session = worktree.sessions.first else { return }
        activeSessionTarget = AgentSessionTarget(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        selectedNavigationItem = .session(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        expandedWorkspaceIDs.insert(workspaceID)
        expandedProjectIDs.insert(project.id)
    }

    private func createAdditionalSession(in worktree: ProjectWorktree, for project: LocalProject) {
        guard let selectedWorkspaceID else { return }
        createAdditionalSession(
            in: worktree,
            for: project,
            workspaceID: selectedWorkspaceID
        )
    }

    private func createAdditionalSession(
        in worktree: ProjectWorktree,
        for project: LocalProject,
        workspaceID: Workspace.ID
    ) {
        guard let session = workspaceStore.createSession(
                  in: workspaceID,
                  projectID: project.id,
                  worktreeID: worktree.id
              )
        else {
            return
        }
        activeSessionTarget = AgentSessionTarget(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        selectedNavigationItem = .session(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        expandedWorkspaceIDs.insert(workspaceID)
        expandedProjectIDs.insert(project.id)
    }

    private func deleteSelectedSession() {
        guard let selectedNavigationItem,
              case let .session(workspaceID, projectID, worktreeID, sessionID) = selectedNavigationItem
        else {
            return
        }
        requestSessionDeletion(
            AgentSessionTarget(
                workspaceID: workspaceID,
                projectID: projectID,
                worktreeID: worktreeID,
                sessionID: sessionID
            )
        )
    }

    private func requestSessionDeletion(_ target: AgentSessionTarget) {
        guard let session = workspaceStore.session(
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID,
            sessionID: target.sessionID
        ) else {
            return
        }

        if session.initialPrompt != nil
            || session.agentPrompt != nil
            || session.inferenceConfiguration != nil
            || agentRuntime.snapshot(for: session.id) != nil
        {
            sessionPendingDeletion = target
        } else {
            deleteSession(target)
        }
    }

    private func deleteSession(_ target: AgentSessionTarget) {
        sessionPendingDeletion = nil
        agentRuntime.discard(sessionID: target.sessionID)

        guard workspaceStore.deleteSession(
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID,
            sessionID: target.sessionID
        ) else {
            return
        }

        if activeSessionTarget == target {
            activeSessionTarget = nil
        }
        selectedWorkspaceID = target.workspaceID
        selectedProjectIDs[target.workspaceID] = target.projectID
        selectedNavigationItem = .project(
            workspaceID: target.workspaceID,
            projectID: target.projectID
        )
        expandedWorkspaceIDs.insert(target.workspaceID)
        expandedProjectIDs.insert(target.projectID)
    }

    private func sessionDeletionMessage(for target: AgentSessionTarget) -> String {
        if workspaceStore.isOnlySession(
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID
        ) {
            return "This removes the session from Tuist Code. Its Git worktree and files remain on disk, and you can start another session in that worktree later."
        }
        return "This permanently removes this session from Tuist Code. Other sessions in the Git worktree are unaffected."
    }

    private func startAgentSession(
        with prompt: String,
        configuration: AgentSessionInferenceConfiguration,
        for session: AgentSession
    ) {
        guard let activeSessionTarget else { return }
        let agentPrompt = AgentSessionTools.prompt(
            for: prompt,
            configuration: configuration,
            canRenameWorktree: activeWorktreeSession?.worktree.sessions.count == 1
        )
        workspaceStore.startAgentSession(
            prompt: prompt,
            in: activeSessionTarget.workspaceID,
            projectID: activeSessionTarget.projectID,
            worktreeID: activeSessionTarget.worktreeID,
            sessionID: session.id,
            configuration: configuration
        )
        guard let currentSession = activeWorktreeSession?.session,
              let worktree = activeWorktreeSession?.worktree,
              let account = inferenceAccounts.configuredAccounts.first(where: { $0.id == configuration.accountID })
        else {
            workspaceStore.errorMessage = "The selected inference account is unavailable."
            return
        }
        let credential = account.providerID == "codex"
            ? ""
            : inferenceAccounts.credential(for: account)
        guard let credential else {
            workspaceStore.errorMessage = "The selected inference account is unavailable."
            return
        }
        agentRuntime.start(
            sessionID: currentSession.id,
            in: URL(fileURLWithPath: worktree.directoryPath),
            prompt: agentPrompt,
            configuration: configuration,
            credential: credential
        )
    }

    private func workspaceExpansionBinding(for workspaceID: Workspace.ID) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaceIDs.contains(workspaceID) },
            set: { isExpanded in
                if isExpanded {
                    expandedWorkspaceIDs.insert(workspaceID)
                } else {
                    expandedWorkspaceIDs.remove(workspaceID)
                }
            }
        )
    }

    private func projectExpansionBinding(for projectID: LocalProject.ID) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIDs.contains(projectID) },
            set: { isExpanded in
                if isExpanded {
                    expandedProjectIDs.insert(projectID)
                } else {
                    expandedProjectIDs.remove(projectID)
                }
            }
        )
    }
}

private enum WorkspaceNavigationItem: Hashable {
    case workspace(Workspace.ID)
    case project(workspaceID: Workspace.ID, projectID: LocalProject.ID)
    case session(
        workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID
    )
}

private struct ProjectSessionsView: View {
    let project: LocalProject?
    let createWorktree: (LocalProject) -> Void
    let remoteSessionsAreAvailable: Bool

    var body: some View {
        Group {
            if let project {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        project.worktrees.isEmpty ? "No agent sessions" : "Select an agent session",
                        systemImage: project.worktrees.isEmpty ? "sparkles" : "sidebar.left",
                        description: Text(sessionDescription(for: project))
                    )

                    Button("New Worktree", systemImage: "plus") {
                        createWorktree(project)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a project",
                    systemImage: "folder",
                    description: Text("Choose a repository in the sidebar to view its agent sessions.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(project?.name ?? "Projects")
        .toolbar {
            if let project {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createWorktree(project)
                    } label: {
                        Label("New Worktree", systemImage: "plus")
                    }
                    .help("Create a worktree and its first session for \(project.name)")
                }
            }
        }
    }

    private func sessionDescription(for project: LocalProject) -> String {
        if project.worktrees.isEmpty, remoteSessionsAreAvailable {
            "Create a worktree for \(project.name), then start an agent session. Remote sessions are available through Tuist."
        } else if project.worktrees.isEmpty {
            "Create a worktree for \(project.name), then start an agent session. Connect to Tuist to unlock remote sessions."
        } else {
            "Choose a session in the sidebar, or create another worktree for \(project.name)."
        }
    }
}

private struct AgentSessionView: View {
    @EnvironmentObject private var accountStore: InferenceAccountStore
    @EnvironmentObject private var agentRuntime: AgentSessionRuntimeStore

    let project: LocalProject
    let worktree: ProjectWorktree
    let session: AgentSession
    let close: () -> Void
    let newSession: () -> Void
    let start: (String, AgentSessionInferenceConfiguration) -> Void

    @State private var prompt = ""
    @State private var selectedAccountID = ""
    @State private var selectedModelID = ""
    @State private var selectedReasoningEffort: InferenceReasoningEffort = .medium

    private var canStart: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && configuration != nil
            && agentRuntime.snapshot(for: session.id)?.phase != .running
    }

    private var selectedAccount: InferenceAccount? {
        agentAccounts.first(where: { $0.id == selectedAccountID })
    }

    private var agentAccounts: [InferenceAccount] {
        accountStore.configuredAccounts.filter { account in
            ["together", "fireworks", "codex"].contains(account.providerID)
        }
    }

    private var selectedProvider: InferenceProviderDescriptor? {
        guard let selectedAccount else { return nil }
        return accountStore.provider(for: selectedAccount)
    }

    private var availableModels: [InferenceModel] {
        guard let selectedAccount else { return [] }
        return accountStore.models(for: selectedAccount)
    }

    private var availableReasoningEfforts: [InferenceReasoningEffort] {
        availableModels.first(where: { $0.id == selectedModelID })?.reasoningEfforts ?? []
    }

    private var configuration: AgentSessionInferenceConfiguration? {
        guard let selectedAccount,
              let selectedProvider,
              availableModels.contains(where: { $0.id == selectedModelID }),
              availableReasoningEfforts.contains(selectedReasoningEffort)
        else {
            return nil
        }
        return AgentSessionInferenceConfiguration(
            accountID: selectedAccount.id,
            providerID: selectedProvider.id,
            modelID: selectedModelID,
            reasoningEffort: selectedReasoningEffort
        )
    }

    private var agentCapabilityDescription: String {
        if worktree.sessions.count == 1 {
            "The agent can inspect, search, edit, patch, and run commands in this worktree. Changes and commands require your approval."
        } else {
            "The agent can inspect, search, edit, patch, and run commands in this shared worktree. Changes and commands require your approval."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let runtimeSnapshot = agentRuntime.snapshot(for: session.id) {
                AgentSessionRunView(snapshot: runtimeSnapshot)
            } else if let taskPrompt = session.initialPrompt {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text("Agent is starting")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Task")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(taskPrompt)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                        Label(
                            agentCapabilityDescription,
                            systemImage: "pencil.and.list.clipboard"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help("The agent has access to shared programming tools in this worktree.")
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Start the agent",
                    systemImage: "sparkles",
                    description: Text("Describe the task. Before work begins, the agent is instructed to name this session and its worktree.")
                )
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if agentAccounts.isEmpty {
                        Label(
                            "Add an inference account in Settings before starting an agent session.",
                            systemImage: "person.crop.circle.badge.plus"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            Picker("Account", selection: $selectedAccountID) {
                                ForEach(agentAccounts) { account in
                                    Text(account.name).tag(account.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedAccountID) { _, _ in
                                selectDefaultModel()
                            }

                            Picker("Model", selection: $selectedModelID) {
                                ForEach(availableModels) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedModelID) { _, _ in
                                selectDefaultReasoningEffort()
                            }

                            Picker("Reasoning", selection: $selectedReasoningEffort) {
                                ForEach(availableReasoningEfforts) { effort in
                                    Text(effort.title).tag(effort)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .font(.caption)
                    }

                    TextField("Ask the agent to work on this project", text: $prompt, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startSession)
                }

                Button(action: startSession) {
                    Label(session.initialPrompt == nil ? "Start" : "Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: close) {
                    Label("Sessions", systemImage: "chevron.backward")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if agentRuntime.snapshot(for: session.id)?.phase == .running {
                        Button("Stop", role: .destructive) {
                            agentRuntime.stop(sessionID: session.id)
                        }
                    }

                    Button(action: newSession) {
                        Label("New Session", systemImage: "plus")
                    }
                    .help("Create another agent session in \(worktree.name)")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(project.name)
                Text(worktree.directoryPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear(perform: restoreInferenceConfiguration)
        .onChange(of: accountStore.configuredAccounts) { _, _ in
            restoreInferenceConfiguration()
        }
        .onChange(of: accountStore.modelsByAccountID) { _, _ in
            restoreInferenceConfiguration()
        }
    }

    private func startSession() {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, let configuration else { return }
        start(task, configuration)
        prompt = ""
    }

    private func restoreInferenceConfiguration() {
        if let configuration = session.inferenceConfiguration,
           agentAccounts.contains(where: { $0.id == configuration.accountID })
        {
            selectedAccountID = configuration.accountID
            selectedModelID = configuration.modelID
            selectedReasoningEffort = configuration.reasoningEffort
            if self.configuration != nil {
                return
            }
        }
        selectedAccountID = agentAccounts.first?.id ?? ""
        selectDefaultModel()
    }

    private func selectDefaultModel() {
        selectedModelID = availableModels.first?.id ?? ""
        selectDefaultReasoningEffort()
    }

    private func selectDefaultReasoningEffort() {
        selectedReasoningEffort = availableReasoningEfforts.contains(.medium)
            ? .medium
            : availableReasoningEfforts.first ?? .none
    }
}

/// The capability supplied to an agent as soon as a local session begins.
///
/// The agent runner can use `prompt(for:)` as its system context and bind this
/// definition to `WorkspaceStore.renameSessionAndWorktree`. Keeping the
/// capability separate from the SwiftUI view makes the same contract portable
/// to another desktop client.
private enum AgentSessionTools {
    static func prompt(
        for task: String,
        configuration: AgentSessionInferenceConfiguration,
        canRenameWorktree: Bool
    ) -> String {
        let worktreeInstruction = if canRenameWorktree {
            "This worktree belongs only to this session."
        } else {
            "This worktree is shared with other sessions; do not make assumptions about their work."
        }
        return """
        You are working in a local Git worktree session.

        Use the selected inference configuration: provider \(configuration.providerID), model \(configuration.modelID), reasoning \(configuration.reasoningEffort.rawValue).

        You can use read, list, ls, glob, find, grep, write, edit, apply_patch, shell, bash, git_status, git_diff, and ask_user. Read-only tools run immediately. The user must approve write, edit, apply_patch, shell, and bash before they run. \(worktreeInstruction)

        User task:
        \(task)
        """
    }
}

fileprivate enum AgentSessionRuntimePhase: String, Hashable {
    case running
    case completed
    case stopped
    case failed

    var title: String {
        switch self {
        case .running: "Agent is working"
        case .completed: "Agent finished"
        case .stopped: "Agent stopped"
        case .failed: "Agent could not finish"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

fileprivate struct AgentSessionActivity: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String?
    let isInProgress: Bool
}

fileprivate struct AgentRunnerApproval: Hashable {
    let tool: String
    let summary: String
}

fileprivate struct AgentSessionRuntimeSnapshot: Identifiable, Hashable {
    let id: AgentSession.ID
    var phase: AgentSessionRuntimePhase
    var activities: [AgentSessionActivity]
    var transcript: String
    var errorMessage: String?
    var pendingApproval: AgentRunnerApproval?
    var pendingQuestion: String?

    static func failed(id: AgentSession.ID, message: String) -> Self {
        Self(
            id: id,
            phase: .failed,
            activities: [],
            transcript: "",
            errorMessage: message,
            pendingApproval: nil,
            pendingQuestion: nil
        )
    }
}

private struct AgentSessionRunView: View {
    @EnvironmentObject private var agentRuntime: AgentSessionRuntimeStore

    let snapshot: AgentSessionRuntimeSnapshot
    @State private var answer = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(snapshot.phase.title, systemImage: snapshot.phase.symbolName)
                    .font(.headline)
                    .foregroundStyle(statusColor)

                if let errorMessage = snapshot.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }

                if let pendingApproval = snapshot.pendingApproval {
                    GroupBox("Approval required") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("The agent wants to use \(pendingApproval.tool).")
                            Text(pendingApproval.summary)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                            HStack {
                                Button("Deny", role: .cancel) {
                                    agentRuntime.approvePendingToolCall(for: snapshot.id, approved: false)
                                }
                                Button("Allow") {
                                    agentRuntime.approvePendingToolCall(for: snapshot.id, approved: true)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let pendingQuestion = snapshot.pendingQuestion {
                    GroupBox("The agent needs your input") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(pendingQuestion)
                            HStack {
                                TextField("Your response", text: $answer)
                                Button("Reply") {
                                    agentRuntime.answerPendingQuestion(for: snapshot.id, answer: answer)
                                    answer = ""
                                }
                                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }

                if snapshot.activities.isEmpty, snapshot.phase == .running {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing the coding environment…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(snapshot.activities) { activity in
                        HStack(alignment: .top, spacing: 10) {
                            if activity.isInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.title)
                                    .font(.body.weight(.medium))
                                if let detail = activity.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if !snapshot.transcript.isEmpty {
                    DisclosureGroup("Provider events") {
                        Text(snapshot.transcript)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
        }
    }

    private var statusColor: Color {
        switch snapshot.phase {
        case .running: .primary
        case .completed: .green
        case .stopped: .secondary
        case .failed: .orange
        }
    }
}

/// Owns provider conversations independently from navigation, allowing several
/// worktree sessions to progress while the user moves between them.
@MainActor
final class AgentSessionRuntimeStore: ObservableObject {
    @Published fileprivate private(set) var snapshots = [AgentSession.ID: AgentSessionRuntimeSnapshot]()
    private var runners = [AgentSession.ID: RustAgentRunner]()

    fileprivate func snapshot(for sessionID: AgentSession.ID) -> AgentSessionRuntimeSnapshot? {
        snapshots[sessionID]
    }

    fileprivate func start(
        sessionID: AgentSession.ID,
        in worktree: URL,
        prompt: String,
        configuration: AgentSessionInferenceConfiguration,
        credential: String
    ) {
        guard snapshots[sessionID]?.phase != .running else { return }
        guard ["together", "fireworks", "codex"].contains(configuration.providerID) else {
            snapshots[sessionID] = AgentSessionRuntimeSnapshot.failed(
                id: sessionID,
                message: "Choose a configured inference account for the built-in coding agent."
            )
            return
        }
        guard let executableURL = RustAgentRunner.executableURL else {
            snapshots[sessionID] = AgentSessionRuntimeSnapshot.failed(
                id: sessionID,
                message: "The Rust agent runner is unavailable in this app bundle."
            )
            return
        }

        snapshots[sessionID] = AgentSessionRuntimeSnapshot(
            id: sessionID,
            phase: .running,
            activities: [
                AgentSessionActivity(
                    title: "Starting \(configuration.modelID)",
                    detail: "Working in \(worktree.lastPathComponent)",
                    isInProgress: true
                )
            ],
            transcript: "",
            errorMessage: nil,
            pendingApproval: nil,
            pendingQuestion: nil
        )
        let runner = RustAgentRunner(
            executableURL: executableURL,
            providerID: configuration.providerID,
            modelID: configuration.modelID,
            reasoning: configuration.reasoningEffort.rawValue,
            worktree: worktree,
            prompt: prompt,
            credential: credential
        )
        runner.onOutput = { [weak self] data in
            Task { @MainActor in
                self?.receiveRunnerOutput(data, for: sessionID)
            }
        }
        runner.onTermination = { [weak self] status in
            Task { @MainActor in
                self?.runnerTerminated(for: sessionID, status: status)
            }
        }
        runners[sessionID] = runner
        do {
            try runner.start()
        } catch {
            runners[sessionID] = nil
            finish(sessionID: sessionID, phase: .failed, message: error.localizedDescription)
        }
    }

    fileprivate func stop(sessionID: AgentSession.ID) {
        runners.removeValue(forKey: sessionID)?.stop()
        finish(sessionID: sessionID, phase: .stopped, message: nil)
    }

    fileprivate func discard(sessionID: AgentSession.ID) {
        runners.removeValue(forKey: sessionID)?.stop()
        snapshots.removeValue(forKey: sessionID)
    }

    fileprivate func approvePendingToolCall(for sessionID: AgentSession.ID, approved: Bool) {
        guard var snapshot = snapshots[sessionID] else { return }
        snapshot.pendingApproval = nil
        snapshots[sessionID] = snapshot
        runners[sessionID]?.send(approved ? "allow\n" : "deny\n")
        appendActivity(
            AgentSessionActivity(
                title: approved ? "Approved" : "Denied",
                detail: "Your decision was sent to the Rust agent runner.",
                isInProgress: false
            ),
            to: sessionID
        )
    }

    fileprivate func answerPendingQuestion(for sessionID: AgentSession.ID, answer: String) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty,
              var snapshot = snapshots[sessionID]
        else {
            return
        }

        snapshot.pendingQuestion = nil
        snapshots[sessionID] = snapshot
        runners[sessionID]?.send("\(answer)\n")
    }

    private func receiveRunnerOutput(_ data: Data, for sessionID: AgentSession.ID) {
        guard let runner = runners[sessionID] else { return }
        for line in runner.consume(data) {
            appendToTranscript(line, for: sessionID)
            guard let event = try? JSONDecoder().decode(RustAgentRunnerEvent.self, from: Data(line.utf8)) else {
                continue
            }
            receive(event, for: sessionID)
        }
    }

    private func receive(_ event: RustAgentRunnerEvent, for sessionID: AgentSession.ID) {
        switch event.type {
        case "model_request":
            appendActivity(
                AgentSessionActivity(
                    title: "Thinking",
                    detail: event.turn.map { "Agent turn \($0)" },
                    isInProgress: true
                ),
                to: sessionID
            )
        case "assistant_message":
            appendActivity(
                AgentSessionActivity(
                    title: "Agent response",
                    detail: event.content,
                    isInProgress: false
                ),
                to: sessionID
            )
        case "approval_requested":
            guard var snapshot = snapshots[sessionID] else { return }
            let tool = event.tool ?? "change the worktree"
            let summary = event.summary ?? tool
            snapshot.pendingApproval = AgentRunnerApproval(tool: tool, summary: summary)
            snapshots[sessionID] = snapshot
            appendActivity(
                AgentSessionActivity(title: "Approval required", detail: summary, isInProgress: true),
                to: sessionID
            )
        case "tool_completed":
            appendActivity(
                AgentSessionActivity(
                    title: event.tool ?? "Tool",
                    detail: event.output,
                    isInProgress: false
                ),
                to: sessionID
            )
        case "tool_failed":
            appendActivity(
                AgentSessionActivity(
                    title: event.tool ?? "Tool failed",
                    detail: event.error,
                    isInProgress: false
                ),
                to: sessionID
            )
        case "user_question":
            guard var snapshot = snapshots[sessionID] else { return }
            let question = event.question ?? "The agent needs more information."
            snapshot.pendingQuestion = question
            snapshots[sessionID] = snapshot
            appendActivity(
                AgentSessionActivity(title: "Question for you", detail: question, isInProgress: true),
                to: sessionID
            )
        case "completed":
            finish(sessionID: sessionID, phase: .completed, message: nil)
        case "error":
            finish(
                sessionID: sessionID,
                phase: .failed,
                message: event.message ?? "The Rust agent runner failed."
            )
        default:
            break
        }
    }

    private func runnerTerminated(for sessionID: AgentSession.ID, status: Int32) {
        guard snapshots[sessionID]?.phase == .running else { return }
        finish(
            sessionID: sessionID,
            phase: .failed,
            message: "The Rust agent runner stopped unexpectedly (status \(status))."
        )
    }

    private func appendToTranscript(_ line: String, for sessionID: AgentSession.ID) {
        guard var snapshot = snapshots[sessionID] else { return }
        snapshot.transcript.append(line)
        snapshot.transcript.append("\n")
        if snapshot.transcript.count > 40_000 {
            snapshot.transcript.removeFirst(snapshot.transcript.count - 40_000)
        }
        snapshots[sessionID] = snapshot
    }

    private func appendActivity(_ activity: AgentSessionActivity, to sessionID: AgentSession.ID) {
        guard var snapshot = snapshots[sessionID] else { return }
        if let lastIndex = snapshot.activities.indices.last, snapshot.activities[lastIndex].isInProgress {
            snapshot.activities[lastIndex] = AgentSessionActivity(
                title: snapshot.activities[lastIndex].title,
                detail: snapshot.activities[lastIndex].detail,
                isInProgress: false
            )
        }
        snapshot.activities.append(activity)
        if snapshot.activities.count > 50 {
            snapshot.activities.removeFirst(snapshot.activities.count - 50)
        }
        snapshots[sessionID] = snapshot
    }

    private func finish(
        sessionID: AgentSession.ID,
        phase: AgentSessionRuntimePhase,
        message: String?
    ) {
        guard var snapshot = snapshots[sessionID] else { return }
        snapshot.phase = phase
        snapshot.errorMessage = message
        snapshot.pendingApproval = nil
        snapshot.pendingQuestion = nil
        if let lastIndex = snapshot.activities.indices.last {
            snapshot.activities[lastIndex] = AgentSessionActivity(
                title: snapshot.activities[lastIndex].title,
                detail: snapshot.activities[lastIndex].detail,
                isInProgress: false
            )
        }
        snapshots[sessionID] = snapshot
    }
}

/// Bridges the headless Rust agent process to SwiftUI. It forwards JSON Lines
/// events and never implements provider or tool-loop behaviour itself.
#if os(macOS)
private final class RustAgentRunner {
    static var executableURL: URL? {
        if let bundled = Bundle.main.url(forResource: "tuist_code_agent", withExtension: nil) {
            return bundled
        }
        let developmentBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".once/out/TuistCodeAgent/tuist_code_agent")
        return FileManager.default.isExecutableFile(atPath: developmentBuild.path)
            ? developmentBuild
            : nil
    }

    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private var outputBuffer = ""

    var onOutput: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    init(
        executableURL: URL,
        providerID: String,
        modelID: String,
        reasoning: String,
        worktree: URL,
        prompt: String,
        credential: String
    ) {
        process.executableURL = executableURL
        process.currentDirectoryURL = worktree
        process.arguments = [
            "--provider", providerID,
            "--model", modelID,
            "--reasoning", reasoning,
            "--worktree", worktree.path,
            "--prompt", prompt,
            "--interactive",
        ]
        var environment = ProcessInfo.processInfo.environment
        if !credential.isEmpty {
            environment["TUIST_CODE_AGENT_API_KEY"] = credential
        }
        if providerID == "codex", let codexExecutable = CodexInstallation.executableURL {
            environment["TUIST_CODE_CODEX_EXECUTABLE"] = codexExecutable.path
        }
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func start() throws {
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onOutput?(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.onTermination?(process.terminationStatus)
        }
        try process.run()
    }

    func consume(_ data: Data) -> [String] {
        outputBuffer.append(String(decoding: data, as: UTF8.self))
        var lines = [String]()
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    func send(_ value: String) {
        standardInput.fileHandleForWriting.write(Data(value.utf8))
    }

    func stop() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    deinit {
        stop()
    }
}
#else
private final class RustAgentRunner {
    static var executableURL: URL? { nil }

    var onOutput: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    init(
        executableURL _: URL,
        providerID _: String,
        modelID _: String,
        reasoning _: String,
        worktree _: URL,
        prompt _: String,
        credential _: String
    ) {}

    func start() throws {
        throw NSError(
            domain: "TuistCode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The Rust agent runner is not bundled for this platform yet."]
        )
    }

    func consume(_: Data) -> [String] { [] }
    func send(_: String) {}
    func stop() {}
}
#endif

private struct RustAgentRunnerEvent: Decodable {
    let type: String
    let turn: Int?
    let content: String?
    let tool: String?
    let summary: String?
    let output: String?
    let error: String?
    let question: String?
    let message: String?
}

// Compatibility records for the legacy account view. Session execution no
// longer uses these types; it is performed by RustAgentRunner above.
private enum AgentInferenceEndpoint {
    case together
    case fireworks

    var url: URL {
        switch self {
        case .together: URL(string: "https://api.together.ai/v1/chat/completions")!
        case .fireworks: URL(string: "https://api.fireworks.ai/inference/v1/chat/completions")!
        }
    }
}

private struct AgentProviderResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let role: String
        let content: String?
        let toolCalls: [AgentProviderToolCall]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
        }
    }
}

fileprivate struct AgentProviderToolCall: Decodable, Hashable {
    let id: String
    let function: Function

    struct Function: Decodable, Hashable {
        let name: String
        let arguments: String
    }

    var name: String { function.name }
    var arguments: String { function.arguments }
}

private enum AgentInferenceProvider {
    static func endpoint(for providerID: String) -> AgentInferenceEndpoint? {
        switch providerID {
        case "together": .together
        case "fireworks": .fireworks
        default: nil
        }
    }

    static func complete(
        endpoint: AgentInferenceEndpoint,
        credential: String,
        modelID: String,
        messages: [[String: Any]]
    ) async throws -> AgentProviderResponse {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": messages,
            "tools": toolDefinitions,
            "tool_choice": "auto",
            "stream": false,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AgentInferenceError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
            throw AgentInferenceError.providerFailure(
                (error as? [String: Any])?["message"] as? String
                    ?? "The provider returned status \(response.statusCode)."
            )
        }
        let decoded = try JSONDecoder().decode(AgentProviderResponse.self, from: data)
        guard !decoded.choices.isEmpty else { throw AgentInferenceError.invalidResponse }
        return decoded
    }

    private static let toolDefinitions: [[String: Any]] = [
        function("read", "Read a text file in the worktree.", properties: [
            "path": stringProperty("Relative file path."),
            "offset": integerProperty("Zero-based line offset."),
            "limit": integerProperty("Maximum number of lines."),
        ], required: ["path"]),
        function("list", "List a directory in the worktree.", properties: [
            "path": stringProperty("Relative directory path, or . for the worktree root."),
        ], required: ["path"]),
        function("ls", "List a directory in the worktree.", properties: [
            "path": stringProperty("Relative directory path, or . for the worktree root."),
        ], required: ["path"]),
        function("glob", "Find files using a * wildcard pattern.", properties: [
            "pattern": stringProperty("A relative path pattern."),
        ], required: ["pattern"]),
        function("find", "Find files using a * wildcard pattern.", properties: [
            "pattern": stringProperty("A relative path pattern."),
        ], required: ["pattern"]),
        function("grep", "Search text files in the worktree.", properties: [
            "pattern": stringProperty("Literal text to search for."),
        ], required: ["pattern"]),
        function("write", "Create or replace a text file. Requires approval.", properties: [
            "path": stringProperty("Relative file path."),
            "content": stringProperty("Complete new contents."),
        ], required: ["path", "content"]),
        function("edit", "Replace one exact text range in a file. Requires approval.", properties: [
            "path": stringProperty("Relative file path."),
            "old_text": stringProperty("Exact existing text."),
            "new_text": stringProperty("Replacement text."),
        ], required: ["path", "old_text", "new_text"]),
        function("apply_patch", "Apply a unified Git patch. Requires approval.", properties: [
            "patch": stringProperty("Patch in unified diff format."),
        ], required: ["patch"]),
        function("shell", "Run a shell command in the worktree. Requires approval.", properties: [
            "command": stringProperty("Command to run."),
        ], required: ["command"]),
        function("bash", "Run a shell command in the worktree. Requires approval.", properties: [
            "command": stringProperty("Command to run."),
        ], required: ["command"]),
        function("git_status", "Show the Git working tree status.", properties: [:], required: []),
        function("git_diff", "Show unstaged Git changes.", properties: [:], required: []),
        function("ask_user", "Ask the human for information needed to continue.", properties: [
            "question": stringProperty("The question for the human."),
        ], required: ["question"]),
    ]

    private static func function(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private static func stringProperty(_ description: String) -> [String: String] {
        ["type": "string", "description": description]
    }

    private static func integerProperty(_ description: String) -> [String: String] {
        ["type": "integer", "description": description]
    }
}

private enum AgentInferenceError: LocalizedError {
    case invalidResponse
    case providerFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The inference provider returned an invalid response."
        case let .providerFailure(message): message
        }
    }
}

fileprivate struct SharedAgentToolResult {
    let output: String
    let needsUserInput: Bool
}

private enum SharedAgentToolRuntime {
    static func requiresApproval(for tool: String) -> Bool {
        tool.withCString { tuistCodeAgentToolRequiresApproval($0) != 0 }
    }

    static func execute(_ call: AgentProviderToolCall, in worktree: URL) -> SharedAgentToolResult {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let path = string("path", in: arguments) ?? ""
        let value: String
        let replacement: String
        switch call.name {
        case "list", "ls": value = path; replacement = ""
        case "glob", "find", "grep": value = string("pattern", in: arguments) ?? ""; replacement = ""
        case "write": value = string("content", in: arguments) ?? ""; replacement = ""
        case "edit":
            value = string("old_text", in: arguments) ?? string("oldText", in: arguments) ?? ""
            replacement = string("new_text", in: arguments) ?? string("newText", in: arguments) ?? ""
        case "apply_patch": value = string("patch", in: arguments) ?? ""; replacement = ""
        case "shell", "bash": value = string("command", in: arguments) ?? ""; replacement = ""
        case "ask_user": value = string("question", in: arguments) ?? ""; replacement = ""
        default: value = ""; replacement = ""
        }
        let offset = number("offset", in: arguments) ?? 0
        let limit = number("limit", in: arguments) ?? 200
        var output = [CChar](repeating: 0, count: 64 * 1024)
        let status = worktree.path.withCString { worktree in
            call.name.withCString { tool in
                path.withCString { path in
                    value.withCString { value in
                        replacement.withCString { replacement in
                            tuistCodeExecuteAgentTool(
                                worktree,
                                tool,
                                path,
                                value,
                                replacement,
                                offset,
                                limit,
                                &output,
                                output.count
                            )
                        }
                    }
                }
            }
        }
        let message = String(cString: output)
        switch status {
        case 0: return SharedAgentToolResult(output: message, needsUserInput: false)
        case 4: return SharedAgentToolResult(output: message, needsUserInput: true)
        default: return SharedAgentToolResult(output: "Tool failed: \(message)", needsUserInput: false)
        }
    }

    static func summary(for call: AgentProviderToolCall) -> String {
        switch call.name {
        case "shell", "bash": string("command", in: call.arguments) ?? "Run a shell command"
        case "write", "edit": string("path", in: call.arguments) ?? "Change a file"
        case "apply_patch": "Apply a patch to the worktree"
        default: call.name
        }
    }

    static func question(for call: AgentProviderToolCall) -> String {
        string("question", in: call.arguments) ?? "The agent needs more information."
    }

    private static func string(_ key: String, in arguments: [String: Any]?) -> String? {
        arguments?[key] as? String
    }

    private static func string(_ key: String, in rawArguments: String) -> String? {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(rawArguments.utf8))) as? [String: Any]
        return string(key, in: arguments)
    }

    private static func number(_ key: String, in arguments: [String: Any]?) -> Int? {
        (arguments?[key] as? NSNumber)?.intValue
    }
}

struct TuistCodeSettingsView: View {
    @EnvironmentObject private var themeStore: TuistCodeThemeStore

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $themeStore.selectedTheme) {
                    ForEach(TuistCodeTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gear")
            }

            InferenceAccountsSettingsView()
                .tabItem {
                    Label("Accounts", systemImage: "person.crop.circle")
                }
        }
        #if os(macOS)
        .frame(width: 820, height: 520)
        #else
        .frame(width: 720, height: 480)
        #endif
    }
}

private struct InferenceAccountsSettingsView: View {
    @EnvironmentObject private var accountStore: InferenceAccountStore

    @State private var selectedAccountID: InferenceAccount.ID?
    @State private var providerToAdd: InferenceProviderDescriptor?

    private var selectedAccount: InferenceAccount? {
        accountStore.accounts.first(where: { $0.id == selectedAccountID })
    }

    var body: some View {
        Group {
            if accountStore.accounts.isEmpty {
                InferenceAccountsEmptyState(
                    providers: accountStore.catalog,
                    addAccount: { providerToAdd = $0 }
                )
            } else {
                #if os(macOS)
                HStack(spacing: 0) {
                    accountsSidebar
                    Divider()
                    accountDetail
                }
                #else
                NavigationSplitView {
                    accountsSidebar
                } detail: {
                    accountDetail
                }
                .navigationSplitViewStyle(.balanced)
                #endif
            }
        }
        .onAppear {
            selectAvailableAccount()
        }
        .onChange(of: accountStore.accounts.map(\.id)) { _, _ in
            selectAvailableAccount()
        }
        .sheet(item: $providerToAdd) { provider in
            AddInferenceAccountSheet(provider: provider)
                .environmentObject(accountStore)
        }
        .alert(
            "Unable to update accounts",
            isPresented: Binding(
                get: { accountStore.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        accountStore.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                accountStore.errorMessage = nil
            }
        } message: {
            Text(accountStore.errorMessage ?? "")
        }
    }

    private var accountsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedAccountID) {
                ForEach(accountStore.accounts) { account in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            account.name,
                            systemImage: accountStore.provider(for: account)?.symbolName ?? "cpu"
                        )
                        Text(accountStore.provider(for: account)?.name ?? "Unknown provider")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(account.id)
                }
            }
            #if os(macOS)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .padding(16)
            #else
            .listStyle(.sidebar)
            #endif

            HStack {
                ControlGroup {
                    InferenceAccountAddMenu(
                        providers: accountStore.catalog,
                        addAccount: { providerToAdd = $0 },
                        compact: true
                    )
                    Button {
                        guard let selectedAccount else { return }
                        accountStore.remove(selectedAccount)
                        selectedAccountID = accountStore.accounts.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedAccount == nil)
                    .accessibilityLabel("Remove Account")
                }
                .frame(width: 92)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
    }

    @ViewBuilder
    private var accountDetail: some View {
        if let selectedAccount,
           let provider = accountStore.provider(for: selectedAccount)
        {
            InferenceAccountDetailView(
                account: selectedAccount,
                provider: provider
            )
        } else {
            ContentUnavailableView(
                "Select an Account",
                systemImage: "person.crop.circle",
                description: Text("Choose an account from the list to manage its connection.")
            )
        }
    }

    private func selectAvailableAccount() {
        guard !accountStore.accounts.isEmpty else {
            selectedAccountID = nil
            return
        }

        if !accountStore.accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accountStore.accounts.first?.id
        }
    }
}

private struct InferenceAccountsEmptyState: View {
    let providers: [InferenceProviderDescriptor]
    let addAccount: (InferenceProviderDescriptor) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Add an inference account to use it in agent sessions.")
        } actions: {
            InferenceAccountAddMenu(providers: providers, addAccount: addAccount)
                .controlSize(.regular)
        }
    }
}

private struct InferenceAccountAddMenu: View {
    let providers: [InferenceProviderDescriptor]
    let addAccount: (InferenceProviderDescriptor) -> Void
    var compact = false

    var body: some View {
        Menu {
            ForEach(providers) { provider in
                Button {
                    addAccount(provider)
                } label: {
                    Label("Add \(provider.name) Account", systemImage: provider.symbolName)
                }
            }
        } label: {
            if compact {
                Image(systemName: "plus")
            } else {
                Label("Add Account", systemImage: "plus")
            }
        }
        .menuIndicator(compact ? .hidden : .automatic)
        .accessibilityLabel("Add Account")
    }
}

private struct InferenceAccountDetailView: View {
    @EnvironmentObject private var accountStore: InferenceAccountStore

    let account: InferenceAccount
    let provider: InferenceProviderDescriptor

    @State private var selectedPane: AccountDetailPane = .information
    @State private var isPresentingSignIn = false

    var body: some View {
        VStack(spacing: 22) {
            Picker("Account section", selection: $selectedPane) {
                ForEach(AccountDetailPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 680)

            Group {
                switch selectedPane {
                case .information:
                    accountInformation
                case .models:
                    modelAccess
                case .connection:
                    connection
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(16)
        #endif
        .sheet(isPresented: $isPresentingSignIn) {
            InferenceAccountAuthenticationSheet(
                accountID: account.id,
                provider: provider
            )
            .environmentObject(accountStore)
        }
    }

    private var accountInformation: some View {
        VStack(spacing: 18) {
            preferenceRow("Description") {
                Text(account.name)
            }
            preferenceRow("Provider") {
                Text(provider.name)
            }
            preferenceRow("Status") {
                connectionStatus
            }
        }
    }

    private var modelAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Models available to this account")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    accountStore.refreshModels(for: account)
                }
                .disabled(accountStore.isRefreshingModels(for: account))
            }
            .padding(.bottom, 8)

            if accountStore.isRefreshingModels(for: account) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models from \(provider.name)…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else {
                let models = accountStore.models(for: account)
                if models.isEmpty {
                    ContentUnavailableView(
                        "No models available",
                        systemImage: "cpu",
                        description: Text("Refresh to load the models available to this account."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(models) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text(model.reasoningEfforts.map(\.title).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 10)

                        if model.id != models.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: account.id) {
            accountStore.refreshModels(for: account)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferenceRow("Status") {
                connectionStatus
            }

            preferenceRow("Authentication") {
                switch provider.authentication {
                case .oauth:
                    Button(account.state == .authorizing ? "Waiting for sign in" : "Sign In…") {
                        if accountStore.reauthenticate(account, with: provider) {
                            isPresentingSignIn = true
                        }
                    }
                    .disabled(account.state == .authorizing)
                case .apiKey:
                    Text("Application programming interface key")
                }
            }

            Divider()

            Text("Credentials remain in this device’s secure credential storage. Removing this account deletes its stored credential.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Text(account.state.title)
            Circle()
                .fill(account.state == .configured ? .green : .orange)
                .frame(width: 10, height: 10)
        }
    }

    private func preferenceRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title + ":")
                .frame(width: 142, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum AccountDetailPane: String, CaseIterable, Identifiable {
    case information
    case models
    case connection

    var id: Self { self }

    var title: String {
        switch self {
        case .information: "Account Information"
        case .models: "Model Access"
        case .connection: "Connection"
        }
    }
}

private struct InferenceAccountAuthenticationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accountStore: InferenceAccountStore

    let accountID: InferenceAccount.ID
    let provider: InferenceProviderDescriptor
    @State private var didCopyDeviceCode = false

    private var account: InferenceAccount? {
        accountStore.accounts.first(where: { $0.id == accountID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch account?.state {
            case .authorizing:
                Label("Sign in to \(provider.name)", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.title3.weight(.semibold))

                if let authorizationURL = accountStore.authorizationURL {
                    Text("Open the sign-in page in your browser, then enter the one-time code below.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(destination: authorizationURL) {
                        Label("Open Sign-In Page", systemImage: "safari")
                    }
                        .buttonStyle(.borderedProminent)
                } else {
                    ProgressView("Preparing sign in")
                        .controlSize(.regular)

                    Text("Getting the sign-in page and one-time code.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let deviceCode = accountStore.authorizationDeviceCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One-Time Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text(deviceCode)
                                .font(.system(.title3, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                copy(deviceCode)
                            } label: {
                                Label(
                                    didCopyDeviceCode ? "Copied" : "Copy",
                                    systemImage: didCopyDeviceCode ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .accessibilityLabel("Copy one-time sign-in code")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    if let expiration = accountStore.authorizationDeviceCodeExpiration {
                        Text("This code expires \(expiration).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("This sheet closes automatically when the connection is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .configured:
                EmptyView()

            default:
                Label("\(provider.name) sign in wasn’t completed", systemImage: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.orange)

                Text("Try again to restart the sign-in flow.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if account?.state == .requiresAuthorization,
                   let account
                {
                    Button("Try Again") {
                        _ = accountStore.reauthenticate(account, with: provider)
                    }
                }
                Button("Cancel") {
                    if account?.state == .authorizing {
                        accountStore.cancelAuthorization(for: accountID)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: account?.state) { _, state in
            if state == .configured {
                dismiss()
            }
        }
    }

    private func copy(_ deviceCode: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceCode, forType: .string)
        didCopyDeviceCode = true
        #endif
    }
}

private struct AddInferenceAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accountStore: InferenceAccountStore

    let provider: InferenceProviderDescriptor

    @State private var accountName = ""
    @State private var apiKey = ""

    private var canAddAccount: Bool {
        !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (provider.authentication == .oauth || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add \(provider.name) Account", systemImage: provider.symbolName)
                .font(.title2)

            LabeledContent("Account name") {
                TextField("Personal", text: $accountName)
                    .textFieldStyle(.roundedBorder)
            }

            switch provider.authentication {
            case .apiKey:
                Text("Add an application programming interface key for this account. It is stored only in this device’s secure credential storage.")
                    .foregroundStyle(.secondary)

                SecureField("Application programming interface key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    Button("Add Account") {
                        if accountStore.configureAPIKey(apiKey, named: accountName, for: provider) {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAddAccount)
                }

            case .oauth:
                Text("Sign in with your ChatGPT account. Tuist Code starts Codex’s supported sign-in flow and records the account after it succeeds.")
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    Button("Sign in with ChatGPT") {
                        if accountStore.beginOAuth(named: accountName, for: provider) {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAddAccount)
                }
            }
        }
        .onAppear {
            if accountName.isEmpty {
                accountName = provider.name
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct NewWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    let addWorkspace: (String) -> Void

    private var canAddWorkspace: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(.headline)

            LabeledContent("Name") {
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Add") {
                    addWorkspace(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddWorkspace)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct CloneRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var remote = ""
    @State private var destinationParent: URL?

    let cloneRepository: (String, URL) -> Bool

    private var canClone: Bool {
        !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && destinationParent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository")
                .font(.headline)

            LabeledContent("Repository URL") {
                TextField("https://github.com/organization/repository.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Destination") {
                HStack(spacing: 8) {
                    Text(destinationParent?.path ?? "Choose a folder")
                        .foregroundStyle(destinationParent == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose") {
                        chooseDestinationParent()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Clone") {
                    guard let destinationParent else { return }
                    if cloneRepository(remote, destinationParent) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canClone)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseDestinationParent() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Clone Destination"
        panel.message = "Choose the folder where the repository will be cloned."
        panel.prompt = "Choose Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            destinationParent = panel.url
        }
        #endif
    }
}

private enum SharedProjectService {
    private static let outputPathCapacity = 4_096

    static func validateGitRepository(at directoryURL: URL) throws {
        let status = directoryURL.path.withCString { directoryPath in
            tuistCodeValidateGitRepository(directoryPath)
        }
        try ProjectOperationError.throwIfFailure(status)
    }

    static func cloneRepository(remote: String, into destinationParent: URL) throws -> URL {
        var outputPath = [CChar](repeating: 0, count: outputPathCapacity)
        let status = remote.withCString { remote in
            destinationParent.path.withCString { destinationParent in
                outputPath.withUnsafeMutableBufferPointer { outputPath in
                    tuistCodeCloneGitRepository(
                        remote,
                        destinationParent,
                        outputPath.baseAddress!,
                        outputPath.count
                    )
                }
            }
        }

        try ProjectOperationError.throwIfFailure(status)
        return URL(fileURLWithPath: String(cString: outputPath))
    }

    static func createDefaultSessionWorktree(in repository: URL) throws -> URL {
        var outputPath = [CChar](repeating: 0, count: outputPathCapacity)
        let status = repository.path.withCString { repository in
            outputPath.withUnsafeMutableBufferPointer { outputPath in
                tuistCodeCreateDefaultSessionWorktree(
                    repository,
                    outputPath.baseAddress!,
                    outputPath.count
                )
            }
        }

        try WorktreeOperationError.throwIfFailure(status)
        return URL(fileURLWithPath: String(cString: outputPath))
    }

    static func renameSessionWorktree(
        in repository: URL,
        currentWorktree: URL,
        sessionTitle: String,
        newWorktreeName: String
    ) throws -> URL {
        var outputPath = [CChar](repeating: 0, count: outputPathCapacity)
        let status = repository.path.withCString { repository in
            currentWorktree.path.withCString { currentWorktree in
                sessionTitle.withCString { sessionTitle in
                    newWorktreeName.withCString { newWorktreeName in
                        outputPath.withUnsafeMutableBufferPointer { outputPath in
                            tuistCodeRenameSessionWorktree(
                                repository,
                                currentWorktree,
                                sessionTitle,
                                newWorktreeName,
                                outputPath.baseAddress!,
                                outputPath.count
                            )
                        }
                    }
                }
            }
        }

        try WorktreeOperationError.throwIfFailure(status)
        return URL(fileURLWithPath: String(cString: outputPath))
    }
}

private enum SharedInferenceProviderRegistry {
    private static let outputCapacity = 16_384

    static func catalog() throws -> [InferenceProviderDescriptor] {
        var output = [CChar](repeating: 0, count: outputCapacity)
        let status = output.withUnsafeMutableBufferPointer { output in
            tuistCodeInferenceProviderCatalog(output.baseAddress!, output.count)
        }
        try InferenceProviderStoreError.throwIfFailure(status)
        return try JSONDecoder().decode(
            [InferenceProviderDescriptor].self,
            from: Data(String(cString: output).utf8)
        )
    }

    static func connections(in storageDirectory: URL) throws -> [InferenceProviderConnection] {
        var output = [CChar](repeating: 0, count: outputCapacity)
        let status = storageDirectory.path.withCString { storageDirectory in
            output.withUnsafeMutableBufferPointer { output in
                tuistCodeInferenceProviderConnections(
                    storageDirectory,
                    output.baseAddress!,
                    output.count
                )
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
        return try JSONDecoder().decode(
            [InferenceProviderConnection].self,
            from: Data(String(cString: output).utf8)
        )
    }

    static func accounts(in storageDirectory: URL) throws -> [InferenceAccount] {
        var output = [CChar](repeating: 0, count: outputCapacity)
        let status = storageDirectory.path.withCString { storageDirectory in
            output.withUnsafeMutableBufferPointer { output in
                tuistCodeInferenceAccounts(
                    storageDirectory,
                    output.baseAddress!,
                    output.count
                )
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
        return try JSONDecoder().decode(
            [InferenceAccount].self,
            from: Data(String(cString: output).utf8)
        )
    }

    static func save(
        _ provider: InferenceProviderDescriptor,
        state: InferenceProviderConnectionState,
        in storageDirectory: URL
    ) throws {
        let status = storageDirectory.path.withCString { storageDirectory in
            provider.id.withCString { providerID in
                state.rawValue.withCString { state in
                    tuistCodeSaveInferenceProviderConnection(storageDirectory, providerID, state)
                }
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
    }

    static func remove(_ provider: InferenceProviderDescriptor, in storageDirectory: URL) throws {
        let status = storageDirectory.path.withCString { storageDirectory in
            provider.id.withCString { providerID in
                tuistCodeRemoveInferenceProviderConnection(storageDirectory, providerID)
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
    }

    static func save(_ account: InferenceAccount, in storageDirectory: URL) throws {
        let status = storageDirectory.path.withCString { storageDirectory in
            account.id.withCString { accountID in
                account.providerID.withCString { providerID in
                    account.name.withCString { name in
                        account.state.rawValue.withCString { state in
                            tuistCodeSaveInferenceAccount(
                                storageDirectory,
                                accountID,
                                providerID,
                                name,
                                state
                            )
                        }
                    }
                }
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
    }

    static func remove(_ account: InferenceAccount, in storageDirectory: URL) throws {
        let status = storageDirectory.path.withCString { storageDirectory in
            account.id.withCString { accountID in
                tuistCodeRemoveInferenceAccount(storageDirectory, accountID)
            }
        }
        try InferenceProviderStoreError.throwIfFailure(status)
    }
}

struct InferenceProviderDescriptor: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let authentication: InferenceProviderAuthentication
    let models: [InferenceModel]

    var symbolName: String {
        switch id {
        case "together": "person.2"
        case "fireworks": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "cpu"
        }
    }
}

enum InferenceProviderAuthentication: String, Codable {
    case apiKey = "api_key"
    case oauth

    var addActionTitle: String {
        switch self {
        case .apiKey: "Add API Key"
        case .oauth: "Sign in"
        }
    }
}

struct InferenceModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let reasoningEfforts: [InferenceReasoningEffort]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case reasoningEfforts = "reasoning_efforts"
    }
}

enum InferenceReasoningEffort: String, Codable, CaseIterable, Identifiable, Hashable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Maximum"
        case .ultra: "Ultra"
        }
    }
}

struct InferenceAccount: Codable, Identifiable, Hashable {
    let id: String
    let providerID: String
    let name: String
    let state: InferenceProviderConnectionState

    enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider_id"
        case name
        case state
    }
}

private struct InferenceProviderConnection: Codable, Identifiable, Hashable {
    let id: String
    let state: InferenceProviderConnectionState
}

enum InferenceProviderConnectionState: String, Codable {
    case requiresAuthorization = "requires_authorization"
    case authorizing
    case configured

    var title: String {
        switch self {
        case .requiresAuthorization: "Authentication required"
        case .authorizing: "Waiting for sign in"
        case .configured: "Connected"
        }
    }
}

private enum InferenceProviderStoreError: LocalizedError {
    case invalidInput
    case storageUnavailable
    case outputBufferTooSmall
    case codexUnavailable

    init(status: Int32) {
        switch status {
        case 1: self = .invalidInput
        case 2: self = .storageUnavailable
        case 3: self = .outputBufferTooSmall
        default: self = .invalidInput
        }
    }

    static func throwIfFailure(_ status: Int32) throws {
        guard status == 0 else { throw Self(status: status) }
    }

    var errorDescription: String? {
        switch self {
        case .invalidInput: "This provider configuration is invalid."
        case .storageUnavailable: "Tuist Code could not save the provider configuration."
        case .outputBufferTooSmall: "The provider configuration is too large."
        case .codexUnavailable: "Codex is not installed."
        }
    }
}

private enum InferenceModelCatalogError: LocalizedError {
    case unsupportedProvider
    case requestFailed
    case invalidResponse
    case codexAppServerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "This provider does not publish a model catalog."
        case .requestFailed: "The provider could not load its models for this account."
        case .invalidResponse: "The provider returned an invalid model catalog."
        case .codexAppServerUnavailable: "Codex did not return its available models."
        }
    }
}

#if os(macOS)
private enum CodexInstallation {
    static var executableURL: URL? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
#endif

/// Loads the model catalog owned by an application-programming-interface-key provider.
///
/// The account registry intentionally stores no model inventory. Provider model
/// availability changes independently of app releases, so the native client
/// fetches it for the authenticated account at the point of use.
private enum InferenceModelCatalogClient {
    static func models(for providerID: String, credential: String) async throws -> [InferenceModel] {
        let endpoint: URL
        switch providerID {
        case "together":
            endpoint = URL(string: "https://api.together.ai/v1/models")!
        case "fireworks":
            endpoint = URL(string: "https://api.fireworks.ai/inference/v1/models")!
        default:
            throw InferenceModelCatalogError.unsupportedProvider
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw InferenceModelCatalogError.requestFailed
        }

        let object = try JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let foundRecords = object as? [[String: Any]] {
            records = foundRecords
        } else if let dictionary = object as? [String: Any],
                  let models = (dictionary["data"] ?? dictionary["models"]) as? [[String: Any]]
        {
            records = models
        } else {
            throw InferenceModelCatalogError.invalidResponse
        }

        return records.compactMap { record in
            guard let id = record["id"] as? String ?? record["name"] as? String,
                  !id.isEmpty
            else {
                return nil
            }

            let name = (record["display_name"] as? String)
                ?? (record["displayName"] as? String)
                ?? (record["name"] as? String)
                ?? id
            let efforts = reasoningEfforts(in: record)
            return InferenceModel(
                id: id,
                name: name,
                reasoningEfforts: efforts.isEmpty ? [.none] : efforts
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func reasoningEfforts(in record: [String: Any]) -> [InferenceReasoningEffort] {
        let rawValues = (record["reasoning_efforts"] as? [String])
            ?? (record["reasoningEfforts"] as? [String])
            ?? (record["supported_reasoning_efforts"] as? [String])
            ?? (record["supportedReasoningEfforts"] as? [String])
            ?? []
        return rawValues.compactMap(InferenceReasoningEffort.init(rawValue:))
    }
}

#if os(macOS)
/// Reads the catalog from the authenticated local Codex application server.
///
/// Codex itself owns the account session and knows which models and reasoning
/// levels it has granted. Asking its local server avoids duplicating that
/// provider-specific policy in Tuist Code.
private enum CodexModelCatalogClient {
    static func models(using executableURL: URL) async throws -> [InferenceModel] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try loadModels(using: executableURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadModels(using executableURL: URL) throws -> [InferenceModel] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Tuist Code","version":"1.0"},"capabilities":{}}}"#
        let listModels = #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"#
        input.fileHandleForWriting.write(Data((initialize + "\n").utf8))
        Thread.sleep(forTimeInterval: 0.5)
        input.fileHandleForWriting.write(Data((listModels + "\n").utf8))

        // `model/list` can require the local Codex service to refresh account
        // state. Keep standard input open long enough for that response, then
        // close it to make the one-shot application-server process terminate.
        Thread.sleep(forTimeInterval: 4)
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let decoder = JSONDecoder()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let response = try? decoder.decode(ModelListResponse.self, from: Data(line.utf8)),
                  response.id == 2,
                  let models = response.result?.data
            else {
                continue
            }

            return models.map { model in
                let efforts = model.supportedReasoningEfforts.compactMap {
                    InferenceReasoningEffort(rawValue: $0.reasoningEffort)
                }
                return InferenceModel(
                    id: model.id,
                    name: model.displayName,
                    reasoningEfforts: efforts.isEmpty ? [.none] : efforts
                )
            }
        }

        throw InferenceModelCatalogError.codexAppServerUnavailable
    }

    private struct ModelListResponse: Decodable {
        let id: Int?
        let result: ModelListResult?
    }

    private struct ModelListResult: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
        let displayName: String
        let supportedReasoningEfforts: [ReasoningEffort]
    }

    private struct ReasoningEffort: Decodable {
        let reasoningEffort: String
    }
}
#endif

@MainActor
final class InferenceAccountStore: ObservableObject {
    @Published private(set) var catalog = [InferenceProviderDescriptor]()
    @Published private(set) var accounts = [InferenceAccount]()
    @Published private(set) var modelsByAccountID = [InferenceAccount.ID: [InferenceModel]]()
    @Published private(set) var refreshingModelAccountIDs = Set<InferenceAccount.ID>()
    @Published var errorMessage: String?
    @Published private(set) var authorizationURL: URL?
    @Published private(set) var authorizationDeviceCode: String?
    @Published private(set) var authorizationDeviceCodeExpiration: String?

    private let storageDirectory: URL
    private let credentialStore = InferenceProviderCredentialStore()
    private var authorizationOutput = ""
    #if os(macOS)
    private var authorizationProcess: Process?
    private var authorizationOutputPipe: Pipe?
    #endif

    init() {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        storageDirectory = applicationSupportDirectory.appendingPathComponent(
            "Tuist Code",
            isDirectory: true
        )
        errorMessage = nil
        reload()
        recoverInterruptedAuthorization()
    }

    var configuredAccounts: [InferenceAccount] {
        accounts.filter { $0.state == .configured }
    }

    func models(for account: InferenceAccount) -> [InferenceModel] {
        modelsByAccountID[account.id] ?? []
    }

    func isRefreshingModels(for account: InferenceAccount) -> Bool {
        refreshingModelAccountIDs.contains(account.id)
    }

    func credential(for account: InferenceAccount) -> String? {
        try? credentialStore.credential(for: account.id)
    }

    func refreshModels(for account: InferenceAccount) {
        guard account.state == .configured,
              !refreshingModelAccountIDs.contains(account.id)
        else {
            return
        }

        refreshingModelAccountIDs.insert(account.id)
        Task {
            defer { refreshingModelAccountIDs.remove(account.id) }

            do {
                let models: [InferenceModel]
                switch account.providerID {
                case "codex":
                    #if os(macOS)
                    guard let executableURL = CodexInstallation.executableURL else {
                        throw InferenceProviderStoreError.codexUnavailable
                    }
                    models = try await CodexModelCatalogClient.models(using: executableURL)
                    #else
                    models = []
                    #endif
                case "together", "fireworks":
                    let credential = try credentialStore.credential(for: account.id)
                    models = try await InferenceModelCatalogClient.models(
                        for: account.providerID,
                        credential: credential
                    )
                default:
                    models = []
                }
                modelsByAccountID[account.id] = models
            } catch {
                modelsByAccountID[account.id] = []
            }
        }
    }

    func provider(for account: InferenceAccount) -> InferenceProviderDescriptor? {
        catalog.first(where: { $0.id == account.providerID })
    }

    @discardableResult
    func configureAPIKey(
        _ apiKey: String,
        named name: String,
        for provider: InferenceProviderDescriptor
    ) -> Bool {
        guard provider.authentication == .apiKey else { return false }
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !name.isEmpty else { return false }

        let account = InferenceAccount(
            id: UUID().uuidString.lowercased(),
            providerID: provider.id,
            name: name,
            state: .configured
        )

        do {
            try credentialStore.save(apiKey, for: account.id)
            try SharedInferenceProviderRegistry.save(account, in: storageDirectory)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func beginOAuth(named name: String, for provider: InferenceProviderDescriptor) -> Bool {
        guard provider.authentication == .oauth, provider.id == "codex" else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        let account = InferenceAccount(
            id: UUID().uuidString.lowercased(),
            providerID: provider.id,
            name: name,
            state: .authorizing
        )

        return beginOAuth(for: account, provider: provider)
    }

    @discardableResult
    func reauthenticate(_ account: InferenceAccount, with provider: InferenceProviderDescriptor) -> Bool {
        guard account.state != .authorizing else { return false }
        return beginOAuth(for: account, provider: provider)
    }

    func cancelAuthorization(for accountID: InferenceAccount.ID) {
        #if os(macOS)
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.state == .authorizing
        else {
            return
        }

        authorizationOutputPipe?.fileHandleForReading.readabilityHandler = nil
        authorizationOutputPipe = nil
        let process = authorizationProcess
        authorizationProcess = nil
        process?.terminate()
        resetAuthorizationDetails()

        do {
            try SharedInferenceProviderRegistry.save(
                InferenceAccount(
                    id: account.id,
                    providerID: account.providerID,
                    name: account.name,
                    state: .requiresAuthorization
                ),
                in: storageDirectory
            )
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    @discardableResult
    private func beginOAuth(
        for account: InferenceAccount,
        provider: InferenceProviderDescriptor
    ) -> Bool {
        guard provider.authentication == .oauth, provider.id == "codex" else { return false }

        let authorizingAccount = InferenceAccount(
            id: account.id,
            providerID: account.providerID,
            name: account.name,
            state: .authorizing
        )

        #if os(macOS)
        do {
            try SharedInferenceProviderRegistry.save(authorizingAccount, in: storageDirectory)
            reload()
            resetAuthorizationDetails()

            guard let executableURL = CodexInstallation.executableURL else {
                throw InferenceProviderStoreError.codexUnavailable
            }

            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["login", "--device-auth"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let output = String(data: data, encoding: .utf8)
                else {
                    return
                }
                Task { @MainActor in
                    self?.recordAuthorizationOutput(output)
                }
            }
            process.terminationHandler = { [weak self, outputPipe] process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let remainingOutput = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )
                Task { @MainActor in
                    guard let self,
                          let currentProcess = self.authorizationProcess,
                          currentProcess === process
                    else {
                        return
                    }

                    if let remainingOutput, !remainingOutput.isEmpty {
                        self.recordAuthorizationOutput(remainingOutput)
                    }
                    self.authorizationOutputPipe = nil
                    self.authorizationProcess = nil
                    let succeeded = process.terminationStatus == 0
                    self.completeOAuth(for: authorizingAccount, succeeded: succeeded)
                    if !succeeded {
                        self.errorMessage = "Codex sign in did not complete. Try again."
                    }
                }
            }
            try process.run()
            authorizationProcess = process
            authorizationOutputPipe = outputPipe
            return true
        } catch {
            errorMessage = "Codex sign in could not start. Install Codex and try again."
            try? SharedInferenceProviderRegistry.save(
                InferenceAccount(
                    id: authorizingAccount.id,
                    providerID: authorizingAccount.providerID,
                    name: authorizingAccount.name,
                    state: .requiresAuthorization
                ),
                in: storageDirectory
            )
            reload()
            return false
        }
        #else
        errorMessage = "Codex sign in is currently available in the macOS app."
        return false
        #endif
    }

    func remove(_ account: InferenceAccount) {
        do {
            try SharedInferenceProviderRegistry.remove(account, in: storageDirectory)
            credentialStore.removeCredential(for: account.id)
            if account.id.hasPrefix("legacy-") {
                credentialStore.removeCredential(for: account.providerID)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeOAuth(for account: InferenceAccount, succeeded: Bool) {
        #if os(macOS)
        authorizationProcess = nil
        authorizationOutputPipe = nil
        #endif
        do {
            try SharedInferenceProviderRegistry.save(
                InferenceAccount(
                    id: account.id,
                    providerID: account.providerID,
                    name: account.name,
                    state: succeeded ? .configured : .requiresAuthorization
                ),
                in: storageDirectory
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func recordAuthorizationOutput(_ output: String) {
        authorizationOutput = String(
            (authorizationOutput + Self.strippingTerminalControlSequences(from: output)).suffix(8_000)
        )

        if authorizationURL == nil,
           let detector = try? NSDataDetector(
               types: NSTextCheckingResult.CheckingType.link.rawValue
           )
        {
            let range = NSRange(authorizationOutput.startIndex..<authorizationOutput.endIndex, in: authorizationOutput)
            authorizationURL = detector.firstMatch(
                in: authorizationOutput,
                options: [],
                range: range
            )?.url
        }

        if authorizationDeviceCode == nil {
            authorizationDeviceCode = Self.firstMatch(
                in: authorizationOutput,
                pattern: #"\b[A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+\b"#
            )
        }

        if authorizationDeviceCodeExpiration == nil {
            authorizationDeviceCodeExpiration = Self.firstMatch(
                in: authorizationOutput,
                pattern: #"\(expires in ([^)]+)\)"#,
                captureGroup: 1
            )
        }
    }

    private func resetAuthorizationDetails() {
        authorizationOutput = ""
        authorizationURL = nil
        authorizationDeviceCode = nil
        authorizationDeviceCodeExpiration = nil
    }

    private static func strippingTerminalControlSequences(from output: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        ) else {
            return output
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return expression.stringByReplacingMatches(
            in: output,
            range: range,
            withTemplate: ""
        )
    }

    private static func firstMatch(
        in string: String,
        pattern: String,
        captureGroup: Int = 0
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = expression.firstMatch(in: string, range: range),
              match.numberOfRanges > captureGroup,
              let matchRange = Range(match.range(at: captureGroup), in: string)
        else {
            return nil
        }
        return String(string[matchRange])
    }

    private func recoverInterruptedAuthorization() {
        let interruptedAccounts = accounts.filter { $0.state == .authorizing }
        guard !interruptedAccounts.isEmpty else { return }

        do {
            for account in interruptedAccounts {
                try SharedInferenceProviderRegistry.save(
                    InferenceAccount(
                        id: account.id,
                        providerID: account.providerID,
                        name: account.name,
                        state: .requiresAuthorization
                    ),
                    in: storageDirectory
                )
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        do {
            catalog = try SharedInferenceProviderRegistry.catalog()
            accounts = try SharedInferenceProviderRegistry.accounts(in: storageDirectory)
            modelsByAccountID = modelsByAccountID.filter { accountID, _ in
                accounts.contains(where: { $0.id == accountID && $0.state == .configured })
            }
            configuredAccounts.forEach(refreshModels)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private final class InferenceProviderCredentialStore {
    private let service = "dev.tuist.code.inference-providers"

    func save(_ credential: String, for providerID: String) throws {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerID,
        ] as CFDictionary
        let attributes = [kSecValueData: Data(credential.utf8)] as CFDictionary
        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: providerID,
                kSecValueData: Data(credential.utf8),
            ] as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw InferenceProviderCredentialStoreError.unavailable }
        } else if updateStatus != errSecSuccess {
            throw InferenceProviderCredentialStoreError.unavailable
        }
    }

    func credential(for accountID: String) throws -> String {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let credential = String(data: data, encoding: .utf8)
        else {
            throw InferenceProviderCredentialStoreError.unavailable
        }

        return credential
    }

    func removeCredential(for providerID: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerID,
        ] as CFDictionary)
    }
}

private enum InferenceProviderCredentialStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Tuist Code could not save this provider credential securely."
    }
}

private enum SharedCapabilityService {
    static func remoteSessionsAreAvailable(for authenticationState: AuthenticationState) -> Bool {
        tuistCodeCapabilityIsAvailable(authenticationState.rawValue, 2) != 0
    }
}

private enum ProjectOperationError: LocalizedError {
    case invalidInput
    case notGitRepository
    case invalidDestination
    case destinationExists
    case gitUnavailable
    case cloneFailed
    case outputBufferTooSmall

    init(status: Int32) {
        switch status {
        case 1:
            self = .invalidInput
        case 2:
            self = .notGitRepository
        case 3:
            self = .invalidDestination
        case 4:
            self = .destinationExists
        case 5:
            self = .gitUnavailable
        case 6:
            self = .cloneFailed
        case 7:
            self = .outputBufferTooSmall
        default:
            self = .invalidInput
        }
    }

    static func throwIfFailure(_ status: Int32) throws {
        guard status != 0 else { return }
        throw Self(status: status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Enter a valid repository URL or directory."
        case .notGitRepository:
            "Choose a folder that contains a Git repository."
        case .invalidDestination:
            "Choose an existing destination folder for the clone."
        case .destinationExists:
            "A folder for this repository already exists at the selected destination."
        case .gitUnavailable:
            "Git is unavailable on this device."
        case .cloneFailed:
            "Tuist Code could not clone the repository."
        case .outputBufferTooSmall:
            "The cloned repository path is too long."
        }
    }
}

private enum WorktreeOperationError: LocalizedError {
    case invalidInput
    case notGitRepository
    case invalidDestination
    case destinationExists
    case gitUnavailable
    case creationFailed
    case outputBufferTooSmall

    init(status: Int32) {
        switch status {
        case 1:
            self = .invalidInput
        case 2:
            self = .notGitRepository
        case 3:
            self = .invalidDestination
        case 4:
            self = .destinationExists
        case 5:
            self = .gitUnavailable
        case 6:
            self = .creationFailed
        case 7:
            self = .outputBufferTooSmall
        default:
            self = .invalidInput
        }
    }

    static func throwIfFailure(_ status: Int32) throws {
        guard status != 0 else { return }
        throw Self(status: status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Enter a valid new branch name."
        case .notGitRepository:
            "This project is no longer a Git repository."
        case .invalidDestination:
            "Choose an existing folder for the new worktree."
        case .destinationExists:
            "A worktree folder with this branch name already exists there."
        case .gitUnavailable:
            "Git is unavailable on this device."
        case .creationFailed:
            "Tuist Code could not create the worktree. Check that the branch name is new."
        case .outputBufferTooSmall:
            "The worktree path is too long."
        }
    }
}

@MainActor
private final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] {
        didSet { saveWorkspaces() }
    }
    @Published var errorMessage: String?

    private static let storageKey = "tuist-code-workspaces"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let storedWorkspaces = try? JSONDecoder().decode([Workspace].self, from: data),
           !storedWorkspaces.isEmpty
        {
            workspaces = storedWorkspaces
        } else {
            workspaces = [Workspace(name: "Tuist")]
        }
        errorMessage = nil
    }

    @discardableResult
    func addWorkspace(named name: String) -> Workspace {
        let workspace = Workspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        workspaces.append(workspace)
        return workspace
    }

    func addLocalProject(at directoryURL: URL, to workspaceID: Workspace.ID) -> LocalProject? {
        do {
            try SharedProjectService.validateGitRepository(at: directoryURL)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        return registerProject(at: directoryURL, to: workspaceID)
    }

    func cloneRepository(
        _ remote: String,
        into destinationParent: URL,
        workspaceID: Workspace.ID
    ) -> LocalProject? {
        let projectURL: URL
        do {
            projectURL = try SharedProjectService.cloneRepository(
                remote: remote,
                into: destinationParent
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        return registerProject(at: projectURL, to: workspaceID)
    }

    @discardableResult
    func createWorktree(
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID
    ) -> ProjectWorktree? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID })
        else {
            return nil
        }

        let repositoryURL = URL(
            fileURLWithPath: workspaces[workspaceIndex].projects[projectIndex].directoryPath
        )
        let worktreeURL: URL
        do {
            worktreeURL = try SharedProjectService.createDefaultSessionWorktree(in: repositoryURL)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let worktree = ProjectWorktree(
            name: worktreeURL.lastPathComponent,
            branch: worktreeURL.lastPathComponent,
            directoryPath: worktreeURL.path,
            sessions: [AgentSession(title: "New session", createdAt: Date())]
        )
        workspaces[workspaceIndex].projects[projectIndex].worktrees.append(worktree)
        return worktree
    }

    @discardableResult
    func createSession(
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID
    ) -> AgentSession? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID }),
              let worktreeIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees.firstIndex(where: {
                  $0.id == worktreeID
              })
        else {
            return nil
        }

        let session = AgentSession(title: "New session", createdAt: Date())
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.append(session)
        return session
    }

    func session(
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID
    ) -> AgentSession? {
        workspaces.first(where: { $0.id == workspaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?
            .sessions.first(where: { $0.id == sessionID })
    }

    func isOnlySession(
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID
    ) -> Bool {
        workspaces.first(where: { $0.id == workspaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?
            .sessions.count == 1
    }

    @discardableResult
    func deleteSession(
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID
    ) -> Bool {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID }),
              let worktreeIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees.firstIndex(where: {
                  $0.id == worktreeID
              }),
              let sessionIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.firstIndex(where: {
                  $0.id == sessionID
              })
        else {
            return false
        }

        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.remove(at: sessionIndex)
        return true
    }

    func startAgentSession(
        prompt: String,
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID,
        configuration: AgentSessionInferenceConfiguration
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID }),
              let worktreeIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees.firstIndex(where: {
                  $0.id == worktreeID
              }),
              let sessionIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.firstIndex(where: {
                  $0.id == sessionID
              })
        else {
            return
        }

        let canRenameWorktree = workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.count == 1
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions[sessionIndex].initialPrompt = prompt
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions[sessionIndex].inferenceConfiguration = configuration
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions[sessionIndex].agentPrompt =
            AgentSessionTools.prompt(
                for: prompt,
                configuration: configuration,
                canRenameWorktree: canRenameWorktree
            )
    }

    /// Handles the agent's `rename_session` tool call.
    @discardableResult
    func renameSession(
        title: String,
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID
    ) -> AgentSession? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID }),
              let worktree = workspaces[workspaceIndex].projects[projectIndex].worktrees.first(where: {
                  $0.id == worktreeID
              })
        else {
            return nil
        }

        return renameSessionAndWorktree(
            title: title,
            worktreeName: worktree.name,
            in: workspaceID,
            projectID: projectID,
            worktreeID: worktreeID,
            sessionID: sessionID
        )
    }

    /// Handles the agent's `rename_session_and_worktree` tool call.
    ///
    /// The session title is saved by the application while Rust validates the
    /// title and moves the Git worktree, so the operation remains usable from
    /// every native client.
    @discardableResult
    func renameSessionAndWorktree(
        title: String,
        worktreeName: String,
        in workspaceID: Workspace.ID,
        projectID: LocalProject.ID,
        worktreeID: ProjectWorktree.ID,
        sessionID: AgentSession.ID
    ) -> AgentSession? {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let projectIndex = workspaces[workspaceIndex].projects.firstIndex(where: { $0.id == projectID }),
              let worktreeIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees.firstIndex(where: {
                  $0.id == worktreeID
              }),
              let sessionIndex = workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions.firstIndex(where: {
                  $0.id == sessionID
              })
        else {
            return nil
        }

        let currentWorktree = workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex]
        let requestedWorktreeName = worktreeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentWorktree.sessions.count > 1, requestedWorktreeName != currentWorktree.name {
            errorMessage = "This worktree is shared by multiple sessions and cannot be renamed from one session."
            return nil
        }

        let repositoryURL = URL(
            fileURLWithPath: workspaces[workspaceIndex].projects[projectIndex].directoryPath
        )
        let currentWorktreeURL = URL(
            fileURLWithPath: workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].directoryPath
        )
        let renamedWorktreeURL: URL
        do {
            renamedWorktreeURL = try SharedProjectService.renameSessionWorktree(
                in: repositoryURL,
                currentWorktree: currentWorktreeURL,
                sessionTitle: title,
                newWorktreeName: worktreeName
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions[sessionIndex].title = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].name = requestedWorktreeName
        workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].directoryPath = renamedWorktreeURL.path
        return workspaces[workspaceIndex].projects[projectIndex].worktrees[worktreeIndex].sessions[sessionIndex]
    }

    private func registerProject(at directoryURL: URL, to workspaceID: Workspace.ID) -> LocalProject? {
        let directoryPath = directoryURL.standardizedFileURL.path

        if let existingWorkspace = workspaces.first(where: {
            $0.projects.contains(where: { $0.directoryPath == directoryPath })
        }) {
            errorMessage = "This repository is already in the \(existingWorkspace.name) workspace."
            return nil
        }

        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }

        let project = LocalProject(name: directoryURL.lastPathComponent, directoryPath: directoryPath)
        workspaces[workspaceIndex].projects.append(project)
        return project
    }

    private func saveWorkspaces() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

private struct Workspace: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var projects: [LocalProject]

    init(name: String, projects: [LocalProject] = []) {
        id = UUID()
        self.name = name
        self.projects = projects
    }
}

private struct LocalProject: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let directoryPath: String
    var worktrees: [ProjectWorktree]

    init(name: String, directoryPath: String, worktrees: [ProjectWorktree] = []) {
        id = UUID()
        self.name = name
        self.directoryPath = directoryPath
        self.worktrees = worktrees
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case directoryPath
        case worktrees
        case sessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        directoryPath = try container.decode(String.self, forKey: .directoryPath)
        if let worktrees = try container.decodeIfPresent([ProjectWorktree].self, forKey: .worktrees) {
            self.worktrees = worktrees
        } else {
            let legacySessions = try container.decodeIfPresent([LegacyAgentSession].self, forKey: .sessions) ?? []
            worktrees = legacySessions.map(ProjectWorktree.init(legacySession:))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(directoryPath, forKey: .directoryPath)
        try container.encode(worktrees, forKey: .worktrees)
    }
}

private struct AgentSessionTarget: Hashable {
    let workspaceID: Workspace.ID
    let projectID: LocalProject.ID
    let worktreeID: ProjectWorktree.ID
    let sessionID: AgentSession.ID
}

private struct ProjectWorktree: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let branch: String
    var directoryPath: String
    let createdAt: Date
    var sessions: [AgentSession]

    init(
        name: String,
        branch: String,
        directoryPath: String,
        createdAt: Date = Date(),
        sessions: [AgentSession] = []
    ) {
        id = UUID()
        self.name = name
        self.branch = branch
        self.directoryPath = directoryPath
        self.createdAt = createdAt
        self.sessions = sessions
    }

    init(legacySession: LegacyAgentSession) {
        id = UUID()
        name = URL(fileURLWithPath: legacySession.worktreePath).lastPathComponent.nonEmpty ?? legacySession.title
        branch = legacySession.branch
        directoryPath = legacySession.worktreePath
        createdAt = legacySession.createdAt
        sessions = [
            AgentSession(
                id: legacySession.id,
                title: legacySession.title,
                createdAt: legacySession.createdAt,
                initialPrompt: legacySession.initialPrompt,
                agentPrompt: legacySession.agentPrompt
            ),
        ]
    }
}

private struct AgentSession: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var initialPrompt: String?
    var agentPrompt: String?
    var inferenceConfiguration: AgentSessionInferenceConfiguration?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        initialPrompt: String? = nil,
        agentPrompt: String? = nil,
        inferenceConfiguration: AgentSessionInferenceConfiguration? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.initialPrompt = initialPrompt
        self.agentPrompt = agentPrompt
        self.inferenceConfiguration = inferenceConfiguration
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case initialPrompt
        case agentPrompt
        case inferenceConfiguration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        initialPrompt = try container.decodeIfPresent(String.self, forKey: .initialPrompt)
        agentPrompt = try container.decodeIfPresent(String.self, forKey: .agentPrompt)
        inferenceConfiguration = try container.decodeIfPresent(
            AgentSessionInferenceConfiguration.self,
            forKey: .inferenceConfiguration
        )
    }
}

private struct AgentSessionInferenceConfiguration: Codable, Hashable {
    let accountID: InferenceAccount.ID
    let providerID: String
    let modelID: String
    let reasoningEffort: InferenceReasoningEffort
}

private struct LegacyAgentSession: Decodable {
    let id: UUID
    let title: String
    let branch: String
    let worktreePath: String
    let createdAt: Date
    let initialPrompt: String?
    let agentPrompt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case branch
        case worktreePath
        case createdAt
        case initialPrompt
        case agentPrompt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? title
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        initialPrompt = try container.decodeIfPresent(String.self, forKey: .initialPrompt)
        agentPrompt = try container.decodeIfPresent(String.self, forKey: .agentPrompt)
    }
}

@MainActor
private final class AuthenticationService: NSObject, ObservableObject {
    @Published private(set) var state: AuthenticationState
    @Published private(set) var errorMessage: String?

    let configuration: TuistAuthenticationConfiguration

    private let tokenStore = TokenStore()
    private let presentationContextProvider = AuthenticationPresentationContextProvider()
    private var pendingAuthorization: PendingAuthorization?
    private var webAuthenticationSession: ASWebAuthenticationSession?

    private static let sessionPresencePrefix = "dev.tuist.code.authentication.session-present"

    override init() {
        configuration = TuistAuthenticationConfiguration.current
        state = .signedOut
        errorMessage = nil
        super.init()
        transition(
            UserDefaults.standard.bool(forKey: Self.sessionPresenceKey(for: configuration))
                ? .restoreAuthenticated
                : .restoreUnauthenticated
        )
    }

    func signIn() {
        let verifier = Self.codeVerifier()
        let pendingAuthorization = PendingAuthorization(
            verifier: verifier,
            state: UUID().uuidString
        )

        guard let authorizationURL = configuration.authorizationURL(
            state: pendingAuthorization.state,
            codeChallenge: Self.codeChallenge(for: verifier)
        ) else {
            fail("The Tuist origin is invalid.")
            return
        }

        self.pendingAuthorization = pendingAuthorization
        errorMessage = nil
        transition(.startSignIn)

        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: TuistAuthenticationConfiguration.callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.completeSignIn(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = presentationContextProvider
        session.prefersEphemeralWebBrowserSession = true
        webAuthenticationSession = session

        if !session.start() {
            self.pendingAuthorization = nil
            fail("Tuist could not start the sign-in session.")
        }
    }

    func signOut() {
        tokenStore.deleteTokens(for: configuration)
        UserDefaults.standard.set(false, forKey: Self.sessionPresenceKey(for: configuration))
        errorMessage = nil
        transition(.signOut)
    }

    private func completeSignIn(callbackURL: URL?, error: Error?) {
        defer { webAuthenticationSession = nil }

        if let error {
            pendingAuthorization = nil
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin
            {
                transition(.cancelled)
            } else {
                fail("Tuist could not start sign in. \(error.localizedDescription)")
            }
            return
        }

        guard
            let callbackURL,
            let pendingAuthorization,
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.scheme == TuistAuthenticationConfiguration.callbackScheme,
            components.host == "oauth-callback",
            components.queryItems?.first(where: { $0.name == "state" })?.value == pendingAuthorization.state,
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            self.pendingAuthorization = nil
            fail("Tuist returned an invalid sign-in response.")
            return
        }

        self.pendingAuthorization = nil

        Task {
            do {
                let tokens = try await Self.exchange(
                    code: code,
                    verifier: pendingAuthorization.verifier,
                    configuration: configuration
                )
                tokenStore.save(tokens, for: configuration)
                UserDefaults.standard.set(true, forKey: Self.sessionPresenceKey(for: configuration))
                errorMessage = nil
                transition(.signInSucceeded)
            } catch {
                fail("Tuist could not complete sign in. \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        transition(.signInFailed)
    }

    private static func sessionPresenceKey(for configuration: TuistAuthenticationConfiguration) -> String {
        "\(sessionPresencePrefix).\(configuration.origin.absoluteString)"
    }

    private func transition(_ event: AuthenticationEvent) {
        let nextState = tuistCodeAuthenticationStateAfter(state.rawValue, event.rawValue)
        guard let nextState = AuthenticationState(rawValue: nextState) else {
            assertionFailure("Rust returned an unknown authentication state")
            return
        }
        state = nextState
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func exchange(
        code: String,
        verifier: String,
        configuration: TuistAuthenticationConfiguration
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": TuistAuthenticationConfiguration.redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
        ]
        .map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }
        .sorted()
        .joined(separator: "&")
        .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AuthenticationError.tokenExchangeFailed
        }

        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }
}

private final class AuthenticationPresentationContextProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
        #else
        ASPresentationAnchor()
        #endif
    }
}

private enum AuthenticationState: Int32 {
    case signedOut = 0
    case authenticating = 1
    case authenticated = 2
    case failed = 3
}

private enum AuthenticationEvent: Int32 {
    case restoreUnauthenticated = 0
    case restoreAuthenticated = 1
    case startSignIn = 2
    case signInSucceeded = 3
    case signInFailed = 4
    case cancelled = 5
    case signOut = 6
}

private struct PendingAuthorization {
    let verifier: String
    let state: String
}

private struct OAuthTokens: Decodable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private enum AuthenticationError: LocalizedError {
    case tokenExchangeFailed

    var errorDescription: String? {
        "The server rejected the authorization code."
    }
}

private struct TuistAuthenticationConfiguration {
    static let defaultOrigin = URL(string: "https://tuist.dev")!
    static let defaultClientID = "b3298a92-3deb-4f5e-a526-b7ad324979b5"
    static let callbackScheme = "tuist"
    static let redirectURI = "tuist://oauth-callback"

    let origin: URL
    let clientID: String

    static var current: Self {
        let environment = ProcessInfo.processInfo.environment
        let origin = ProcessInfo.processInfo.argumentValue(named: "-tuist-origin")
            ?? environment["TUIST_ORIGIN"]
        let clientID = ProcessInfo.processInfo.argumentValue(named: "-tuist-oauth-client-id")
            ?? environment["TUIST_OAUTH_CLIENT_ID"]

        let selectedOrigin = Self.validOrigin(from: origin) ?? defaultOrigin
        return Self(
            origin: selectedOrigin,
            clientID: clientID?.nonEmpty ?? Self.defaultClientID(for: selectedOrigin)
        )
    }

    var tokenURL: URL {
        origin.appending(path: "oauth2/token")
    }

    func authorizationURL(state: String, codeChallenge: String) -> URL? {
        var components = URLComponents(
            url: origin.appending(path: "oauth2/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    private static func validOrigin(from value: String?) -> URL? {
        guard
            let value,
            var components = URLComponents(string: value),
            components.scheme == "https" || components.scheme == "http",
            components.host != nil,
            components.user == nil,
            components.password == nil
        else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func defaultClientID(for origin: URL) -> String {
        switch origin.absoluteString {
        case "https://staging.tuist.dev": "bcb85209-0cef-4acd-8dd4-e0d1c5e5e09a"
        case "https://canary.tuist.dev": "ca49d1d6-acaf-4eaa-b866-774b799044db"
        case "http://localhost:8080": "5339abf2-467c-4690-b816-17246ed149d2"
        default: defaultClientID
        }
    }
}

private final class TokenStore {
    private let service = "dev.tuist.code.authentication"

    func accessToken(for configuration: TuistAuthenticationConfiguration) -> String? {
        read(account: account(named: "access_token", for: configuration))
    }

    func save(_ tokens: OAuthTokens, for configuration: TuistAuthenticationConfiguration) {
        save(tokens.accessToken, account: account(named: "access_token", for: configuration))
        save(tokens.refreshToken, account: account(named: "refresh_token", for: configuration))
    }

    func deleteTokens(for configuration: TuistAuthenticationConfiguration) {
        delete(account: account(named: "access_token", for: configuration))
        delete(account: account(named: "refresh_token", for: configuration))
    }

    private func account(named token: String, for configuration: TuistAuthenticationConfiguration) -> String {
        "\(configuration.origin.absoluteString).\(token)"
    }

    private func read(account: String) -> String? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary

        var result: CFTypeRef?
        guard SecItemCopyMatching(query, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, account: String) {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary
        let attributes = [kSecValueData: Data(value.utf8)] as CFDictionary

        if SecItemUpdate(query, attributes) == errSecItemNotFound {
            SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: Data(value.utf8),
            ] as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) ?? self
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension CharacterSet {
    static let oauthFormAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}

private extension ProcessInfo {
    func argumentValue(named name: String) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
