import Foundation
import NIOCore
import NIOSSH
import os.log

/// Manages all terminal sessions, web tabs, and connection pooling
/// Reuses SSH connections when opening multiple tabs to the same server
@MainActor
class SessionManager: ObservableObject {
    // MARK: - Published State

    /// All active terminal sessions
    @Published var sessions: [Session] = []

    /// All active web tabs
    @Published var webTabs: [WebTab] = []

    /// Ports being forwarded without a web tab (background forwarding)
    @Published var forwardedPorts: [ForwardedPort] = []

    /// Currently active tab type and ID
    enum ActiveTab: Equatable {
        case terminal(UUID)
        case web(UUID)
    }

    @Published var activeTab: ActiveTab?

    /// Previously active tab (for "go back" navigation)
    private(set) var previousActiveTab: ActiveTab?

    /// Currently active terminal session (if a terminal is active)
    var activeSession: Session? {
        if case .terminal(let id) = activeTab {
            return sessions.first { $0.id == id }
        }
        return nil
    }

    /// Currently active web tab (if a web tab is active)
    var activeWebTab: WebTab? {
        if case .web(let id) = activeTab {
            return webTabs.first { $0.id == id }
        }
        return nil
    }

    /// Legacy compatibility - active session ID
    var activeSessionId: UUID? {
        get {
            if case .terminal(let id) = activeTab {
                return id
            }
            return nil
        }
        set {
            if let id = newValue {
                activeTab = .terminal(id)
            }
        }
    }

    // MARK: - Connection Pool

    /// Pool of SSH connections, keyed by "user@host:port"
    private var connectionPool: [String: SSHConnection] = [:]

    // MARK: - Session Management

    /// Create a new session for a connection config
    /// Reuses existing SSH connection if available
    func createSession(for config: SavedConnection) -> Session {
        let session = Session(connectionConfig: config)
        sessions.append(session)

        // Always make new session active (user just opened it)
        activeSessionId = session.id

        Logger.clauntty.info("SessionManager: created session \(session.id.uuidString.prefix(8)) for \(config.host)")
        return session
    }

    /// Whether to use rtach for session persistence (can be disabled for debugging)
    var useRtach: Bool = true

    /// Cache of RtachDeployer per connection (for session listing)
    private var rtachDeployers: [String: RtachDeployer] = [:]

    /// Connect SSH and list existing rtach sessions
    /// Returns sessions and deployer, or nil if rtach is disabled or deployment fails
    func connectAndListSessions(for config: SavedConnection) async throws -> (sessions: [RtachSession], deployer: RtachDeployer)? {
        let poolKey = connectionKey(for: config)

        // Get or create SSH connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            Logger.clauntty.info("SessionManager: reusing existing connection for \(poolKey)")
            connection = existing
        } else {
            Logger.clauntty.info("SessionManager: creating new connection for \(poolKey)")
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )

            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        guard useRtach else { return nil }

