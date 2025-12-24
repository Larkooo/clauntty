import Foundation
import os.log

/// Metadata stored for each session in ~/.clauntty/sessions.json
struct SessionMetadata: Codable {
    var name: String
    var created: Date
}

/// Information about an existing rtach session on a remote server
struct RtachSession: Identifiable {
    let id: String          // Session ID (filename)
    var name: String        // Display name (from metadata or generated)
    let lastActive: Date    // Last modification time
    let socketPath: String  // Full path to socket
    let created: Date?      // Creation time from metadata

    /// Human-readable description of last activity
    var lastActiveDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActive, relativeTo: Date())
    }
}

/// Handles deploying rtach to remote servers for session persistence
class RtachDeployer {
    private let connection: SSHConnection

    /// Remote path where rtach is installed
    static let remoteBinPath = "~/.clauntty/bin/rtach"
    static let remoteSessionsPath = "~/.clauntty/sessions"
    static let remoteMetadataPath = "~/.clauntty/sessions.json"

    /// Expected rtach version - must match rtach's version constant
    /// Increment this when rtach is updated to force redeployment
    static let expectedVersion = "1.3.0"

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// Deploy rtach to the remote server if not already present
    /// Returns the command to wrap the shell with rtach
    func deployIfNeeded(sessionId: String = "default") async throws -> String {
        Logger.clauntty.info("Checking rtach deployment status...")

        // 1. Check remote architecture
        let arch = try await getRemoteArch()
        Logger.clauntty.info("Remote architecture: \(arch)")

        // 2. Check if rtach exists and is executable
        let exists = try await rtachExists()

        if !exists {
            Logger.clauntty.info("rtach not found, deploying...")
            try await deploy(arch: arch)
        } else {
            Logger.clauntty.info("rtach already deployed")
        }

        // 3. Ensure sessions directory exists
        _ = try await connection.executeCommand("mkdir -p \(Self.remoteSessionsPath)")

        // 4. Return the wrapped shell command
        let sessionPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        return "\(Self.remoteBinPath) -A \(sessionPath) $SHELL"
    }

    /// Get the shell command for rtach (assumes already deployed)
    func shellCommand(sessionId: String = "default") -> String {
        let sessionPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        return "\(Self.remoteBinPath) -A \(sessionPath) $SHELL"
    }

    /// List existing rtach sessions on the remote server
    /// Returns sessions sorted by last active time (most recent first)
    func listSessions() async throws -> [RtachSession] {
        // Use stat to get modification times (epoch format for easy parsing)
        // Format: filename epoch_time
        let output = try await connection.executeCommand(
            "for f in \(Self.remoteSessionsPath)/*; do " +
            "[ -S \"$f\" ] && stat -c '%n %Y' \"$f\" 2>/dev/null; " +
            "done || true"
        )

        // Load existing metadata
        var metadata = try await loadSessionMetadata()
        var metadataChanged = false

        var sessions: [RtachSession] = []

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let epochTime = Double(parts[parts.count - 1]) else {
                continue
            }

            let fullPath = String(parts[0..<(parts.count - 1)].joined(separator: " "))
            let sessionId = (fullPath as NSString).lastPathComponent

            // Get or create metadata for this session
            let sessionMeta: SessionMetadata
            if let existing = metadata[sessionId] {
                sessionMeta = existing
            } else {
                // Generate new name for sessions without metadata
                sessionMeta = SessionMetadata(
                    name: SessionNameGenerator.generate(),
                    created: Date(timeIntervalSince1970: epochTime)
                )
                metadata[sessionId] = sessionMeta
                metadataChanged = true
            }

            let session = RtachSession(
                id: sessionId,
                name: sessionMeta.name,
                lastActive: Date(timeIntervalSince1970: epochTime),
                socketPath: fullPath,
                created: sessionMeta.created
            )
            sessions.append(session)
        }

        // Save metadata if we generated new names
        if metadataChanged {
            try await saveSessionMetadata(metadata)
        }

        // Sort by most recent first
        sessions.sort { $0.lastActive > $1.lastActive }

