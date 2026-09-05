import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

#if os(iOS)
import SwiftUI
#endif

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

#if os(iOS)
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
#endif

/// The capability supplied to an agent as soon as a local session begins.
///
/// The agent runner can use `prompt(for:)` as its system context and bind this
/// definition to `WorkspaceStore.renameSessionAndWorktree`. Keeping the
/// capability separate from the user-interface view makes the same contract portable
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

#if os(iOS)
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
#endif

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

/// Bridges the headless Rust agent process to the native user interface. It forwards JSON Lines
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

#if os(iOS)
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
#endif

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

#if os(macOS)
@MainActor
final class AppKitMainWindowController: NSWindowController, NSToolbarDelegate {
    private let workspaceStore = WorkspaceStore()
    private let accountStore = InferenceAccountStore()
    private let runtimeStore = AgentSessionRuntimeStore()
    private let authentication = AuthenticationService()
    private let splitViewController = NSSplitViewController()
    private let sidebarController = AppKitWorkspaceSidebarViewController()
    private var detailController: NSViewController?
    private var settingsWindowController: AppKitSettingsWindowController?
    private var selectedWorkspaceID: Workspace.ID?
    private var selectedProjectIDs = [Workspace.ID: LocalProject.ID]()
    private var activeSessionTarget: AgentSessionTarget?
    private weak var cloneDestinationField: NSTextField?
    private var cancellables = Set<AnyCancellable>()

    private static let addToolbarIdentifier = NSToolbarItem.Identifier("dev.tuist.code.toolbar.add")
    private static let accountToolbarIdentifier = NSToolbarItem.Identifier("dev.tuist.code.toolbar.account")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(cString: tuistCodeAppName())
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        super.init(window: window)

        configureSplitView()
        configureToolbar()
        observeStores()
        applyStoredAppearance()

        selectedWorkspaceID = workspaceStore.workspaces.first?.id
        sidebarController.render(workspaces: workspaceStore.workspaces, selecting: .workspace(selectedWorkspaceID))
        showProjectOverview()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    @objc func newWorkspace(_: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Workspace"
        alert.informativeText = "Create a workspace to organize related repositories."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Workspace name"
        nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let workspace = workspaceStore.addWorkspace(named: name)
        selectedWorkspaceID = workspace.id
        activeSessionTarget = nil
        sidebarController.render(workspaces: workspaceStore.workspaces, selecting: .workspace(workspace.id))
        showProjectOverview()
    }

