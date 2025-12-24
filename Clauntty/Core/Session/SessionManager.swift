import Foundation
import NIOCore
import NIOSSH
import os.log

/// Manages all terminal sessions and connection pooling
/// Reuses SSH connections when opening multiple tabs to the same server
@MainActor
class SessionManager: ObservableObject {
    // MARK: - Published State

    /// All active sessions
    @Published var sessions: [Session] = []

    /// Currently active session ID (shown in terminal view)
    @Published var activeSessionId: UUID?

    /// Currently active session
    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
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
            try await deployer.ensureDeployed()
            rtachDeployers[poolKey] = deployer
            let sessions = try await deployer.listSessions()
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

    /// Check if there are any active sessions
    var hasSessions: Bool {
        !sessions.isEmpty
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
