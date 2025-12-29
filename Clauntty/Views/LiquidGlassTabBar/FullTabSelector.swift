import SwiftUI

/// Full-page tab selector showing all tabs with screenshot previews
struct FullTabSelector: View {
    @EnvironmentObject var sessionManager: SessionManager

    let onDismiss: () -> Void
    var onNewTab: (() -> Void)?

    /// Grid columns - 2 columns on iPhone
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("\(allTabs.count) Tabs")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Tab grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(allTabs, id: \.id) { tab in
                            TabCard(
                                tab: tab,
                                isActive: isActive(tab),
                                onSelect: {
                                    selectTab(tab)
                                },
                                onClose: {
                                    closeTab(tab)
                                }
                            )
                        }

                        // New tab button
                        NewTabCard(onTap: {
                            onDismiss()
                            // Trigger new tab sheet after dismissing
                            onNewTab?()
                        })
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Computed Properties

    private var allTabs: [TabItem] {
        var tabs: [TabItem] = sessionManager.sessions.map { .terminal($0) }
        tabs.append(contentsOf: sessionManager.webTabs.map { .web($0) })
        return tabs
    }

    private func isActive(_ tab: TabItem) -> Bool {
        switch (tab, sessionManager.activeTab) {
        case (.terminal(let session), .terminal(let activeId)):
            return session.id == activeId
        case (.web(let webTab), .web(let activeId)):
            return webTab.id == activeId
        default:
            return false
        }
    }

    // MARK: - Actions

    private func selectTab(_ tab: TabItem) {
        switch tab {
        case .terminal(let session):
            sessionManager.switchTo(session)
        case .web(let webTab):
            sessionManager.switchTo(webTab)
        }
        onDismiss()
    }

    private func closeTab(_ tab: TabItem) {
        switch tab {
        case .terminal(let session):
            sessionManager.closeSession(session)
        case .web(let webTab):
            sessionManager.closeWebTab(webTab)
        }

        // If no more tabs, dismiss
        if sessionManager.sessions.isEmpty && sessionManager.webTabs.isEmpty {
            onDismiss()
        }
    }
}

// MARK: - Tab Card

/// Individual tab card showing screenshot preview and title
struct TabCard: View {
    let tab: TabItem
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Screenshot preview area
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))

                // Screenshot or placeholder
                if let screenshot = screenshot {
                    GeometryReader { geo in
                        Image(uiImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .clipped()
                } else {
                    // Placeholder
                    VStack(spacing: 8) {
                        Image(systemName: iconName)
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(tab.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Close button overlay
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(8)
                    }
                    Spacer()
                }

                // Active indicator
                if isActive {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 3)
                }
            }
            .aspectRatio(9/16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(perform: onSelect)

            // Title below card
            HStack(spacing: 4) {
                // Status indicator
                statusIndicator

                Text(tab.title)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
    }

    private var iconName: String {
        switch tab {
        case .terminal: return "terminal"
        case .web: return "globe"
        }
    }

    private var screenshot: UIImage? {
        switch tab {
        case .terminal(let session):
            return session.cachedScreenshot
        case .web(let webTab):
            return webTab.cachedScreenshot
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch tab {
        case .terminal(let session):
            Circle()
                .fill(statusColor(for: session.state))
                .frame(width: 6, height: 6)
        case .web:
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundColor(.blue)
        }
    }

    private func statusColor(for state: Session.State) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}

// MARK: - New Tab Card

/// Card for creating a new tab
struct NewTabCard: View {
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundColor(.gray)
                    )

                Image(systemName: "plus")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.gray)
            }
            .aspectRatio(9/16, contentMode: .fit)
            .onTapGesture(perform: onTap)

            Text("New Tab")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Preview

#Preview {
    FullTabSelector(onDismiss: {})
        .environmentObject(SessionManager())
}
