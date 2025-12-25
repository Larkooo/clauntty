import SwiftUI
import os.log

struct ContentView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager

    @State private var showingNewTabSheet = false
    @State private var hasCheckedAutoConnect = false

    /// Edge swipe detection threshold (distance from edge to start gesture)
    private let edgeThreshold: CGFloat = 30

    /// Minimum swipe distance to trigger action
    private let swipeThreshold: CGFloat = 80

    /// Current swipe offset for interactive transition
    @State private var swipeOffset: CGFloat = 0

    /// Whether we're currently in an interactive swipe
    @State private var isSwipingFromLeftEdge: Bool = false

    /// Source tab when swipe started (to maintain during animation)
    @State private var swipeSourceTab: SessionManager.ActiveTab?

    /// Target tab during swipe (for preview)
    @State private var swipeTargetTab: SessionManager.ActiveTab?

    /// Whether we're in the completion animation phase
    @State private var isCompletingSwipe: Bool = false

    var body: some View {
        NavigationStack {
            if sessionManager.hasSessions {
                // Show tabs + content when there are active sessions or web tabs
                VStack(spacing: 0) {
                    SessionTabBar(onNewTab: {
                        showingNewTabSheet = true
                    })

                    // Keep ALL views alive, but only show the active one.
                    // This preserves terminal state (font size, scrollback, etc.) across tab switches.
                    GeometryReader { geometry in
                        ZStack {
                            // Terminal tabs
                            ForEach(sessionManager.sessions) { session in
                                TerminalView(session: session)
                                    .offset(x: offsetForTab(.terminal(session.id), screenWidth: geometry.size.width))
                                    .opacity(opacityForTab(.terminal(session.id)))
                                    .allowsHitTesting(sessionManager.activeTab == .terminal(session.id) && swipeOffset == 0)
                            }

                            // Web tabs
                            ForEach(sessionManager.webTabs) { webTab in
                                WebTabView(webTab: webTab)
                                    .offset(x: offsetForTab(.web(webTab.id), screenWidth: geometry.size.width))
                                    .opacity(opacityForTab(.web(webTab.id)))
                                    .allowsHitTesting(sessionManager.activeTab == .web(webTab.id) && swipeOffset == 0)
                            }

                            // Edge swipe gesture overlay
                            EdgeSwipeGestureView(
                                screenWidth: geometry.size.width,
                                edgeThreshold: edgeThreshold,
                                swipeThreshold: swipeThreshold,
                                onDragStart: { isLeftEdge in
                                    isSwipingFromLeftEdge = isLeftEdge
                                    swipeSourceTab = sessionManager.activeTab
                                    // Determine target tab
                                    if isLeftEdge {
                                        swipeTargetTab = sessionManager.previousActiveTab
                                    } else {
                                        swipeTargetTab = sessionManager.nextWaitingTab()
                                    }
                                },
                                onDragProgress: { offset in
                                    swipeOffset = offset
                                },
                                onDragEnd: { completed in
                                    let screenWidth = geometry.size.width
                                    if completed && swipeTargetTab != nil {
                                        isCompletingSwipe = true
                                        triggerHaptic()
                                        // Animate to full screen width first
                                        let targetOffset = isSwipingFromLeftEdge ? screenWidth : -screenWidth
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            swipeOffset = targetOffset
                                        }
                                        // Then switch tabs and reset
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            if isSwipingFromLeftEdge {
                                                sessionManager.switchToPreviousTab()
                                            } else {
                                                sessionManager.switchToNextWaitingTab()
                                            }
                                            // Reset without animation since views are now in correct position
                                            swipeOffset = 0
                                            swipeSourceTab = nil
                                            swipeTargetTab = nil
                                            isCompletingSwipe = false
                                        }
                                    } else {
                                        // Cancelled - animate back to zero
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            swipeOffset = 0
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            swipeSourceTab = nil
                                            swipeTargetTab = nil
                                        }
                                    }
                                }
                            )
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showingNewTabSheet) {
                    NavigationStack {
                        ConnectionListView()
                            .navigationTitle("New Tab")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") {
                                        showingNewTabSheet = false
                                    }
                                }
                            }
                    }
                }
                .onChange(of: sessionManager.sessions.count) { oldCount, newCount in
                    // Dismiss sheet when a new session is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
                .onChange(of: sessionManager.webTabs.count) { oldCount, newCount in
                    // Dismiss sheet when a new web tab is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
            } else {
                // Show connection list when no sessions
                ConnectionListView()
            }
        }
        .onAppear {
            checkAutoConnect()
        }
    }

    /// Check for --connect <name> and --tabs launch arguments
    private func checkAutoConnect() {
        guard !hasCheckedAutoConnect else { return }
        hasCheckedAutoConnect = true

        guard let connectionName = LaunchArgs.autoConnectName() else { return }

        Logger.clauntty.info("Auto-connect requested for: \(connectionName)")

        // Find connection by name (case-insensitive)
        guard let connection = connectionStore.connections.first(where: {
            $0.name.lowercased() == connectionName.lowercased() ||
            $0.host.lowercased() == connectionName.lowercased()
        }) else {
            let available = connectionStore.connections.map { "\($0.name) (\($0.host))" }.joined(separator: ", ")
            Logger.clauntty.error("Auto-connect: connection '\(connectionName)' not found. Available: \(available)")
            return
        }

        Logger.clauntty.info("Auto-connect: found connection \(connection.name) (\(connection.host))")

        // Check for multi-tab specs
        let tabSpecs = LaunchArgs.tabSpecs()

        Task {
            do {
                // First, establish SSH and deploy rtach
                Logger.clauntty.info("Auto-connect: establishing SSH and deploying rtach...")
                let (rtachSessions, _) = try await sessionManager.connectAndListSessions(for: connection) ?? ([], nil)
                Logger.clauntty.info("Auto-connect: rtach deployed, found \(rtachSessions.count) existing sessions")

                if let specs = tabSpecs {
                    // Multi-tab mode
                    Logger.clauntty.info("Auto-connect: opening \(specs.count) tabs")
                    for spec in specs {
                        switch spec {
                        case .session(let index):
                            // Connect to existing rtach session by index
                            if index < rtachSessions.count {
                                let rtachSession = rtachSessions[index]
                                Logger.clauntty.info("Auto-connect: opening rtach session \(index): \(rtachSession.id)")
                                let session = sessionManager.createSession(for: connection)
                                session.rtachSessionId = rtachSession.id
                                try await sessionManager.connect(session: session, rtachSessionId: rtachSession.id)
                            } else {
                                Logger.clauntty.warning("Auto-connect: session index \(index) out of range (have \(rtachSessions.count) sessions), creating new")
                                let session = sessionManager.createSession(for: connection)
                                try await sessionManager.connect(session: session)
                            }

                        case .newSession:
                            // Create a new session
                            Logger.clauntty.info("Auto-connect: creating new session")
                            let session = sessionManager.createSession(for: connection)
                            try await sessionManager.connect(session: session)

                        case .port(let portNum):
                            // Port forward - create web tab
                            Logger.clauntty.info("Auto-connect: forwarding port \(portNum)")
                            let remotePort = RemotePort(id: portNum, port: portNum, process: nil, address: "127.0.0.1")
                            _ = try await sessionManager.createWebTab(for: remotePort, config: connection)
                        }
                    }
                    Logger.clauntty.info("Auto-connect: \(specs.count) tabs opened successfully")
                } else {
                    // Single tab mode (original behavior)
                    let session = sessionManager.createSession(for: connection)
                    try await sessionManager.connect(session: session)
                    Logger.clauntty.info("Auto-connect: session connected successfully")
                }
            } catch {
                Logger.clauntty.error("Auto-connect failed: \(error.localizedDescription)")
            }
        }
    }

    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    // MARK: - Swipe Transition Helpers

    /// Calculate X offset for a tab during swipe
    private func offsetForTab(_ tab: SessionManager.ActiveTab, screenWidth: CGFloat) -> CGFloat {
        // Use swipeSourceTab during swipe, otherwise use activeTab
        let activeTab = swipeSourceTab ?? sessionManager.activeTab
        let isSource = activeTab == tab
        let isTarget = swipeTargetTab == tab

        if swipeOffset == 0 && swipeSourceTab == nil {
            // No swipe in progress
            let isActive = sessionManager.activeTab == tab
            return isActive ? 0 : screenWidth
        }

        if isSource {
            // Source tab slides with the swipe
            return swipeOffset
        } else if isTarget {
            // Target tab slides in from the opposite side
            if isSwipingFromLeftEdge {
                // Swiping right: target comes from left
                return -screenWidth + swipeOffset
            } else {
                // Swiping left: target comes from right
                return screenWidth + swipeOffset
            }
        } else {
            // Other tabs stay offscreen
            return screenWidth
        }
    }

    /// Calculate opacity for a tab during swipe
    private func opacityForTab(_ tab: SessionManager.ActiveTab) -> Double {
        // Use swipeSourceTab during swipe, otherwise use activeTab
        let activeTab = swipeSourceTab ?? sessionManager.activeTab
        let isSource = activeTab == tab
        let isTarget = swipeTargetTab == tab

        if swipeOffset == 0 && swipeSourceTab == nil {
            let isActive = sessionManager.activeTab == tab
            return isActive ? 1 : 0
        }

        // Both source and target are visible during swipe
        if isSource || isTarget {
            return 1
        }
        return 0
    }
}

