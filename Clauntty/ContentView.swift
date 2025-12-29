import SwiftUI
import os.log

struct ContentView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var edgeGestureCoordinator: EdgeGestureCoordinator

    @State private var showingNewTabSheet = false
    @State private var showingFullTabSelector = false
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
                // Tab bar overlays terminal content with transparent background
                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        // Terminal tabs (full screen, with top padding for tab bar)
                        ForEach(sessionManager.sessions) { session in
                            TerminalView(session: session)
                                .safeAreaInset(edge: .top) {
                                    Color.clear.frame(height: 48) // Tab bar height
                                }
                                .offset(x: offsetForTab(.terminal(session.id), screenWidth: geometry.size.width))
                                .opacity(opacityForTab(.terminal(session.id)))
                                .allowsHitTesting(sessionManager.activeTab == .terminal(session.id) && swipeOffset == 0)
                        }

                        // Web tabs (full screen, with top padding for tab bar)
                        ForEach(sessionManager.webTabs) { webTab in
                            WebTabView(webTab: webTab)
                                .safeAreaInset(edge: .top) {
                                    Color.clear.frame(height: 48) // Tab bar height
                                }
                                .offset(x: offsetForTab(.web(webTab.id), screenWidth: geometry.size.width))
                                .opacity(opacityForTab(.web(webTab.id)))
                                .allowsHitTesting(sessionManager.activeTab == .web(webTab.id) && swipeOffset == 0)
                        }

                        // Tab bar overlay at top
                        VStack(spacing: 0) {
                            LiquidGlassTabBarRepresentable(
                                onNewTab: { showingNewTabSheet = true },
                                onShowTabSelector: { showingFullTabSelector = true },
                                sessionStatesHash: sessionManager.sessionStateVersion
                            )
                            .frame(height: 48)
                            Spacer()
                        }

                        // Edge swipe gesture overlay
                        EdgeSwipeGestureView(
                            screenWidth: geometry.size.width,
                            edgeThreshold: edgeThreshold,
                            swipeThreshold: swipeThreshold,
                            edgeGestureCoordinator: edgeGestureCoordinator,
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
                .fullScreenCover(isPresented: $showingFullTabSelector) {
                    FullTabSelector(
                        onDismiss: { showingFullTabSelector = false },
                        onNewTab: {
                            // Show new tab sheet after a brief delay to let the full cover dismiss
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showingNewTabSheet = true
                            }
                        }
                    )
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
    let edgeGestureCoordinator: EdgeGestureCoordinator
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

        // Wire up gesture registration callbacks
        view.onGesturesAttachedToWindow = { [weak edgeGestureCoordinator] left, right in
            edgeGestureCoordinator?.registerEdgeGestures(left: left, right: right)
        }
        view.onGesturesRemovedFromWindow = { [weak edgeGestureCoordinator] in
            edgeGestureCoordinator?.unregisterEdgeGestures()
        }

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
/// Uses UIScreenEdgePanGestureRecognizer to allow text selection near edges
class EdgeSwipeUIView: UIView {
    var screenWidth: CGFloat = 0
    var edgeThreshold: CGFloat = 30
    var swipeThreshold: CGFloat = 80
    var onDragStart: ((Bool) -> Void)?
    var onDragProgress: ((CGFloat) -> Void)?
    var onDragEnd: ((Bool) -> Void)?

    /// Callback to register edge gestures with coordinator
    var onGesturesAttachedToWindow: ((UIScreenEdgePanGestureRecognizer, UIScreenEdgePanGestureRecognizer) -> Void)?

    /// Callback when gestures are removed from window
    var onGesturesRemovedFromWindow: (() -> Void)?

    private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer!
    private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    private func setupGestures() {
        // Left edge swipe (swipe right to go back)
        leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        leftEdgeGesture.edges = .left
        leftEdgeGesture.cancelsTouchesInView = true
        leftEdgeGesture.delaysTouchesBegan = false
        addGestureRecognizer(leftEdgeGesture)

        // Right edge swipe (swipe left for next tab)
        rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        rightEdgeGesture.edges = .right
        rightEdgeGesture.cancelsTouchesInView = true
        rightEdgeGesture.delaysTouchesBegan = false
        addGestureRecognizer(rightEdgeGesture)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Add gestures to window so they work even when our hitTest returns nil
        if let window = window {
            // Remove from self and add to window for proper edge detection
            if let left = leftEdgeGesture {
                removeGestureRecognizer(left)
                window.addGestureRecognizer(left)
            }
            if let right = rightEdgeGesture {
                removeGestureRecognizer(right)
                window.addGestureRecognizer(right)
            }

            // Notify coordinator that gestures are ready
            if let left = leftEdgeGesture, let right = rightEdgeGesture {
                onGesturesAttachedToWindow?(left, right)
            }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        // Clean up gestures from old window
        if let oldWindow = window, newWindow == nil {
            if let left = leftEdgeGesture {
                oldWindow.removeGestureRecognizer(left)
            }
            if let right = rightEdgeGesture {
                oldWindow.removeGestureRecognizer(right)
            }
            // Notify coordinator that gestures are removed
            onGesturesRemovedFromWindow?()
        }
        super.willMove(toWindow: newWindow)
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let translation = gesture.translation(in: self.window)
        let isLeftEdge = gesture.edges == .left

        switch gesture.state {
        case .began:
            onDragStart?(isLeftEdge)

        case .changed:
            onDragProgress?(translation.x)

        case .ended, .cancelled:
            let shouldComplete: Bool
            if isLeftEdge {
                shouldComplete = translation.x > swipeThreshold
            } else {
                shouldComplete = translation.x < -swipeThreshold
            }
            onDragEnd?(gesture.state == .ended && shouldComplete)

        default:
            break
        }
    }

    // Pass all touches through - edge gestures are on the window
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}

#Preview {
    ContentView()
        .environmentObject(ConnectionStore())
        .environmentObject(AppState())
        .environmentObject(SessionManager())
        .environmentObject(EdgeGestureCoordinator())
}
