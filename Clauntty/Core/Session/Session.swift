import Foundation
import NIOCore
import NIOSSH
import os.log

/// Represents a single terminal session (one tab)
/// Each session has its own SSH channel and terminal surface
@MainActor
class Session: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    let connectionConfig: SavedConnection
    let createdAt: Date

    // MARK: - State

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .disconnected

    /// Dynamic title set by terminal escape sequences (OSC 0/1/2)
    @Published var dynamicTitle: String?

    /// Display title for tab - prefer dynamic title if set
    var title: String {
        if let dynamic = dynamicTitle, !dynamic.isEmpty {
            return dynamic
        }
        if !connectionConfig.name.isEmpty {
            return connectionConfig.name
        }
        return "\(connectionConfig.username)@\(connectionConfig.host)"
    }

    // MARK: - Input Detection (OSC 133 Shell Integration)

    /// Terminal prompt state based on OSC 133 sequences
    enum PromptState {
        case unknown           // No shell integration detected
        case promptDisplayed   // OSC 133;A - prompt shown, waiting for input
        case commandRunning    // OSC 133;B/C - command being executed
        case commandFinished   // OSC 133;D - command completed
    }

    /// Current prompt state from shell integration
    @Published private(set) var promptState: PromptState = .unknown

    /// Whether the terminal is waiting for user input
    @Published private(set) var isWaitingForInput: Bool = false

    /// Timer for detecting inactivity after output stops
    private var inactivityTimer: Timer?

    /// How long to wait after output stops before considering terminal idle (seconds)
    private let inactivityThreshold: TimeInterval = 1.5

    // MARK: - SSH Channel

    /// The SSH child channel for this session
    private(set) var sshChannel: Channel?

    /// Channel handler for data flow
    private(set) var channelHandler: SSHChannelHandler?

    /// Reference to parent connection (for sending data)
    weak var parentConnection: SSHConnection?

    /// Strong reference to SSH connection - each session owns its connection
    /// This keeps the connection alive for the lifetime of the session
    var sshConnection: SSHConnection?

    // MARK: - Terminal Size

    /// Initial terminal size to use when connecting (rows, columns)
    /// Set this before connecting for correct initial PTY size
    var initialTerminalSize: (rows: Int, columns: Int) = (30, 60)

    // MARK: - rtach Session

    /// The rtach session ID to use when connecting (nil = create new session)
    var rtachSessionId: String?

    // MARK: - Scrollback Buffer

    /// Buffer of all received data (for persistence)
    private(set) var scrollbackBuffer = Data()

    /// Maximum scrollback buffer size (50KB)
    private let maxScrollbackSize = 50 * 1024

    // MARK: - Callbacks

    /// Called when data is received from SSH (to display in terminal)
    var onDataReceived: ((Data) -> Void)?

    /// Called when session state changes
    var onStateChanged: ((State) -> Void)?

    /// Called when old scrollback is received (to prepend to terminal)
    var onScrollbackReceived: ((Data) -> Void)?

    /// Called when a port forward is requested via OSC 777
    var onPortForwardRequested: ((Int) -> Void)?

    /// Called when a web tab should be opened via OSC 777
    var onOpenTabRequested: ((Int) -> Void)?

    // MARK: - Scrollback Request State

    /// State machine for scrollback request/response
    private enum ScrollbackState {
        case idle                          // Not requesting scrollback
        case waitingForHeader              // Sent request, waiting for 5-byte header
        case receivingData(remaining: Int) // Receiving scrollback data
    }

    /// Current scrollback request state
    private var scrollbackState: ScrollbackState = .idle

    /// Buffer for accumulating scrollback response
    private var scrollbackResponseBuffer = Data()

    /// Buffer for partial header (if header arrives split across packets)
    private var headerBuffer = Data()

    /// Whether we've already requested scrollback for this session
    private var scrollbackRequested = false

    // MARK: - Initialization

    init(connectionConfig: SavedConnection) {
        self.id = UUID()
        self.connectionConfig = connectionConfig
        self.createdAt = Date()
    }

    // MARK: - Channel Management

    /// Attach an SSH channel to this session
    func attach(channel: Channel, handler: SSHChannelHandler, connection: SSHConnection) {
        self.sshChannel = channel
        self.channelHandler = handler
        self.parentConnection = connection
        self.state = .connected
        onStateChanged?(.connected)
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel attached, channelHandler is set")
    }

    /// Detach the channel (on disconnect)
    func detach() {
        // Clean up inactivity timer
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        // Disconnect our SSH connection
        sshConnection?.disconnect()
        sshConnection = nil
        sshChannel = nil
        channelHandler = nil
        parentConnection = nil
        state = .disconnected
        onStateChanged?(.disconnected)
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel detached")
    }

    // MARK: - Data Flow

    /// Handle data received from SSH
    func handleDataReceived(_ data: Data) {
        // If we're receiving a scrollback response, handle it separately
        if case .idle = scrollbackState {
            // Normal data flow
            handleNormalData(data)
        } else {
            // Scrollback response handling
            handleScrollbackResponse(data)
        }
    }

    // MARK: - Loading Indicator

    /// Whether we're currently loading a large amount of data (show loading indicator)
    @Published private(set) var isLoadingContent: Bool = false

    /// Bytes received in the current sliding window
    private var recentBytes: [(Date, Int)] = []

    /// Timer to check if loading is complete
    private var loadingCheckTimer: Timer?

    /// Threshold: show loading if we receive this many bytes in the window
    private let loadingShowThreshold = 10 * 1024  // 10KB (show quickly)

    /// Window size for tracking recent bytes
    private let loadingWindowSize: TimeInterval = 0.1  // 100ms

    /// How long of low activity before hiding loading indicator
    private let loadingHideDelay: TimeInterval = 0.3  // 300ms

    /// Update loading state based on incoming data rate
    private func updateLoadingState(bytesReceived: Int) {
        let now = Date()

        // Add this chunk to recent bytes
        recentBytes.append((now, bytesReceived))

        // Remove old entries outside the window
        let windowStart = now.addingTimeInterval(-loadingWindowSize)
        recentBytes.removeAll { $0.0 < windowStart }

        // Calculate bytes in window
        let bytesInWindow = recentBytes.reduce(0) { $0 + $1.1 }

        // If receiving lots of data, show loading indicator
        if bytesInWindow >= loadingShowThreshold {
            if !isLoadingContent {
                isLoadingContent = true
                Logger.clauntty.info("[LOAD] Showing loading indicator (bytes in window: \(bytesInWindow))")
            }

            // Reset/restart the hide timer
            loadingCheckTimer?.invalidate()
            loadingCheckTimer = Timer.scheduledTimer(withTimeInterval: loadingHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.checkLoadingComplete()
                }
            }
        }
    }

    /// Check if loading is complete (called after delay)
    private func checkLoadingComplete() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-loadingWindowSize)
        recentBytes.removeAll { $0.0 < windowStart }

        let bytesInWindow = recentBytes.reduce(0) { $0 + $1.1 }

        // If data rate is low, hide loading indicator
        if bytesInWindow < 1024 {  // Less than 1KB in window
            if isLoadingContent {
                isLoadingContent = false
                Logger.clauntty.info("[LOAD] Hiding loading indicator (bytes in window: \(bytesInWindow))")
            }
        } else {
            // Still receiving data, check again later
            loadingCheckTimer = Timer.scheduledTimer(withTimeInterval: loadingHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.checkLoadingComplete()
                }
            }
        }
    }

    /// Handle normal terminal data
    private func handleNormalData(_ data: Data) {
        // Track loading state for showing loading indicator
        updateLoadingState(bytesReceived: data.count)

        // Parse OSC 133 sequences for shell integration
        parseOSC133(data)

        // Parse OSC 777 sequences for Clauntty commands (port forwarding)
        parseOSC777(data)

        // Reset inactivity timer - we received output
        resetInactivityTimer()

        // Append to scrollback buffer
        scrollbackBuffer.append(data)

        // Trim if too large (keep most recent data)
        if scrollbackBuffer.count > maxScrollbackSize {
            let excess = scrollbackBuffer.count - maxScrollbackSize
            scrollbackBuffer.removeFirst(excess)
        }

        // Forward to terminal
        onDataReceived?(data)
    }

    /// Handle scrollback response data (when in scrollback receive mode)
    private func handleScrollbackResponse(_ data: Data) {
        var remainingData = data
        var processedAny = false

        while !remainingData.isEmpty {
            switch scrollbackState {
            case .idle:
                // Shouldn't happen, but if we get here, forward remaining data normally
                if processedAny {
                    handleNormalData(remainingData)
                }
                return

            case .waitingForHeader:
                // Accumulate bytes until we have 5 bytes for the header
                let headerSize = 5  // 1 byte type + 4 bytes length
                let needed = headerSize - headerBuffer.count
                let available = min(needed, remainingData.count)

                headerBuffer.append(remainingData.prefix(available))
                remainingData = remainingData.dropFirst(available)
                processedAny = true

                if headerBuffer.count >= headerSize {
                    // Parse header: [type: 1 byte][length: 4 bytes little-endian]
                    let type = headerBuffer[0]
                    // Use loadUnaligned since the UInt32 is at offset 1 (not 4-byte aligned)
                    let length = headerBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
                    }

                    Logger.clauntty.info("Scrollback header: type=\(type), length=\(length)")

                    if type == 1 && length > 0 {
                        // Type 1 = scrollback, transition to receiving data
                        scrollbackState = .receivingData(remaining: Int(length))
                        scrollbackResponseBuffer.removeAll(keepingCapacity: true)
                    } else if length == 0 {
                        // Empty scrollback response
                        Logger.clauntty.info("Scrollback response: empty (all data was in initial send)")
                        scrollbackState = .idle
                        headerBuffer.removeAll()
                    } else {
                        // Unknown type, abort
                        Logger.clauntty.warning("Unknown scrollback response type: \(type)")
                        scrollbackState = .idle
                        headerBuffer.removeAll()
                    }
                    headerBuffer.removeAll()
                }

            case .receivingData(let remaining):
                let toRead = min(remaining, remainingData.count)
                scrollbackResponseBuffer.append(remainingData.prefix(toRead))
                remainingData = remainingData.dropFirst(toRead)
                processedAny = true

                let newRemaining = remaining - toRead
                if newRemaining <= 0 {
                    // Complete! Deliver the scrollback
                    let byteCount = self.scrollbackResponseBuffer.count
                    Logger.clauntty.info("Scrollback response complete: \(byteCount) bytes")
                    let scrollbackData = self.scrollbackResponseBuffer
                    self.scrollbackResponseBuffer.removeAll()
                    self.scrollbackState = .idle

                    // Deliver to callback
                    self.onScrollbackReceived?(scrollbackData)
                } else {
                    self.scrollbackState = .receivingData(remaining: newRemaining)
                }
            }
        }
    }

    // MARK: - OSC 133 Parsing (Shell Integration)

    /// Parse OSC 133 sequences to detect prompt state
    /// Format: ESC ] 133 ; <A|B|C|D> BEL  or  ESC ] 133 ; <A|B|C|D> ESC \
    private func parseOSC133(_ data: Data) {
        let bytes = [UInt8](data)
        let ESC: UInt8 = 0x1B
        let BRACKET: UInt8 = 0x5D  // ]
        let SEMICOLON: UInt8 = 0x3B  // ;

        // Look for ESC ] 133 ; <marker>
        for i in 0..<bytes.count {
            // Check for ESC ]
            guard i + 6 < bytes.count,
                  bytes[i] == ESC,
                  bytes[i + 1] == BRACKET,
                  bytes[i + 2] == 0x31,  // '1'
                  bytes[i + 3] == 0x33,  // '3'
                  bytes[i + 4] == 0x33,  // '3'
                  bytes[i + 5] == SEMICOLON else {
                continue
            }

            let marker = bytes[i + 6]
            let newState: PromptState

            switch marker {
            case 0x41:  // 'A' - Prompt displayed - immediately ready for input!
                newState = .promptDisplayed
                if !isWaitingForInput {
                    isWaitingForInput = true
                }
            case 0x42, 0x43:  // 'B' or 'C' - Command started/executing
                newState = .commandRunning
                isWaitingForInput = false  // Definitely not waiting
            case 0x44:  // 'D' - Command finished
                newState = .commandFinished
            default:
                continue
            }

            promptState = newState
        }
    }

    // MARK: - OSC 777 Parsing (Clauntty Commands)

    /// Parse OSC 777 sequences for Clauntty-specific commands
    /// Format: ESC ] 777 ; <command> ; <args> BEL  or  ESC ] 777 ; <command> ; <args> ESC \
    /// Commands:
    ///   - forward;<port> - Forward a port
    ///   - open;<port>    - Open a web tab for a port
    private func parseOSC777(_ data: Data) {
        let bytes = [UInt8](data)
        let ESC: UInt8 = 0x1B
        let BRACKET: UInt8 = 0x5D  // ]
        let BEL: UInt8 = 0x07
        let BACKSLASH: UInt8 = 0x5C  // \

        // Look for ESC ] 7 7 7 ;
        var i = 0
        while i < bytes.count {
            // Check for ESC ]
            guard i + 5 < bytes.count,
                  bytes[i] == ESC,
                  bytes[i + 1] == BRACKET,
                  bytes[i + 2] == 0x37,  // '7'
                  bytes[i + 3] == 0x37,  // '7'
                  bytes[i + 4] == 0x37,  // '7'
                  bytes[i + 5] == 0x3B   // ';'
            else {
                i += 1
                continue
            }

            // Find the end of the OSC sequence (BEL or ESC \)
            var endIndex = i + 6
            while endIndex < bytes.count {
                if bytes[endIndex] == BEL {
                    break
                }
                if bytes[endIndex] == ESC && endIndex + 1 < bytes.count && bytes[endIndex + 1] == BACKSLASH {
                    break
                }
                endIndex += 1
            }

            // Extract the payload between the semicolon and terminator
            if endIndex > i + 6 {
                let payloadBytes = Array(bytes[(i + 6)..<endIndex])
                if let payload = String(bytes: payloadBytes, encoding: .utf8) {
                    handleOSC777Command(payload)
                }
            }

            i = endIndex + 1
        }
    }

    /// Handle a parsed OSC 777 command
    private func handleOSC777Command(_ payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 1)
        guard let command = parts.first else { return }

        switch command {
        case "forward":
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): OSC 777 forward port \(port)")
                onPortForwardRequested?(port)
            }
        case "open":
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): OSC 777 open tab port \(port)")
                onOpenTabRequested?(port)
            }
        default:
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): unknown OSC 777 command: \(command)")
        }
    }

    // MARK: - Inactivity Detection

    /// Reset the inactivity timer when output is received
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()

        // If we were waiting for input, we're not anymore (got output)
        if isWaitingForInput {
            isWaitingForInput = false
        }

        // Schedule timer to check for idle state
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfWaitingForInput()
            }
        }
    }

    /// Check if terminal is waiting for input after inactivity period
    private func checkIfWaitingForInput() {
        // If prompt is displayed or command just finished, we're likely waiting for input
        switch promptState {
        case .promptDisplayed, .commandFinished:
            if !isWaitingForInput {
                isWaitingForInput = true
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): waiting for input")
            }
        case .unknown:
            // No shell integration - fallback to pure inactivity detection
            // Less reliable but better than nothing
            if !isWaitingForInput {
                isWaitingForInput = true
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): waiting for input (fallback, no OSC 133)")
            }
        case .commandRunning:
            // Command is running, not waiting for input
            break
        }
    }

    /// Send data to remote (keyboard input)
    func sendData(_ data: Data) {
        let hasHandler = self.channelHandler != nil
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): sendData called with \(data.count) bytes, channelHandler=\(hasHandler ? "set" : "nil")")
        if channelHandler == nil {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): sendData called but channelHandler is nil!")
        }
        channelHandler?.sendToRemote(data)
    }

    /// Send window size change
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        guard let channel = sshChannel else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot send window change, no channel")
            return
        }

        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(columns),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(windowChange, promise: nil)
        }
        Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): window change \(columns)x\(rows)")
    }

    // MARK: - Scrollback Request

    /// Request old scrollback from rtach (everything before the initial 16KB)
    /// This is called after connection is established to load the full history.
    func requestScrollback() {
        guard !scrollbackRequested else {
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): scrollback already requested")
            return
        }

        guard channelHandler != nil else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot request scrollback, no channel")
            return
        }

        scrollbackRequested = true
        scrollbackState = .waitingForHeader
        headerBuffer.removeAll()

        // Send rtach request_scrollback packet
        // Format: [type: 1 byte = 5][length: 1 byte = 0]
        let packet = Data([5, 0])  // MessageType.request_scrollback = 5, length = 0
        channelHandler?.sendToRemote(packet)

        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): requested old scrollback from rtach")
    }

    // MARK: - Scrollback Persistence

    /// Get scrollback data for restoration
    func getScrollbackData() -> Data {
        return scrollbackBuffer
    }

    /// Restore scrollback from saved data
    func restoreScrollback(_ data: Data) {
        scrollbackBuffer = data
        // Note: Terminal surface will need to replay this data
    }

    /// Clear scrollback buffer
    func clearScrollback() {
        scrollbackBuffer.removeAll()
    }
}

// MARK: - Hashable

extension Session: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}