// MARK: - Edge Swipe Gesture View

/// Invisible view that detects edge swipes without blocking touch events in the center
struct EdgeSwipeGestureView: UIViewRepresentable {
    let screenWidth: CGFloat
    let edgeThreshold: CGFloat
    let swipeThreshold: CGFloat
    let onDragStart: (Bool) -> Void  // Bool: isLeftEdge
    let onDragProgress: (CGFloat) -> Void  // Current offset
    let onDragEnd: (Bool) -> Void  // Bool: should complete transition

    func makeUIView(context: Context) -> EdgeSwipeUIView {
        let view = EdgeSwipeUIView()
        view.screenWidth = screenWidth
        view.edgeThreshold = edgeThreshold
        view.swipeThreshold = swipeThreshold
        view.onDragStart = onDragStart
        view.onDragProgress = onDragProgress
        view.onDragEnd = onDragEnd
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: EdgeSwipeUIView, context: Context) {
        uiView.screenWidth = screenWidth
        uiView.edgeThreshold = edgeThreshold
        uiView.swipeThreshold = swipeThreshold
        uiView.onDragStart = onDragStart
        uiView.onDragProgress = onDragProgress
        uiView.onDragEnd = onDragEnd
    }
}

/// UIView subclass that handles edge swipe gestures with interactive feedback
class EdgeSwipeUIView: UIView {
    var screenWidth: CGFloat = 0
    var edgeThreshold: CGFloat = 30
    var swipeThreshold: CGFloat = 80
    var onDragStart: ((Bool) -> Void)?
    var onDragProgress: ((CGFloat) -> Void)?
    var onDragEnd: ((Bool) -> Void)?