        Logger.clauntty.info("Found \(sessions.count) existing rtach sessions")
        return sessions
    }

    /// Check if rtach is available (deployed) on the remote server
    func isDeployed() async throws -> Bool {
        return try await rtachExists()
    }

    /// Deploy rtach if needed (without creating a session)
    /// Checks version and redeploys if outdated
    func ensureDeployed() async throws {
        Logger.clauntty.info("RtachDeployer.ensureDeployed: checking if update needed...")
        if try await needsUpdate() {
            Logger.clauntty.info("RtachDeployer.ensureDeployed: update needed, getting arch...")
            let arch = try await getRemoteArch()
            Logger.clauntty.info("RtachDeployer.ensureDeployed: deploying for \(arch)...")
            try await deploy(arch: arch)
        }
        // Ensure sessions directory exists
        Logger.clauntty.info("RtachDeployer.ensureDeployed: creating sessions directory...")
        _ = try await connection.executeCommand("mkdir -p \(Self.remoteSessionsPath)")
        Logger.clauntty.info("RtachDeployer.ensureDeployed: done")
    }

    // MARK: - Session Metadata

    /// Load session metadata from remote server
    func loadSessionMetadata() async throws -> [String: SessionMetadata] {
        let output = try await connection.executeCommand(
            "cat \(Self.remoteMetadataPath) 2>/dev/null || echo '{}'"
        )

        let jsonString = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            return try decoder.decode([String: SessionMetadata].self, from: data)
        } catch {
            Logger.clauntty.warning("Failed to decode session metadata: \(error)")
            return [:]
        }
    }

    /// Save session metadata to remote server
    func saveSessionMetadata(_ metadata: [String: SessionMetadata]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(metadata)

        // Write metadata file
        try await connection.executeWithStdin(
            "cat > \(Self.remoteMetadataPath)",
            stdinData: data
        )

        Logger.clauntty.info("Saved session metadata (\(metadata.count) sessions)")
    }

    /// Delete a session (kills the process and removes the socket)
    func deleteSession(sessionId: String) async throws {
        Logger.clauntty.info("Deleting session: \(sessionId)")

        // 1. Kill any rtach processes for this session
        _ = try await connection.executeCommand(
            "pkill -f 'rtach.*\(sessionId)' 2>/dev/null || true"
        )

        // 2. Remove the socket file
        let socketPath = "\(Self.remoteSessionsPath)/\(sessionId)"
        _ = try await connection.executeCommand("rm -f \(socketPath)")

        // 3. Remove from metadata
        var metadata = try await loadSessionMetadata()
        metadata.removeValue(forKey: sessionId)
        try await saveSessionMetadata(metadata)

        Logger.clauntty.info("Session deleted: \(sessionId)")
    }

    /// Rename a session
    func renameSession(sessionId: String, newName: String) async throws {
        guard SessionNameGenerator.isValid(newName) else {
            throw RtachDeployError.invalidSessionName
        }

        var metadata = try await loadSessionMetadata()

        if var sessionMeta = metadata[sessionId] {
            sessionMeta.name = newName
            metadata[sessionId] = sessionMeta
        } else {
            // Create metadata if it doesn't exist
            metadata[sessionId] = SessionMetadata(name: newName, created: Date())
        }

        try await saveSessionMetadata(metadata)
        Logger.clauntty.info("Session renamed: \(sessionId) -> \(newName)")
    }

    // MARK: - Private

    private func getRemoteArch() async throws -> String {
        let output = try await connection.executeCommand("uname -m")
        let arch = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize arch names
        switch arch {
        case "x86_64", "amd64":
            return "x86_64"
        case "aarch64", "arm64":
            return "aarch64"
        default:
            throw RtachDeployError.unsupportedArchitecture(arch)
        }
    }

    private func rtachExists() async throws -> Bool {
        let output = try await connection.executeCommand("test -x \(Self.remoteBinPath) && echo exists || echo missing")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "exists"
    }

    /// Get the version of rtach installed on remote server (nil if not installed or version unknown)
    private func getRemoteVersion() async throws -> String? {
        let output = try await connection.executeCommand("\(Self.remoteBinPath) --version 2>/dev/null || echo unknown")
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == "unknown" ? nil : version
    }

    /// Check if remote rtach needs to be updated
    private func needsUpdate() async throws -> Bool {
        guard try await rtachExists() else {
            return true // Not installed, needs deployment
        }

        guard let remoteVersion = try await getRemoteVersion() else {
            Logger.clauntty.info("Remote rtach version unknown, will redeploy")
            return true // Can't determine version, redeploy to be safe
        }

        let needsUpdate = remoteVersion != Self.expectedVersion
        if needsUpdate {
            Logger.clauntty.info("Remote rtach version \(remoteVersion) != expected \(Self.expectedVersion), will update")
        } else {
            Logger.clauntty.info("Remote rtach version \(remoteVersion) is up to date")
        }
        return needsUpdate
    }

    private func deploy(arch: String) async throws {
        // Get the binary from app bundle
        guard let binaryData = loadBundledBinary(for: arch) else {
            throw RtachDeployError.binaryNotFound(arch)
        }

        Logger.clauntty.info("Uploading rtach binary (\(binaryData.count) bytes)...")

        // Create directory
        _ = try await connection.executeCommand("mkdir -p ~/.clauntty/bin")

        // Upload binary via stdin
        // Use 'cat > file' trick since we don't have SFTP
        try await connection.executeWithStdin(
            "cat > \(Self.remoteBinPath) && chmod +x \(Self.remoteBinPath)",
            stdinData: binaryData
        )

        // Verify deployment
        let verified = try await rtachExists()
        if !verified {
            throw RtachDeployError.deploymentFailed
        }

        Logger.clauntty.info("rtach deployed successfully")
    }

    private func loadBundledBinary(for arch: String) -> Data? {
        let binaryName: String
        switch arch {
        case "x86_64":
            binaryName = "rtach-x86_64-linux-musl"
        case "aarch64":
            binaryName = "rtach-aarch64-linux-musl"
        default:
            return nil
        }

        // Try to find in bundle
        if let url = Bundle.main.url(forResource: binaryName, withExtension: nil, subdirectory: "rtach") {
            return try? Data(contentsOf: url)
        }

        // Fallback: try without subdirectory
        if let url = Bundle.main.url(forResource: binaryName, withExtension: nil) {
            return try? Data(contentsOf: url)
        }

        Logger.clauntty.error("Could not find bundled binary: \(binaryName)")
        return nil
    }
}

// MARK: - Errors

enum RtachDeployError: Error, LocalizedError {
    case unsupportedArchitecture(String)
    case binaryNotFound(String)
    case deploymentFailed
    case metadataSaveFailed
    case invalidSessionName

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Unsupported remote architecture: \(arch)"
        case .binaryNotFound(let arch):
            return "rtach binary not found for architecture: \(arch)"
        case .deploymentFailed:
            return "Failed to deploy rtach to remote server"
        case .metadataSaveFailed:
            return "Failed to save session metadata"
        case .invalidSessionName:
            return "Invalid session name. Use only letters, numbers, and hyphens."
        }
    }
}