        // Deploy rtach and list sessions
        do {
            let deployer = RtachDeployer(connection: connection)
            Logger.clauntty.info("SessionManager: ensuring rtach deployed...")
            try await deployer.ensureDeployed()
            rtachDeployers[poolKey] = deployer
            Logger.clauntty.info("SessionManager: listing sessions...")
            let sessions = try await deployer.listSessions()
            Logger.clauntty.info("SessionManager: found \(sessions.count) existing sessions")
            return (sessions: sessions, deployer: deployer)
        } catch {
            Logger.clauntty.warning("SessionManager: rtach deployment failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Connect a session with optional rtach session ID
    /// - Parameter rtachSessionId: The rtach session to attach to, or nil for new session
    func connect(session: Session, rtachSessionId: String? = nil) async throws {
        Logger.clauntty.info("SessionManager.connect called for session \(session.id.uuidString.prefix(8))")
        session.state = .connecting

        let config = session.connectionConfig
        let poolKey = connectionKey(for: config)

        // Create a fresh SSH connection for the terminal session
        // (The connection from connectAndListSessions may be in a bad state after exec commands)
        Logger.clauntty.info("SessionManager: creating fresh connection for terminal session \(session.id.uuidString.prefix(8))")
        let connection = SSHConnection(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            connectionId: config.id
        )
        try await connection.connect()
        Logger.clauntty.info("SessionManager: SSH connection established for \(session.id.uuidString.prefix(8))")

        // Store this session's connection - don't disconnect other sessions' connections!
        // Each session gets its own SSH connection to avoid killing other sessions' channels
        session.sshConnection = connection

        // Build rtach command
        var shellCommand: String? = nil
        if useRtach, let deployer = rtachDeployers[poolKey] {
            // Use session's rtach ID, or generate new UUID for new session
            let sessionId = session.rtachSessionId ?? UUID().uuidString
            // Store back so we can track which rtach session this tab is using
            session.rtachSessionId = sessionId
            shellCommand = deployer.shellCommand(sessionId: sessionId)
            Logger.clauntty.info("SessionManager: using rtach session: \(sessionId.prefix(8))...")

            // Update last accessed time for this session (use fresh connection)
            // The deployer's cached connection might be stale, so create a new deployer
            let freshDeployer = RtachDeployer(connection: connection)
            try? await freshDeployer.updateLastAccessed(sessionId: sessionId)
        }

        // Create a new channel for this session with the correct terminal size
        Logger.clauntty.info("SessionManager: creating channel for \(session.id.uuidString.prefix(8)), command=\(shellCommand ?? "shell")")
        let (channel, handler) = try await connection.createChannel(
            terminalSize: session.initialTerminalSize,
            command: shellCommand
        ) { [weak session] data in
            Task { @MainActor in
                session?.handleDataReceived(data)
            }
        }
        Logger.clauntty.info("SessionManager: channel created for \(session.id.uuidString.prefix(8))")

        session.attach(channel: channel, handler: handler, connection: connection)

        // Wire up OSC 777 callbacks for port forwarding
        session.onPortForwardRequested = { [weak self, weak session] port in
            guard let self = self, let session = session else { return }
            self.handlePortForwardRequest(from: session, port: port)
        }
        session.onOpenTabRequested = { [weak self, weak session] port in
            guard let self = self, let session = session else { return }
            self.handleOpenTabRequest(from: session, port: port)
        }

        Logger.clauntty.info("SessionManager: session \(session.id.uuidString.prefix(8)) connected and attached")
    }

    /// Close a session
    func closeSession(_ session: Session) {
        Logger.clauntty.info("SessionManager: closing session \(session.id.uuidString.prefix(8))")

        // Detach from channel
        session.detach()

        // Remove from sessions list
        sessions.removeAll { $0.id == session.id }

        // If this was the active session, switch to another
        if activeSessionId == session.id {
            activeSessionId = sessions.first?.id
        }

        // Check if connection should be closed (no more sessions using it)
        cleanupUnusedConnections()
    }

    /// Switch to a different session
    func switchTo(_ session: Session) {
        guard sessions.contains(where: { $0.id == session.id }) else {
            Logger.clauntty.warning("SessionManager: cannot switch to unknown session")
            return
        }
        // Track previous tab for "go back" navigation
        if let current = activeTab, current != .terminal(session.id) {
            previousActiveTab = current
        }
        activeSessionId = session.id
        Logger.clauntty.info("SessionManager: switched to session \(session.id.uuidString.prefix(8))")
    }

    /// Close all sessions
    func closeAllSessions() {
        Logger.clauntty.info("SessionManager: closing all sessions")
        for session in sessions {
            session.detach()
        }
        sessions.removeAll()
        activeSessionId = nil

        // Close all connections
        for (_, connection) in connectionPool {
            connection.disconnect()
        }
        connectionPool.removeAll()
    }

    // MARK: - Connection Pooling

    /// Generate pool key for a connection config
    private func connectionKey(for config: SavedConnection) -> String {
        return "\(config.username)@\(config.host):\(config.port)"
    }

    /// Clean up connections that have no active sessions
    private func cleanupUnusedConnections() {
        // Get all pool keys that have active sessions
        let activeKeys = Set(sessions.map { connectionKey(for: $0.connectionConfig) })

        // Close connections not in use
        for (key, connection) in connectionPool {
            if !activeKeys.contains(key) {
                Logger.clauntty.info("SessionManager: closing unused connection \(key)")
                connection.disconnect()
                connectionPool.removeValue(forKey: key)
            }
        }
    }

    /// Get the number of sessions using a particular connection
    func sessionCount(for config: SavedConnection) -> Int {
        let key = connectionKey(for: config)
        return sessions.filter { connectionKey(for: $0.connectionConfig) == key }.count
    }

    // MARK: - Convenience

    /// Check if there are any active sessions or web tabs
    var hasSessions: Bool {
        !sessions.isEmpty || !webTabs.isEmpty
    }

    /// Check if there are only terminal sessions (no web tabs)
    var hasOnlyTerminals: Bool {
        !sessions.isEmpty && webTabs.isEmpty
    }

    // MARK: - Web Tab Management

    /// Scan for listening ports on a connection
    func scanPorts(for config: SavedConnection) async throws -> [RemotePort] {
        let poolKey = connectionKey(for: config)

        guard let connection = connectionPool[poolKey], connection.isConnected else {
            throw SessionError.notConnected
        }

        let scanner = PortScanner(connection: connection)
        return try await scanner.listListeningPorts()
    }

    /// Create a web tab for a remote port
    /// - Parameters:
    ///   - port: The remote port to forward
    ///   - config: Connection configuration
    ///   - makeActive: Whether to switch to this tab (default true)
    func createWebTab(for port: RemotePort, config: SavedConnection, makeActive: Bool = true) async throws -> WebTab {
        let poolKey = connectionKey(for: config)

        // Get or create connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            connection = existing
        } else {
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        let webTab = WebTab(remotePort: port, sshConnection: connection)
        webTabs.append(webTab)

        // Start port forwarding
        try await webTab.startForwarding()

        // Make it active if requested
        if makeActive {
            activeTab = .web(webTab.id)
        }

        Logger.clauntty.info("SessionManager: created web tab for port \(port.port)")
        return webTab
    }

    /// Close a web tab
    func closeWebTab(_ webTab: WebTab) {
        Logger.clauntty.info("SessionManager: closing web tab for port \(webTab.remotePort.port)")

        Task {
            await webTab.close()
        }

        webTabs.removeAll { $0.id == webTab.id }

        // If this was active, switch to another tab
        if case .web(let id) = activeTab, id == webTab.id {
            if let firstSession = sessions.first {
                activeTab = .terminal(firstSession.id)
            } else if let firstWebTab = webTabs.first {
                activeTab = .web(firstWebTab.id)
            } else {
                activeTab = nil
            }
        }

        cleanupUnusedConnections()
    }

    /// Switch to a web tab
    func switchTo(_ webTab: WebTab) {
        guard webTabs.contains(where: { $0.id == webTab.id }) else {
            Logger.clauntty.warning("SessionManager: cannot switch to unknown web tab")
            return
        }
        // Track previous tab for "go back" navigation
        if let current = activeTab, current != .web(webTab.id) {
            previousActiveTab = current
        }
        activeTab = .web(webTab.id)
        Logger.clauntty.info("SessionManager: switched to web tab \(webTab.id.uuidString.prefix(8))")
    }

    /// Check if a port is already open in a web tab
    func webTabForPort(_ port: Int, config: SavedConnection) -> WebTab? {
        let poolKey = connectionKey(for: config)
        return webTabs.first { tab in
            tab.remotePort.port == port &&
            tab.sshConnection != nil &&
            connectionKey(for: tab.sshConnection!.host, tab.sshConnection!.port, tab.sshConnection!.username) == poolKey
        }
    }

    private func connectionKey(for host: String, _ port: Int, _ username: String) -> String {
        return "\(username)@\(host):\(port)"
    }

    /// Get session by ID
    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Check if an rtach session is already open in a tab
    /// Returns the Session if open, nil otherwise
    func sessionForRtach(_ rtachSessionId: String) -> Session? {
        sessions.first { $0.rtachSessionId == rtachSessionId }
    }

    // MARK: - Tab Reordering

    /// Move a terminal session to a new index
    func moveSession(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        Logger.clauntty.info("SessionManager: reordered sessions")
    }

    /// Move a terminal session by ID to a new index
    func moveSession(id: UUID, toIndex destination: Int) {
        guard let sourceIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        sessions.insert(session, at: min(adjustedDestination, sessions.count))
        Logger.clauntty.info("SessionManager: moved session to index \(adjustedDestination)")
    }

    /// Move a web tab to a new index
    func moveWebTab(from source: IndexSet, to destination: Int) {
        webTabs.move(fromOffsets: source, toOffset: destination)
        Logger.clauntty.info("SessionManager: reordered web tabs")
    }

    /// Move a web tab by ID to a new index
    func moveWebTab(id: UUID, toIndex destination: Int) {
        guard let sourceIndex = webTabs.firstIndex(where: { $0.id == id }) else { return }
        let webTab = webTabs.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        webTabs.insert(webTab, at: min(adjustedDestination, webTabs.count))
        Logger.clauntty.info("SessionManager: moved web tab to index \(adjustedDestination)")
    }

    // MARK: - Tab Navigation

    // MARK: - OSC 777 Port Forwarding

    /// Handle a port forward request from a session (triggered by OSC 777;forward;PORT)
    func handlePortForwardRequest(from session: Session, port: Int) {
        let config = session.connectionConfig
        let remotePort = RemotePort(id: port, port: port, process: nil, address: "127.0.0.1")

        Task {
            do {
                try await startForwarding(port: remotePort, config: config)
                Logger.clauntty.info("SessionManager: forwarded port \(port) via OSC 777")
            } catch {
                Logger.clauntty.error("SessionManager: failed to forward port \(port): \(error)")
            }
        }
    }

    /// Handle an open tab request from a session (triggered by OSC 777;open;PORT)
    /// Opens the tab in background without switching to it
    func handleOpenTabRequest(from session: Session, port: Int) {
        let config = session.connectionConfig
        let remotePort = RemotePort(id: port, port: port, process: nil, address: "127.0.0.1")

        Task {
            do {
                // Check if already open - just log and return, don't switch
                if webTabForPort(port, config: config) != nil {
                    Logger.clauntty.info("SessionManager: web tab for port \(port) already exists")
                    return
                }

                // Create new web tab in background (don't switch to it)
                _ = try await createWebTab(for: remotePort, config: config, makeActive: false)
                Logger.clauntty.info("SessionManager: opened web tab for port \(port) via OSC 777 (background)")
            } catch {
                Logger.clauntty.error("SessionManager: failed to open tab for port \(port): \(error)")
            }
        }
    }

    /// Switch to the previous tab (for "go back" gesture)
    func switchToPreviousTab() {
        guard let previous = previousActiveTab else {
            Logger.clauntty.info("SessionManager: no previous tab to switch to")
            return
        }

        // Verify the tab still exists
        switch previous {
        case .terminal(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                switchTo(session)
            }
        case .web(let id):
            if let webTab = webTabs.first(where: { $0.id == id }) {
                switchTo(webTab)
            }
        }
    }

    /// Find and switch to the next terminal session that is waiting for input
    /// Returns true if a tab was found and switched to
    @discardableResult
    func switchToNextWaitingTab() -> Bool {
        // Get sessions waiting for input, excluding the current one
        let waitingSessions = sessions.filter { session in
            session.isWaitingForInput && activeTab != .terminal(session.id)
        }

        if let nextSession = waitingSessions.first {
            switchTo(nextSession)
            Logger.clauntty.info("SessionManager: switched to waiting session \(nextSession.id.uuidString.prefix(8))")
            return true
        }

        Logger.clauntty.info("SessionManager: no tabs waiting for input")
        return false
    }

    /// Get the next terminal session waiting for input without switching
    /// Used for interactive swipe preview
    func nextWaitingTab() -> ActiveTab? {
        let waitingSessions = sessions.filter { session in
            session.isWaitingForInput && activeTab != .terminal(session.id)
        }

        if let nextSession = waitingSessions.first {
            return .terminal(nextSession.id)
        }
        return nil
    }

    // MARK: - Background Port Forwarding

    /// Start forwarding a port without opening a web tab
    func startForwarding(port: RemotePort, config: SavedConnection) async throws {
        let poolKey = connectionKey(for: config)

        // Check if already forwarded
        if isPortForwarded(port.port, config: config) {
            Logger.clauntty.info("SessionManager: port \(port.port) already forwarded")
            return
        }

        // Get or create connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            connection = existing
        } else {
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        // Create forwarded port
        let forwardedPort = ForwardedPort(
            remotePort: port,
            connectionConfig: config,
            sshConnection: connection
        )

        // Start forwarding
        try await forwardedPort.startForwarding()

        forwardedPorts.append(forwardedPort)
        Logger.clauntty.info("SessionManager: started forwarding port \(port.port) -> localhost:\(forwardedPort.localPort)")
    }

    /// Stop forwarding a port
    func stopForwarding(port: RemotePort, config: SavedConnection) {
        let poolKey = connectionKey(for: config)

        // Find and remove the forwarded port
        if let index = forwardedPorts.firstIndex(where: {
            $0.remotePort.port == port.port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }) {
            let forwarded = forwardedPorts.remove(at: index)
            Task {
                await forwarded.stopForwarding()
            }
            Logger.clauntty.info("SessionManager: stopped forwarding port \(port.port)")
        }

        // Also close any web tab using this port
        if let webTab = webTabForPort(port.port, config: config) {
            closeWebTab(webTab)
        }

        cleanupUnusedConnections()
    }

    /// Check if a port is being forwarded (either background or via web tab)
    func isPortForwarded(_ port: Int, config: SavedConnection) -> Bool {
        let poolKey = connectionKey(for: config)

        // Check background forwarded ports
        let isBackgroundForwarded = forwardedPorts.contains {
            $0.remotePort.port == port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }

        // Check web tabs (which also have port forwarding)
        let hasWebTab = webTabForPort(port, config: config) != nil

        return isBackgroundForwarded || hasWebTab
    }

    /// Get a forwarded port by port number and config
    func forwardedPort(_ port: Int, config: SavedConnection) -> ForwardedPort? {
        let poolKey = connectionKey(for: config)
        return forwardedPorts.first {
            $0.remotePort.port == port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }
    }
}

// MARK: - ForwardedPort

/// A port being forwarded in the background (without a web tab)
@MainActor
class ForwardedPort: Identifiable, ObservableObject {
    let id: UUID
    let remotePort: RemotePort
    @Published var localPort: Int
    let connectionConfig: SavedConnection

    private var portForwarder: PortForwardingManager?
    weak var sshConnection: SSHConnection?

    init(remotePort: RemotePort, connectionConfig: SavedConnection, sshConnection: SSHConnection) {
        self.id = UUID()
        self.remotePort = remotePort
        self.localPort = remotePort.port
        self.connectionConfig = connectionConfig
        self.sshConnection = sshConnection
    }

    /// Start port forwarding
    func startForwarding() async throws {
        guard let connection = sshConnection,
              let eventLoop = connection.nioEventLoopGroup,
              let channel = connection.nioChannel else {
            throw ForwardedPortError.noConnection
        }

        Logger.clauntty.info("ForwardedPort: starting forwarding for port \(self.remotePort.port)")

        let forwarder = PortForwardingManager(
            localPort: remotePort.port,
            remoteHost: "127.0.0.1",
            remotePort: remotePort.port,
            eventLoopGroup: eventLoop,
            sshChannel: channel
        )

        let actualPort = try await forwarder.start()
        self.localPort = actualPort
        self.portForwarder = forwarder

        Logger.clauntty.info("ForwardedPort: forwarding started on localhost:\(actualPort)")
    }

    /// Stop port forwarding
    func stopForwarding() async {
        if let forwarder = portForwarder {
            try? await forwarder.stop()
            portForwarder = nil
            Logger.clauntty.info("ForwardedPort: stopped forwarding for port \(self.remotePort.port)")
        }
    }
}

enum ForwardedPortError: Error, LocalizedError {
    case noConnection

    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "SSH connection not available"
        }
    }
}

// MARK: - Errors

enum SessionError: Error, LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH connection not established"
        }
    }
}