    private var touchStartX: CGFloat = 0
    private var touchStartedFromEdge: Bool = false
    private var isLeftEdge: Bool = false
    private var hasStartedDrag: Bool = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only handle touches that start near the edges
        let isNearLeftEdge = point.x < edgeThreshold
        let isNearRightEdge = point.x > bounds.width - edgeThreshold

        if isNearLeftEdge || isNearRightEdge {
            return self
        }

        // Pass through touches in the center
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)

        touchStartX = location.x
        isLeftEdge = location.x < edgeThreshold
        touchStartedFromEdge = isLeftEdge || location.x > bounds.width - edgeThreshold
        hasStartedDrag = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touchStartedFromEdge else { return }

        let location = touch.location(in: self)
        let deltaX = location.x - touchStartX

        // Check if we're swiping in the correct direction
        let isValidSwipe = (isLeftEdge && deltaX > 0) || (!isLeftEdge && deltaX < 0)

        if isValidSwipe {
            if !hasStartedDrag {
                hasStartedDrag = true
                onDragStart?(isLeftEdge)
            }
            onDragProgress?(deltaX)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touchStartedFromEdge else {
            resetState()
            return
        }

        let location = touch.location(in: self)
        let deltaX = location.x - touchStartX

        // Determine if swipe should complete the transition
        let shouldComplete: Bool
        if isLeftEdge {
            shouldComplete = deltaX > swipeThreshold
        } else {
            shouldComplete = deltaX < -swipeThreshold
        }

        if hasStartedDrag {
            onDragEnd?(shouldComplete)
        }

        resetState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if hasStartedDrag {
            onDragEnd?(false)
        }
        resetState()
    }

    private func resetState() {
        touchStartedFromEdge = false
        hasStartedDrag = false
    }
}

#Preview {
    ContentView()
        .environmentObject(ConnectionStore())
        .environmentObject(AppState())
        .environmentObject(SessionManager())
}
