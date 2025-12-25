import SwiftUI
import WebKit

/// View displaying a forwarded web port
struct WebTabView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab
    @State private var webView: WKWebView?

    /// Whether this web tab is currently active
    private var isActive: Bool {
        sessionManager.activeTab == .web(webTab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            WebToolbar(
                webTab: webTab,
                webView: $webView,
                onNavigate: { urlString in
                    navigateTo(urlString)
                }
            )

            // Content
            switch webTab.state {
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Connecting to port \(webTab.remotePort.port)...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

            case .connected:
                WebViewContainer(
                    url: webTab.localURL,
                    webTab: webTab,
                    webViewBinding: $webView
                )

            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Connection Error")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            try? await webTab.startForwarding()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

            case .closed:
                Text("Tab closed")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .onAppear {
            // Dismiss terminal keyboard when web tab appears
            if isActive {
                dismissKeyboard()
            }
        }
        .onChange(of: isActive) { _, newValue in
            // Dismiss keyboard when web tab becomes active (switching from terminal)
            if newValue {
                dismissKeyboard()
            }
        }
    }

    /// Navigate to a path (relative to localhost:port)
    private func navigateTo(_ path: String) {
        guard let webView = webView else { return }

        var finalPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure path starts with /
        if !finalPath.hasPrefix("/") {
            finalPath = "/" + finalPath
        }

        let urlString = "http://localhost:\(webTab.localPort)\(finalPath)"

        guard let url = URL(string: urlString) else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }

    /// Dismiss keyboard
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Web Toolbar

struct WebToolbar: View {
    @ObservedObject var webTab: WebTab
    @Binding var webView: WKWebView?
    var onNavigate: (String) -> Void

    /// Current path text in the address bar (just the path, not the host)
    @State private var pathText: String = "/"
    /// Whether the URL field is focused
    @FocusState private var isUrlFocused: Bool

    /// Whether back button should be enabled
    private var canGoBack: Bool {
        webTab.state == .connected && webTab.canGoBack
    }

    /// Whether forward button should be enabled
    private var canGoForward: Bool {
        webTab.state == .connected && webTab.canGoForward
    }

    /// Whether refresh button should be enabled
    private var canRefresh: Bool {
        webTab.state == .connected
    }

    var body: some View {
        HStack(spacing: 8) {
            // Back button - 44pt minimum touch target
            Button {
                webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(canGoBack ? .primary : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!canGoBack)

            // Forward button - 44pt minimum touch target
            Button {
                webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(canGoForward ? .primary : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!canGoForward)

            // Editable URL bar with fixed localhost prefix
            HStack(spacing: 4) {
                if webTab.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                }

                // Fixed port prefix (use String to avoid comma formatting)
                Text(":\(String(webTab.localPort))")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                // Editable path portion
                TextField("/path", text: $pathText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.primary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($isUrlFocused)
                    .lineLimit(1)
                    .onSubmit {
                        onNavigate(pathText)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))
            .cornerRadius(8)

            // Refresh button - 44pt minimum touch target
            Button {
                webView?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(canRefresh ? .primary : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!canRefresh)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(.systemGray6))
        .onAppear {
            updatePathText()
        }
        .onChange(of: webTab.currentURL) { _, _ in
            // Update text when navigation changes (but not while editing)
            if !isUrlFocused {
                updatePathText()
            }
        }
    }

    private func updatePathText() {
        if let url = webTab.currentURL {
            // Extract just the path (and query string if present)
            var path = url.path
            if let query = url.query {
                path += "?\(query)"
            }
            if let fragment = url.fragment {
                path += "#\(fragment)"
            }
            pathText = path.isEmpty ? "/" : path
        } else {
            pathText = "/"
        }
    }
}

// MARK: - WKWebView Container

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    @ObservedObject var webTab: WebTab
    @Binding var webViewBinding: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Add pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // Observe URL changes via KVO
        context.coordinator.observeURL(webView: webView)

        // Load the URL
        let request = URLRequest(url: url)
        webView.load(request)

        // Store reference
        DispatchQueue.main.async {
            self.webViewBinding = webView
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if URL changed significantly
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(webTab: webTab)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let webTab: WebTab
        private var urlObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private weak var webView: WKWebView?

        init(webTab: WebTab) {
            self.webTab = webTab
        }

        @objc func handleRefresh(_ refreshControl: UIRefreshControl) {
            webView?.reload()
            // End refreshing after a short delay (will also end when page finishes loading)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                refreshControl.endRefreshing()
            }
        }

        func observeURL(webView: WKWebView) {
            self.webView = webView
            // Observe URL changes (catches SPA navigation, hash changes, etc.)
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.currentURL = webView.url
                }
            }

            // Observe title changes
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.pageTitle = webView.title
                }
            }

            // Observe back/forward navigation state
            canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.canGoBack = webView.canGoBack
                }
            }

            canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in
                    self?.webTab.canGoForward = webView.canGoForward
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                webTab.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                webTab.isLoading = false
                webTab.pageTitle = webView.title
                webTab.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                webTab.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                webTab.isLoading = false
                // Don't show error for cancelled requests
                if (error as NSError).code != NSURLErrorCancelled {
                    webTab.state = .error(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @StateObject var webTab: WebTab

        init() {
            let port = RemotePort(id: 3000, port: 3000, process: "node", address: "127.0.0.1")
            let connection = SSHConnection(
                host: "localhost",
                port: 22,
                username: "test",
                authMethod: .password,
                connectionId: UUID()
            )
            _webTab = StateObject(wrappedValue: WebTab(remotePort: port, sshConnection: connection))
        }

        var body: some View {
            WebTabView(webTab: webTab)
                .onAppear {
                    webTab.state = .connected
                }
        }
    }

    return PreviewWrapper()
}