    @objc func addLocalRepository(_: Any?) {
        guard let workspaceID = selectedWorkspaceID else {
            showMessage("Select a workspace before adding a repository.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add Local Repository"
        panel.message = "Choose a folder that contains a Git repository."
        panel.prompt = "Add Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        guard let project = workspaceStore.addLocalProject(at: directoryURL, to: workspaceID) else {
            presentWorkspaceError()
            return
        }
        selectedProjectIDs[workspaceID] = project.id
        activeSessionTarget = nil
        sidebarController.render(
            workspaces: workspaceStore.workspaces,
            selecting: .project(workspaceID: workspaceID, projectID: project.id)
        )
        showProjectOverview()
    }

    @objc func cloneRepository(_: Any?) {
        guard let workspaceID = selectedWorkspaceID else {
            showMessage("Select a workspace before cloning a repository.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clone Repository"
        alert.informativeText = "Enter a remote repository address and choose its parent folder."
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let remoteField = NSTextField(string: "")
        remoteField.placeholderString = "https://github.com/organization/repository.git"
        let destinationField = NSTextField(string: FileManager.default.homeDirectoryForCurrentUser.path)
        destinationField.placeholderString = "Destination parent folder"
        let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
        let destinationRow = NSStackView(views: [destinationField, chooseButton])
        destinationRow.orientation = .horizontal
        destinationRow.spacing = 8
        destinationField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let stack = NSStackView(views: [remoteField, destinationRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 60)
        remoteField.widthAnchor.constraint(equalToConstant: 430).isActive = true
        alert.accessoryView = stack
        chooseButton.target = self
        chooseButton.action = #selector(chooseCloneDestination(_:))
        cloneDestinationField = destinationField

        guard alert.runModal() == .alertFirstButtonReturn else {
            cloneDestinationField = nil
            return
        }
        cloneDestinationField = nil
        let remote = remoteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, !destination.isEmpty else { return }
        guard let project = workspaceStore.cloneRepository(
            remote,
            into: URL(fileURLWithPath: destination),
            workspaceID: workspaceID
        ) else {
            presentWorkspaceError()
            return
        }
        selectedProjectIDs[workspaceID] = project.id
        activeSessionTarget = nil
        sidebarController.render(
            workspaces: workspaceStore.workspaces,
            selecting: .project(workspaceID: workspaceID, projectID: project.id)
        )
        showProjectOverview()
    }

    @objc func showSettings(_: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = AppKitSettingsWindowController(accountStore: accountStore) { [weak self] appearance in
                self?.apply(appearance: appearance)
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseCloneDestination(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = "Choose Clone Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let field = cloneDestinationField
        else {
            return
        }
        field.stringValue = url.path
    }

    private func configureSplitView() {
        sidebarController.onSelection = { [weak self] selection in
            self?.select(selection)
        }
        sidebarController.onDeleteSession = { [weak self] target in
            self?.deleteSession(target)
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let initialDetail = AppKitEmptyStateViewController(
            title: "Select a project",
            message: "Choose a repository in the sidebar to view its agent sessions.",
            symbolName: "folder"
        )
        detailController = initialDetail
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: initialDetail))
        window?.contentViewController = splitViewController
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "dev.tuist.code.main-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func observeStores() {
        workspaceStore.$workspaces
            .dropFirst()
            .sink { [weak self] workspaces in
                guard let self else { return }
                self.sidebarController.render(workspaces: workspaces, selecting: self.currentSelection)
                self.refreshVisibleDetail()
            }
            .store(in: &cancellables)

        workspaceStore.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.showMessage(message)
                self?.workspaceStore.errorMessage = nil
            }
            .store(in: &cancellables)

        authentication.$state
            .sink { [weak self] _ in
                self?.window?.toolbar?.validateVisibleItems()
            }
            .store(in: &cancellables)

        authentication.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.showMessage(message) }
            .store(in: &cancellables)
    }

    private var currentSelection: AppKitNavigationSelection? {
        if let activeSessionTarget {
            return .session(activeSessionTarget)
        }
        guard let selectedWorkspaceID else { return nil }
        if let projectID = selectedProjectIDs[selectedWorkspaceID] {
            return .project(workspaceID: selectedWorkspaceID, projectID: projectID)
        }
        return .workspace(selectedWorkspaceID)
    }

    private var selectedProject: LocalProject? {
        guard let selectedWorkspaceID,
              let projectID = selectedProjectIDs[selectedWorkspaceID]
        else {
            return nil
        }
        return workspaceStore.workspaces.first(where: { $0.id == selectedWorkspaceID })?
            .projects.first(where: { $0.id == projectID })
    }

    private func select(_ selection: AppKitNavigationSelection) {
        switch selection {
        case let .workspace(workspaceID):
            selectedWorkspaceID = workspaceID
            activeSessionTarget = nil
        case let .project(workspaceID, projectID):
            selectedWorkspaceID = workspaceID
            selectedProjectIDs[workspaceID] = projectID
            activeSessionTarget = nil
        case let .session(target):
            selectedWorkspaceID = target.workspaceID
            selectedProjectIDs[target.workspaceID] = target.projectID
            activeSessionTarget = target
        case let .newSession(workspaceID, projectID, worktreeID):
            selectedWorkspaceID = workspaceID
            selectedProjectIDs[workspaceID] = projectID
            activeSessionTarget = nil
            guard let project = workspaceStore.workspaces.first(where: { $0.id == workspaceID })?
                .projects.first(where: { $0.id == projectID }),
                let worktree = project.worktrees.first(where: { $0.id == worktreeID })
            else {
                return
            }
            createSession(in: worktree, project: project)
            return
        }
        refreshVisibleDetail()
    }

    private func refreshVisibleDetail() {
        if let target = activeSessionTarget,
           let project = project(for: target),
           let worktree = project.worktrees.first(where: { $0.id == target.worktreeID }),
           let session = worktree.sessions.first(where: { $0.id == target.sessionID })
        {
            showSession(project: project, worktree: worktree, session: session, target: target)
        } else {
            showProjectOverview()
        }
    }

    private func showProjectOverview() {
        guard let project = selectedProject else {
            replaceDetail(with: AppKitEmptyStateViewController(
                title: "Select a project",
                message: "Choose a repository in the sidebar to view its agent sessions.",
                symbolName: "folder"
            ))
            return
        }
        let hasRemoteSessions = SharedCapabilityService.remoteSessionsAreAvailable(for: authentication.state)
        let message: String
        if project.worktrees.isEmpty {
            message = hasRemoteSessions
                ? "Create a worktree for \(project.name), then start an agent session. Remote sessions are available through Tuist."
                : "Create a worktree for \(project.name), then start an agent session. Connect to Tuist to unlock remote sessions."
        } else {
            message = "Choose a session in the sidebar, or create another worktree for \(project.name)."
        }
        let controller = AppKitEmptyStateViewController(
            title: project.worktrees.isEmpty ? "No agent sessions" : "Select an agent session",
            message: message,
            symbolName: project.worktrees.isEmpty ? "sparkles" : "sidebar.left",
            actionTitle: "New Worktree"
        ) { [weak self] in
            self?.createWorktree(for: project)
        }
        controller.title = project.name
        replaceDetail(with: controller)
    }

    private func showSession(
        project: LocalProject,
        worktree: ProjectWorktree,
        session: AgentSession,
        target: AgentSessionTarget
    ) {
        let controller = AppKitAgentSessionViewController(
            project: project,
            worktree: worktree,
            session: session,
            accountStore: accountStore,
            runtimeStore: runtimeStore,
            onClose: { [weak self] in
                guard let self else { return }
                self.activeSessionTarget = nil
                self.sidebarController.render(
                    workspaces: self.workspaceStore.workspaces,
                    selecting: .project(workspaceID: target.workspaceID, projectID: target.projectID)
                )
                self.showProjectOverview()
            },
            onNewSession: { [weak self] in self?.createSession(in: worktree, project: project) },
            onStart: { [weak self] prompt, configuration in
                self?.startAgentSession(prompt: prompt, configuration: configuration, target: target)
            }
        )
        controller.title = session.title
        replaceDetail(with: controller)
    }

    private func replaceDetail(with controller: NSViewController) {
        guard splitViewController.splitViewItems.count > 1 else { return }
        splitViewController.removeSplitViewItem(splitViewController.splitViewItems[1])
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: controller))
        detailController = controller
        window?.title = controller.title.map { "\($0) — Tuist Code" } ?? "Tuist Code"
    }

    private func createWorktree(for project: LocalProject) {
        guard let workspaceID = selectedWorkspaceID,
              let worktree = workspaceStore.createWorktree(in: workspaceID, projectID: project.id),
              let session = worktree.sessions.first
        else {
            presentWorkspaceError()
            return
        }
        let target = AgentSessionTarget(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        activeSessionTarget = target
        sidebarController.render(workspaces: workspaceStore.workspaces, selecting: .session(target))
        refreshVisibleDetail()
    }

    private func createSession(in worktree: ProjectWorktree, project: LocalProject) {
        guard let workspaceID = selectedWorkspaceID,
              let session = workspaceStore.createSession(
                  in: workspaceID,
                  projectID: project.id,
                  worktreeID: worktree.id
              )
        else {
            return
        }
        let target = AgentSessionTarget(
            workspaceID: workspaceID,
            projectID: project.id,
            worktreeID: worktree.id,
            sessionID: session.id
        )
        activeSessionTarget = target
        sidebarController.render(workspaces: workspaceStore.workspaces, selecting: .session(target))
        refreshVisibleDetail()
    }

    private func deleteSession(_ target: AgentSessionTarget) {
        guard let session = workspaceStore.session(
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID,
            sessionID: target.sessionID
        ) else {
            return
        }
        if session.initialPrompt != nil || runtimeStore.snapshot(for: session.id) != nil {
            let alert = NSAlert()
            alert.messageText = "Delete Session?"
            alert.informativeText = workspaceStore.isOnlySession(
                in: target.workspaceID,
                projectID: target.projectID,
                worktreeID: target.worktreeID
            )
                ? "This removes the session from Tuist Code. Its Git worktree and files remain on disk."
                : "This permanently removes this session from Tuist Code. Other sessions in the Git worktree are unaffected."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runtimeStore.discard(sessionID: target.sessionID)
        guard workspaceStore.deleteSession(
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID,
            sessionID: target.sessionID
        ) else {
            return
        }
        activeSessionTarget = nil
        selectedWorkspaceID = target.workspaceID
        selectedProjectIDs[target.workspaceID] = target.projectID
        sidebarController.render(
            workspaces: workspaceStore.workspaces,
            selecting: .project(workspaceID: target.workspaceID, projectID: target.projectID)
        )
        showProjectOverview()
    }

    private func startAgentSession(
        prompt: String,
        configuration: AgentSessionInferenceConfiguration,
        target: AgentSessionTarget
    ) {
        guard let project = project(for: target),
              let worktree = project.worktrees.first(where: { $0.id == target.worktreeID }),
              let account = accountStore.configuredAccounts.first(where: { $0.id == configuration.accountID })
        else {
            showMessage("The selected inference account is unavailable.")
            return
        }
        workspaceStore.startAgentSession(
            prompt: prompt,
            in: target.workspaceID,
            projectID: target.projectID,
            worktreeID: target.worktreeID,
            sessionID: target.sessionID,
            configuration: configuration
        )
        let credential = account.providerID == "codex" ? "" : accountStore.credential(for: account)
        guard let credential else {
            showMessage("The selected inference account is unavailable.")
            return
        }
        let agentPrompt = AgentSessionTools.prompt(
            for: prompt,
            configuration: configuration,
            canRenameWorktree: worktree.sessions.count == 1
        )
        runtimeStore.start(
            sessionID: target.sessionID,
            in: URL(fileURLWithPath: worktree.directoryPath),
            prompt: agentPrompt,
            configuration: configuration,
            credential: credential
        )
        refreshVisibleDetail()
    }

    private func project(for target: AgentSessionTarget) -> LocalProject? {
        workspaceStore.workspaces.first(where: { $0.id == target.workspaceID })?
            .projects.first(where: { $0.id == target.projectID })
    }

    private func presentWorkspaceError() {
        if let message = workspaceStore.errorMessage {
            showMessage(message)
            workspaceStore.errorMessage = nil
        }
    }

    private func showMessage(_ message: String) {
        guard !(message.isEmpty) else { return }
        let alert = NSAlert()
        alert.messageText = "Unable to complete request"
        alert.informativeText = message
        alert.runModal()
    }

    private func applyStoredAppearance() {
        apply(appearance: AppKitAppearance(rawValue: UserDefaults.standard.string(forKey: AppKitAppearance.storageKey) ?? "") ?? .system)
    }

    private func apply(appearance: AppKitAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: AppKitAppearance.storageKey)
        NSApp.appearance = appearance.nsAppearance
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.addToolbarIdentifier, Self.accountToolbarIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.addToolbarIdentifier, Self.accountToolbarIdentifier]
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.addToolbarIdentifier:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add"
            item.paletteLabel = "Add Workspace or Project"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Workspace or Project")
            let menu = NSMenu()
            let workspace = menu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "")
            workspace.target = self
            menu.addItem(.separator())
            let local = menu.addItem(withTitle: "Add Local Repository…", action: #selector(addLocalRepository(_:)), keyEquivalent: "")
            local.target = self
            let clone = menu.addItem(withTitle: "Clone Repository…", action: #selector(cloneRepository(_:)), keyEquivalent: "")
            clone.target = self
            item.menu = menu
            return item
        case Self.accountToolbarIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Account"
            let button = NSButton(
                image: NSImage(
                    systemSymbolName: authentication.state == .authenticated
                        ? "person.crop.circle.fill"
                        : "person.crop.circle.badge.plus",
                    accessibilityDescription: "Tuist Account"
                ) ?? NSImage(),
                target: self,
                action: #selector(showAccountMenu(_:))
            )
            button.bezelStyle = .toolbar
            item.view = button
            return item
        default:
            return nil
        }
    }

    @objc private func showAccountMenu(_ sender: NSButton) {
        let menu = NSMenu()
        if authentication.state == .authenticated {
            let status = menu.addItem(withTitle: "Connected to Tuist", action: nil, keyEquivalent: "")
            status.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            menu.addItem(withTitle: authentication.configuration.origin.host() ?? authentication.configuration.origin.absoluteString, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            let signOut = menu.addItem(withTitle: "Sign Out", action: #selector(signOut(_:)), keyEquivalent: "")
            signOut.target = self
        } else {
            menu.addItem(withTitle: "Work locally without an account.", action: nil, keyEquivalent: "")
            let connect = menu.addItem(withTitle: "Connect to Tuist", action: #selector(connectToTuist(_:)), keyEquivalent: "")
            connect.target = self
            connect.isEnabled = authentication.state != .authenticating
            menu.addItem(withTitle: "Connect to unlock remote sessions and remote builds.", action: nil, keyEquivalent: "")
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func connectToTuist(_: Any?) {
        authentication.signIn()
    }

    @objc private func signOut(_: Any?) {
        authentication.signOut()
    }
}

private enum AppKitNavigationSelection: Hashable {
    case workspace(Workspace.ID?)
    case project(workspaceID: Workspace.ID, projectID: LocalProject.ID)
    case session(AgentSessionTarget)
    case newSession(workspaceID: Workspace.ID, projectID: LocalProject.ID, worktreeID: ProjectWorktree.ID)
}

private final class AppKitNavigationNode: NSObject {
    let title: String
    let symbolName: String
    let selection: AppKitNavigationSelection
    let children: [AppKitNavigationNode]

    init(
        title: String,
        symbolName: String,
        selection: AppKitNavigationSelection,
        children: [AppKitNavigationNode] = []
    ) {
        self.title = title
        self.symbolName = symbolName
        self.selection = selection
        self.children = children
    }
}

@MainActor
private final class AppKitWorkspaceSidebarViewController: NSViewController,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    var onSelection: ((AppKitNavigationSelection) -> Void)?
    var onDeleteSession: ((AgentSessionTarget) -> Void)?

    private let outlineView = AppKitDeleteOutlineView()
    private var roots = [AppKitNavigationNode]()
    private var pendingSelection: AppKitNavigationSelection?

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onDelete = { [weak self] in self?.deleteSelectedSession() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.title = "Workspaces"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        scrollView.documentView = outlineView
        view = scrollView
    }

    func render(workspaces: [Workspace], selecting selection: AppKitNavigationSelection?) {
        roots = workspaces.map { workspace in
            AppKitNavigationNode(
                title: workspace.name,
                symbolName: "square.stack.3d.up",
                selection: .workspace(workspace.id),
                children: workspace.projects.map { project in
                    AppKitNavigationNode(
                        title: project.name,
                        symbolName: "folder",
                        selection: .project(workspaceID: workspace.id, projectID: project.id),
                        children: project.worktrees.flatMap { worktree in
                            if worktree.sessions.isEmpty {
                                return [AppKitNavigationNode(
                                    title: "New Session",
                                    symbolName: "plus",
                                    selection: .newSession(
                                        workspaceID: workspace.id,
                                        projectID: project.id,
                                        worktreeID: worktree.id
                                    )
                                )]
                            }
                            return worktree.sessions.map { session in
                                AppKitNavigationNode(
                                    title: session.title,
                                    symbolName: "sparkles",
                                    selection: .session(AgentSessionTarget(
                                        workspaceID: workspace.id,
                                        projectID: project.id,
                                        worktreeID: worktree.id,
                                        sessionID: session.id
                                    ))
                                )
                            }
                        }
                    )
                }
            )
        }
        pendingSelection = selection
        guard isViewLoaded else { return }
        outlineView.reloadData()
        roots.forEach { workspace in
            outlineView.expandItem(workspace)
            workspace.children.forEach { outlineView.expandItem($0) }
        }
        selectPendingNode()
    }

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? AppKitNavigationNode)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? AppKitNavigationNode)?.children[index] ?? roots[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? AppKitNavigationNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(
        _: NSOutlineView,
        viewFor _: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? AppKitNavigationNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("navigation-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.title
        cell.imageView?.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: node.title)
        return cell
    }

    func outlineViewSelectionDidChange(_: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? AppKitNavigationNode
        else {
            return
        }
        onSelection?(node.selection)
    }

    private func selectPendingNode() {
        guard let pendingSelection else { return }
        for row in 0 ..< outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? AppKitNavigationNode else { continue }
            if node.selection == pendingSelection {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                break
            }
        }
    }

    private func deleteSelectedSession() {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? AppKitNavigationNode,
              case let .session(target) = node.selection
        else {
            return
        }
        onDeleteSession?(target)
    }
}

private final class AppKitDeleteOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0,
              let node = item(atRow: clickedRow) as? AppKitNavigationNode,
              case .session = node.selection
        else { return nil }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        let menu = NSMenu()
        let delete = menu.addItem(withTitle: "Delete Session", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        return menu
    }

    @objc private func deleteFromMenu(_: Any?) {
        onDelete?()
    }
}

@MainActor
private final class AppKitEmptyStateViewController: NSViewController {
    private let stateTitle: String
    private let message: String
    private let symbolName: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(
        title: String,
        message: String,
        symbolName: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        stateTitle = title
        self.message = message
        self.symbolName = symbolName
        self.actionTitle = actionTitle
        self.action = action
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        let image = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: stateTitle) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let titleLabel = NSTextField(labelWithString: stateTitle)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.alignment = .center
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        let views: [NSView]
        if let actionTitle {
            let button = NSButton(title: actionTitle, target: self, action: #selector(performAction(_:)))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            views = [image, titleLabel, messageLabel, button]
        } else {
            views = [image, titleLabel, messageLabel]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        view = container
    }

    @objc private func performAction(_: Any?) {
        action?()
    }
}
#endif

#if os(macOS)
private enum AppKitAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let storageKey = "tuist-code-theme"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
private final class AppKitAgentSessionViewController: NSViewController {
    private let project: LocalProject
    private let worktree: ProjectWorktree
    private let session: AgentSession
    private let accountStore: InferenceAccountStore
    private let runtimeStore: AgentSessionRuntimeStore
    private let onClose: () -> Void
    private let onNewSession: () -> Void
    private let onStart: (String, AgentSessionInferenceConfiguration) -> Void

    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Start the agent")
    private let transcriptTextView = NSTextView()
    private let approvalBox = NSBox()
    private let approvalLabel = NSTextField(wrappingLabelWithString: "")
    private let questionBox = NSBox()
    private let questionLabel = NSTextField(wrappingLabelWithString: "")
    private let answerField = NSTextField(string: "")
    private let accountPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let reasoningPopup = NSPopUpButton()
    private let promptField = NSTextField(string: "")
    private let startButton = NSButton()
    private let stopButton = NSButton()
    private var cancellables = Set<AnyCancellable>()

    private var agentAccounts: [InferenceAccount] {
        accountStore.configuredAccounts.filter { ["together", "fireworks", "codex"].contains($0.providerID) }
    }

    init(
        project: LocalProject,
        worktree: ProjectWorktree,
        session: AgentSession,
        accountStore: InferenceAccountStore,
        runtimeStore: AgentSessionRuntimeStore,
        onClose: @escaping () -> Void,
        onNewSession: @escaping () -> Void,
        onStart: @escaping (String, AgentSessionInferenceConfiguration) -> Void
    ) {
        self.project = project
        self.worktree = worktree
        self.session = session
        self.accountStore = accountStore
        self.runtimeStore = runtimeStore
        self.onClose = onClose
        self.onNewSession = onNewSession
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        let root = NSView()

        let backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Sessions") ?? NSImage(),
            target: self,
            action: #selector(closeSession(_:))
        )
        backButton.bezelStyle = .toolbar
        backButton.toolTip = "Return to sessions"
        let titleLabel = NSTextField(labelWithString: session.title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        stopButton.title = "Stop"
        stopButton.target = self
        stopButton.action = #selector(stopSession(_:))
        stopButton.bezelStyle = .rounded
        stopButton.contentTintColor = .systemRed
        let newSessionButton = NSButton(title: "New Session", target: self, action: #selector(createSession(_:)))
        newSessionButton.bezelStyle = .rounded
        let header = NSStackView(views: [backButton, titleLabel, NSView(), stopButton, newSessionButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let locationLabel = NSTextField(labelWithString: "\(project.name)  ·  \(worktree.directoryPath)")
        locationLabel.font = .preferredFont(forTextStyle: .caption1)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle

        statusImage.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent status")
        statusImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        let statusRow = NSStackView(views: [statusImage, statusLabel, NSView()])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true
        transcriptTextView.drawsBackground = false
        transcriptTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        transcriptTextView.textContainerInset = NSSize(width: 8, height: 8)
        transcriptTextView.frame = NSRect(x: 0, y: 0, width: 700, height: 240)
        transcriptTextView.minSize = NSSize(width: 0, height: 240)
        transcriptTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        transcriptTextView.isVerticallyResizable = true
        transcriptTextView.isHorizontallyResizable = false
        transcriptTextView.autoresizingMask = [.width]
        transcriptTextView.textContainer?.widthTracksTextView = true
        transcriptTextView.textContainer?.containerSize = NSSize(
            width: 700,
            height: CGFloat.greatestFiniteMagnitude
        )
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.documentView = transcriptTextView

        configureApprovalBox()
        configureQuestionBox()
        configureComposer()

        let contentStack = NSStackView(views: [
            header,
            locationLabel,
            separator(),
            statusRow,
            transcriptScroll,
            approvalBox,
            questionBox,
            separator(),
            composerView(),
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        root.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        approvalBox.translatesAutoresizingMaskIntoConstraints = false
        questionBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            locationLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            transcriptScroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            approvalBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            questionBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        view = root
        restoreConfiguration()
        updateContent()
        observeStores()
    }

    private func configureApprovalBox() {
        approvalBox.title = "Approval required"
        approvalBox.boxType = .primary
        let deny = NSButton(title: "Deny", target: self, action: #selector(denyTool(_:)))
        let allow = NSButton(title: "Allow", target: self, action: #selector(allowTool(_:)))
        allow.keyEquivalent = "\r"
        let buttons = NSStackView(views: [deny, allow])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [approvalLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        approvalBox.contentView = stack
    }

    private func configureQuestionBox() {
        questionBox.title = "The agent needs your input"
        questionBox.boxType = .primary
        answerField.placeholderString = "Your response"
        let reply = NSButton(title: "Reply", target: self, action: #selector(replyToQuestion(_:)))
        let row = NSStackView(views: [answerField, reply])
        row.orientation = .horizontal
        row.spacing = 8
        answerField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [questionLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        questionBox.contentView = stack
    }

    private func configureComposer() {
        accountPopup.target = self
        accountPopup.action = #selector(accountChanged(_:))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        reasoningPopup.target = self
        reasoningPopup.action = #selector(configurationChanged(_:))
        promptField.placeholderString = "Ask the agent to work on this project"
        promptField.target = self
        promptField.action = #selector(startSession(_:))
        startButton.title = session.initialPrompt == nil ? "Start" : "Send"
        startButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: startButton.title)
        startButton.imagePosition = .imageLeading
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startSession(_:))
    }

    private func composerView() -> NSView {
        let selectors = NSStackView(views: [accountPopup, modelPopup, reasoningPopup, NSView()])
        selectors.orientation = .horizontal
        selectors.spacing = 10
        let promptRow = NSStackView(views: [promptField, startButton])
        promptRow.orientation = .horizontal
        promptRow.spacing = 10
        promptField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [selectors, promptRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        selectors.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        promptRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func observeStores() {
        runtimeStore.$snapshots
            .sink { [weak self] _ in self?.updateContent() }
            .store(in: &cancellables)
        Publishers.CombineLatest(accountStore.$accounts, accountStore.$modelsByAccountID)
            .sink { [weak self] _, _ in self?.restoreConfiguration() }
            .store(in: &cancellables)
    }

    private func updateContent() {
        let snapshot = runtimeStore.snapshot(for: session.id)
        statusLabel.stringValue = snapshot?.phase.title ?? (session.initialPrompt == nil ? "Start the agent" : "Agent is starting")
        statusImage.image = NSImage(
            systemSymbolName: snapshot?.phase.symbolName ?? "sparkles",
            accessibilityDescription: statusLabel.stringValue
        )
        stopButton.isHidden = snapshot?.phase != .running
        approvalBox.isHidden = snapshot?.pendingApproval == nil
        questionBox.isHidden = snapshot?.pendingQuestion == nil
        approvalLabel.stringValue = snapshot?.pendingApproval.map {
            "The agent wants to use \($0.tool).\n\($0.summary)"
        } ?? ""
        questionLabel.stringValue = snapshot?.pendingQuestion ?? ""
        transcriptTextView.string = transcript(for: snapshot)
        startButton.isEnabled = snapshot?.phase != .running && configuration != nil
    }

    private func transcript(for snapshot: AgentSessionRuntimeSnapshot?) -> String {
        guard let snapshot else {
            if let initialPrompt = session.initialPrompt {
                return "Task\n\n\(initialPrompt)\n\nThe agent can inspect, search, edit, patch, and run commands in this worktree. Changes and commands require your approval."
            }
            return "Describe the task below. Before work begins, the agent is instructed to name this session and its worktree."
        }
        var lines = snapshot.activities.map { activity in
            let marker = activity.isInProgress ? "●" : "✓"
            return ["\(marker) \(activity.title)", activity.detail].compactMap { $0 }.joined(separator: "\n")
        }
        if let error = snapshot.errorMessage { lines.append("Error\n\(error)") }
        if !snapshot.transcript.isEmpty { lines.append("Provider events\n\(snapshot.transcript)") }
        return lines.joined(separator: "\n\n")
    }

    private func restoreConfiguration() {
        let previousAccountID = accountPopup.selectedItem?.representedObject as? String
        accountPopup.removeAllItems()
        agentAccounts.forEach { account in
            accountPopup.addItem(withTitle: account.name)
            accountPopup.lastItem?.representedObject = account.id
        }
        let desiredAccountID = session.inferenceConfiguration?.accountID ?? previousAccountID ?? agentAccounts.first?.id
        select(itemRepresenting: desiredAccountID, in: accountPopup)
        reloadModels()
    }

    private func reloadModels() {
        let account = selectedAccount
        let desiredModelID = session.inferenceConfiguration?.accountID == account?.id
            ? session.inferenceConfiguration?.modelID
            : modelPopup.selectedItem?.representedObject as? String
        modelPopup.removeAllItems()
        if let account {
            accountStore.models(for: account).forEach { model in
                modelPopup.addItem(withTitle: model.name)
                modelPopup.lastItem?.representedObject = model.id
            }
        }
        select(itemRepresenting: desiredModelID, in: modelPopup)
        if modelPopup.selectedItem == nil, modelPopup.numberOfItems > 0 { modelPopup.selectItem(at: 0) }
        reloadReasoningEfforts()
    }

    private func reloadReasoningEfforts() {
        let desired = session.inferenceConfiguration?.modelID == selectedModel?.id
            ? session.inferenceConfiguration?.reasoningEffort
            : .medium
        reasoningPopup.removeAllItems()
        (selectedModel?.reasoningEfforts ?? []).forEach { effort in
            reasoningPopup.addItem(withTitle: effort.title)
            reasoningPopup.lastItem?.representedObject = effort.rawValue
        }
        select(itemRepresenting: desired?.rawValue, in: reasoningPopup)
        if reasoningPopup.selectedItem == nil, reasoningPopup.numberOfItems > 0 { reasoningPopup.selectItem(at: 0) }
        updateContent()
    }

    private var selectedAccount: InferenceAccount? {
        guard let id = accountPopup.selectedItem?.representedObject as? String else { return nil }
        return agentAccounts.first(where: { $0.id == id })
    }

    private var selectedModel: InferenceModel? {
        guard let account = selectedAccount,
              let id = modelPopup.selectedItem?.representedObject as? String
        else { return nil }
        return accountStore.models(for: account).first(where: { $0.id == id })
    }

    private var configuration: AgentSessionInferenceConfiguration? {
        guard let account = selectedAccount,
              let provider = accountStore.provider(for: account),
              let model = selectedModel,
              let rawEffort = reasoningPopup.selectedItem?.representedObject as? String,
              let effort = InferenceReasoningEffort(rawValue: rawEffort),
              model.reasoningEfforts.contains(effort)
        else { return nil }
        return AgentSessionInferenceConfiguration(
            accountID: account.id,
            providerID: provider.id,
            modelID: model.id,
            reasoningEffort: effort
        )
    }

    private func select(itemRepresenting value: String?, in popup: NSPopUpButton) {
        guard let value,
              let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value })
        else { return }
        popup.select(item)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func closeSession(_: Any?) { onClose() }
    @objc private func createSession(_: Any?) { onNewSession() }
    @objc private func stopSession(_: Any?) { runtimeStore.stop(sessionID: session.id) }
    @objc private func accountChanged(_: Any?) { reloadModels() }
    @objc private func modelChanged(_: Any?) { reloadReasoningEfforts() }
    @objc private func configurationChanged(_: Any?) { updateContent() }
    @objc private func allowTool(_: Any?) { runtimeStore.approvePendingToolCall(for: session.id, approved: true) }
    @objc private func denyTool(_: Any?) { runtimeStore.approvePendingToolCall(for: session.id, approved: false) }

    @objc private func replyToQuestion(_: Any?) {
        runtimeStore.answerPendingQuestion(for: session.id, answer: answerField.stringValue)
        answerField.stringValue = ""
    }

    @objc private func startSession(_: Any?) {
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let configuration else { return }
        onStart(prompt, configuration)
        promptField.stringValue = ""
    }
}

@MainActor
private final class AppKitSettingsWindowController: NSWindowController {
    init(accountStore: InferenceAccountStore, appearanceChanged: @escaping (AppKitAppearance) -> Void) {
        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar
        let general = AppKitGeneralSettingsViewController(appearanceChanged: appearanceChanged)
        general.title = "General"
        let accounts = AppKitAccountsSettingsViewController(accountStore: accountStore)
        accounts.title = "Inference Accounts"
        tabController.addChild(general)
        tabController.addChild(accounts)
        tabController.tabViewItems[0].image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "General"
        )
        tabController.tabViewItems[1].image = NSImage(
            systemSymbolName: "person.2",
            accessibilityDescription: "Inference Accounts"
        )

        let window = NSWindow(contentViewController: tabController)
        window.title = "Tuist Code Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 720, height: 470))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

@MainActor
private final class AppKitGeneralSettingsViewController: NSViewController {
    private let appearanceChanged: (AppKitAppearance) -> Void
    private let popup = NSPopUpButton()

    init(appearanceChanged: @escaping (AppKitAppearance) -> Void) {
        self.appearanceChanged = appearanceChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Appearance")
        heading.font = .preferredFont(forTextStyle: .headline)
        let label = NSTextField(labelWithString: "Theme")
        AppKitAppearance.allCases.forEach { appearance in
            popup.addItem(withTitle: appearance.title)
            popup.lastItem?.representedObject = appearance.rawValue
        }
        let selected = UserDefaults.standard.string(forKey: AppKitAppearance.storageKey) ?? AppKitAppearance.system.rawValue
        popup.selectItem(withTitle: AppKitAppearance(rawValue: selected)?.title ?? AppKitAppearance.system.title)
        popup.target = self
        popup.action = #selector(changeAppearance(_:))
        let row = NSStackView(views: [label, popup, NSView()])
        row.orientation = .horizontal
        row.spacing = 12
        let stack = NSStackView(views: [heading, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
        ])
        view = root
    }

    @objc private func changeAppearance(_: Any?) {
        guard let rawValue = popup.selectedItem?.representedObject as? String,
              let appearance = AppKitAppearance(rawValue: rawValue)
        else { return }
        appearanceChanged(appearance)
    }
}

@MainActor
private final class AppKitAccountsSettingsViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let accountStore: InferenceAccountStore
    private let tableView = NSTableView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "Select an account to inspect its configuration.")
    private let removeButton = NSButton()
    private let refreshButton = NSButton()
    private var cancellables = Set<AnyCancellable>()
    private var lastPresentedAuthorizationURL: URL?

    init(accountStore: InferenceAccountStore) {
        self.accountStore = accountStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("account")))
        scroll.documentView = tableView

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add inference account") ?? NSImage(),
            target: self,
            action: #selector(showAddMenu(_:))
        )
        addButton.bezelStyle = .smallSquare
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove inference account")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSelectedAccount(_:))
        refreshButton.target = self
        refreshButton.action = #selector(performAccountAction(_:))
        let controls = NSStackView(views: [addButton, removeButton, NSView(), refreshButton])
        controls.orientation = .horizontal
        controls.spacing = 6

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        let left = NSStackView(views: [scroll, controls])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detailLabel)
        root.addSubview(split)
        split.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = root
        observeStore()
        updateSelection()
    }

    private func observeStore() {
        accountStore.$accounts
            .sink { [weak self] _ in
                self?.tableView.reloadData()
                self?.updateSelection()
            }
            .store(in: &cancellables)
        Publishers.CombineLatest3(
            accountStore.$authorizationURL,
            accountStore.$authorizationDeviceCode,
            accountStore.$authorizationDeviceCodeExpiration
        )
        .sink { [weak self] url, code, expiration in
            self?.presentAuthorization(url: url, code: code, expiration: expiration)
        }
        .store(in: &cancellables)
        accountStore.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.showError(message) }
            .store(in: &cancellables)
    }

    func numberOfRows(in _: NSTableView) -> Int { accountStore.accounts.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let account = accountStore.accounts[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: account.name)
        let provider = accountStore.provider(for: account)
        let image = NSImageView(image: NSImage(
            systemSymbolName: provider?.symbolName ?? "cpu",
            accessibilityDescription: provider?.name ?? "Provider"
        ) ?? NSImage())
        cell.addSubview(image)
        cell.addSubview(label)
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) { updateSelection() }

    private var selectedAccount: InferenceAccount? {
        guard tableView.selectedRow >= 0, accountStore.accounts.indices.contains(tableView.selectedRow) else { return nil }
        return accountStore.accounts[tableView.selectedRow]
    }

    private func updateSelection() {
        guard let account = selectedAccount else {
            detailLabel.stringValue = accountStore.accounts.isEmpty
                ? "No inference accounts\n\nAdd an account to select the provider and model used by coding sessions."
                : "Select an account to inspect its configuration."
            removeButton.isEnabled = false
            refreshButton.isEnabled = false
            return
        }
        let provider = accountStore.provider(for: account)
        let models = accountStore.models(for: account)
        let modelList = models.isEmpty
            ? "No models loaded"
            : models.prefix(12).map(\.name).joined(separator: "\n")
        detailLabel.stringValue = "\(account.name)\n\nProvider: \(provider?.name ?? account.providerID)\nStatus: \(account.state.title)\nModels: \(models.count)\n\n\(modelList)"
        removeButton.isEnabled = true
        refreshButton.isEnabled = true
        switch account.state {
        case .configured:
            refreshButton.title = "Refresh Models"
        case .requiresAuthorization:
            refreshButton.title = "Sign In"
        case .authorizing:
            refreshButton.title = "Cancel Sign In"
        }
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        accountStore.catalog.forEach { provider in
            let item = menu.addItem(withTitle: provider.name, action: #selector(addProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.id
            item.image = NSImage(systemSymbolName: provider.symbolName, accessibilityDescription: provider.name)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addProvider(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String,
              let provider = accountStore.catalog.first(where: { $0.id == providerID })
        else { return }
        switch provider.authentication {
        case .apiKey: configureKeyProvider(provider)
        case .oauth: configureSignInProvider(provider)
        }
    }

    private func configureKeyProvider(_ provider: InferenceProviderDescriptor) {
        let alert = NSAlert()
        alert.messageText = "Add \(provider.name) Account"
        alert.addButton(withTitle: "Add Account")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(string: provider.name)
        name.placeholderString = "Account name"
        let key = NSSecureTextField(string: "")
        key.placeholderString = "Application programming interface key"
        let stack = NSStackView(views: [name, key])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        name.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = accountStore.configureAPIKey(key.stringValue, named: name.stringValue, for: provider)
    }

    private func configureSignInProvider(_ provider: InferenceProviderDescriptor) {
        let alert = NSAlert()
        alert.messageText = "Add \(provider.name) Account"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(string: provider.name)
        name.placeholderString = "Account name"
        name.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = accountStore.beginOAuth(named: name.stringValue, for: provider)
    }

    private func presentAuthorization(url: URL?, code: String?, expiration: String?) {
        guard let url, url != lastPresentedAuthorizationURL else { return }
        lastPresentedAuthorizationURL = url
        let alert = NSAlert()
        alert.messageText = "Complete Sign In"
        alert.informativeText = [
            "Open the authorization page and enter the device code.",
            code.map { "Code: \($0)" },
            expiration.map { "Expires in \($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Open Authorization Page")
        alert.addButton(withTitle: "Copy Code")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        } else if response == .alertSecondButtonReturn, let code {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
    }

    @objc private func removeSelectedAccount(_: Any?) {
        guard let account = selectedAccount else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = "Sessions configured with this account will need another inference account before they can run."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accountStore.remove(account)
    }

    @objc private func performAccountAction(_: Any?) {
        guard let account = selectedAccount else { return }
        switch account.state {
        case .configured:
            accountStore.refreshModels(for: account)
        case .requiresAuthorization:
            guard let provider = accountStore.provider(for: account) else { return }
            _ = accountStore.reauthenticate(account, with: provider)
        case .authorizing:
            accountStore.cancelAuthorization(for: account.id)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Inference Account Error"
        alert.informativeText = message
        alert.runModal()
        accountStore.errorMessage = nil
    }
}
#endif

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

#if os(iOS)
private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
#endif
