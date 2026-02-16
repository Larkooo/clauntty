import SwiftUI
import os.log

struct ConnectionListView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?
    @State private var showingPasswordPrompt = false
    @State private var pendingConnection: SavedConnection?
    @State private var pendingAgentProfile: AgentLaunchProfile?
    @State private var enteredPassword = ""

    // Connection state
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showingError = false
    @State private var showingSettings = false
    @State private var showingAgentLauncher = false

    var body: some View {
        List {
            if connectionStore.connections.isEmpty {
                emptyStateView
            } else {
                ForEach(connectionStore.connections) { connection in
                    ConnectionRow(connection: connection)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            connect(to: connection)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                connectionStore.delete(connection)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                connectionToEdit = connection
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAgentLauncher = true
                } label: {
                    Image(systemName: "sparkles")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewConnection = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewConnection) {
            NewConnectionView()
        }
        .sheet(item: $connectionToEdit) { connection in
            NewConnectionView(existingConnection: connection)
        }
        .sheet(isPresented: $showingAgentLauncher) {
            AgentSessionLauncherView { connection, profile in
                showingAgentLauncher = false
                connect(to: connection, agentProfile: profile)
            }
            .environmentObject(connectionStore)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Enter Password", isPresented: $showingPasswordPrompt) {
            SecureField("Password", text: $enteredPassword)
            Button("Cancel", role: .cancel) {
                enteredPassword = ""
                pendingConnection = nil
                pendingAgentProfile = nil
            }
            Button("Connect") {
                if let connection = pendingConnection {
                    performConnect(to: connection, password: enteredPassword, agentProfile: pendingAgentProfile)
                }
                enteredPassword = ""
                pendingAgentProfile = nil
            }
        } message: {
            if let connection = pendingConnection {
                Text("Enter password for \(connection.username)@\(connection.host)")
            }
        }
        .alert("Connection Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionError ?? "Unknown error")
        }
        .overlay {
            if isConnecting {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Connecting...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(10)
                }
            }
        }
        .onAppear {
            appState.beginInputSuppression()
            dismissTerminalInput()
        }
        .onDisappear {
            appState.endInputSuppression()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Servers")
                .font(.headline)
            Text("Tap + to add your first server")
                .font(.subheadline)
                .foregroundColor(.secondary)

            #if DEBUG
            // Debug button to test terminal rendering without SSH
            Button("Test Terminal View") {
                let testConfig = SavedConnection(
                    name: "Test",
                    host: "localhost",
                    port: 22,
                    username: "test",
                    authMethod: .password
                )
                _ = sessionManager.createSession(for: testConfig)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 20)
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }

    private func connect(to connection: SavedConnection, agentProfile: AgentLaunchProfile? = nil) {
        switch connection.authMethod {
        case .password:
            // Check if we have a saved password
            if let _ = try? KeychainHelper.getPassword(for: connection.id) {
                performConnect(to: connection, password: nil, agentProfile: agentProfile)
            } else {
                // Prompt for password
                pendingConnection = connection
                pendingAgentProfile = agentProfile
                showingPasswordPrompt = true
            }
        case .sshKey:
            // SSH key auth - check if key exists and has passphrase
            performConnect(to: connection, password: nil, agentProfile: agentProfile)
        }
    }

    private func performConnect(to connection: SavedConnection, password: String?, agentProfile: AgentLaunchProfile? = nil) {
        // Save password if provided
        if let password = password, !password.isEmpty {
            try? KeychainHelper.savePassword(for: connection.id, password: password)
        }

        connectionStore.updateLastConnected(connection)

        // Start async connection flow
        isConnecting = true

        Task {
            do {
                // Connect SSH and sync sessions with server (auto-creates tabs for existing sessions)
                if let result = try await sessionManager.connectAndListSessions(for: connection) {
                    // Sync existing sessions -> marks deleted ones, creates tabs for new ones
                    await sessionManager.syncSessionsWithServer(config: connection, deployer: result.deployer)
                }

                await MainActor.run {
                    isConnecting = false

                    // Create a new session and tab
                    let session: Session
                    if let agentProfile {
                        session = sessionManager.createAgentSession(for: connection, profile: agentProfile)
                        Logger.clauntty.debugOnly("ConnectionListView: created agent session \(session.id.uuidString.prefix(8)) provider=\(agentProfile.provider.rawValue)")
                    } else {
                        session = sessionManager.createSession(for: connection)
                        Logger.clauntty.debugOnly("ConnectionListView: created new session \(session.id.uuidString.prefix(8))")
                    }

                    // Save persistence immediately
                    sessionManager.savePersistence()

                    // Navigation happens automatically when sessionManager.hasSessions becomes true
                    // TerminalView will call sessionManager.connect() via connectSession()
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text(connection.endpointDisplay)
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: connection.authMethod == .password ? "key.fill" : "key.horizontal.fill")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct AgentSessionLauncherView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    let onLaunch: (SavedConnection, AgentLaunchProfile) -> Void

    @State private var selectedConnectionId: UUID?
    @State private var provider: AgentProvider = .claudeCode
    @State private var launchCommand: String = AgentProvider.claudeCode.defaultLaunchCommand
    @State private var workingDirectory: String = ""
    @State private var repositoryURL: String = ""
    @State private var useDedicatedWorktree = false
    @State private var initialPrompt: String = ""

    private var selectedConnection: SavedConnection? {
        guard let selectedConnectionId else { return connectionStore.connections.first }
        return connectionStore.connections.first { $0.id == selectedConnectionId }
    }

    private var canLaunch: Bool {
        selectedConnection != nil && !launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Connection", selection: $selectedConnectionId) {
                        ForEach(connectionStore.connections) { connection in
                            Text(connection.displayName).tag(Optional(connection.id))
                        }
                    }
                }

                Section("Agent") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AgentProvider.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .onChange(of: provider) { _, newProvider in
                        if launchCommand == AgentProvider.claudeCode.defaultLaunchCommand
                            || launchCommand == AgentProvider.codexCLI.defaultLaunchCommand {
                            launchCommand = newProvider.defaultLaunchCommand
                        }
                    }

                    TextField("Launch command", text: $launchCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Working directory (optional)", text: $workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Repository (Optional)") {
                    TextField("Repository URL", text: $repositoryURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Toggle("Use dedicated worktree per agent", isOn: $useDedicatedWorktree)
                        .disabled(repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text("If a repository URL is provided, Clauntty clones/fetches it before launch. Worktree mode creates an isolated worktree for each new agent session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Initial Prompt (Optional)") {
                    TextEditor(text: $initialPrompt)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Launch Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Launch") {
                        guard let connection = selectedConnection else { return }
                        let profile = AgentLaunchProfile(
                            provider: provider,
                            launchCommand: launchCommand,
                            initialPrompt: initialPrompt,
                            workingDirectory: workingDirectory,
                            repositoryURL: repositoryURL,
                            useDedicatedWorktree: useDedicatedWorktree
                        )
                        onLaunch(connection, profile)
                    }
                    .disabled(!canLaunch)
                }
            }
            .onAppear {
                if selectedConnectionId == nil {
                    selectedConnectionId = connectionStore.connections.first?.id
                }
            }
            .onChange(of: repositoryURL) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    useDedicatedWorktree = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ConnectionListView()
            .environmentObject(ConnectionStore())
            .environmentObject(AppState())
            .environmentObject(SessionManager())
    }
}
