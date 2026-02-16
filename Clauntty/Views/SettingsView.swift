import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sshKeyStore: SSHKeyStore
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var notificationManager = NotificationManager.shared
    @ObservedObject var powerManager = PowerManager.shared
    @ObservedObject var speechManager = SpeechManager.shared
    @State private var showingDownloadConfirmation = false
    @AppStorage("sessionManagementEnabled") private var sessionManagementEnabled = true
    @State private var fontSize: Float = FontSizePreference.current
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        HStack {
                            Text("Theme")
                            Spacer()
                            Text(ghosttyApp.currentTheme?.name ?? "Default")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Stepper("", value: $fontSize, in: 6...36, step: 1)
                            .labelsHidden()
                            .onChange(of: fontSize) { _, newValue in
                                FontSizePreference.save(newValue)
                            }
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle("Session Management", isOn: $sessionManagementEnabled)
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("When enabled, terminal sessions persist on the server using rtach. Reconnecting restores your session with scrollback history.")
                }

                Section {
                    NavigationLink {
                        SSHKeyManagementView()
                    } label: {
                        HStack {
                            Label("SSH Keys", systemImage: "key.fill")
                            Spacer()
                            Text("\(sshKeyStore.keys.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Manage saved private keys used for SSH key authentication.")
                }

                Section {
                    voiceInputContent
                } header: {
                    Text("Voice Input")
                } footer: {
                    Text("Speak commands instead of typing. Uses on-device speech recognition for privacy.")
                }

                Section {
                    Toggle("Battery Saver", isOn: $powerManager.batterySaverEnabled)
                } header: {
                    Text("Performance")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reduces rendering frequency to extend battery life.")
                        if powerManager.currentMode == .lowPower && !powerManager.batterySaverEnabled {
                            Text("Currently active due to low battery, thermal throttling, or iOS Low Power Mode.")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section {
                    Picker("Input notifications", selection: $notificationManager.notificationMode) {
                        ForEach(NotificationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    // Show system settings link if permission denied
                    if !notificationManager.isAuthorized && notificationManager.hasPromptedForPermission {
                        Button("Enable in Settings") {
                            openNotificationSettings()
                        }
                        .foregroundColor(.blue)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified when a terminal is waiting for your input while the app is in the background.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
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

    @ViewBuilder
    private var voiceInputContent: some View {
        switch speechManager.modelState {
        case .notDownloaded:
            Button {
                showingDownloadConfirmation = true
            } label: {
                HStack {
                    Label("Enable Voice Input", systemImage: "mic.fill")
                    Spacer()
                    Text("~800 MB")
                        .foregroundColor(.secondary)
                }
            }
            .alert("Download Speech Model?", isPresented: $showingDownloadConfirmation) {
                Button("Download") {
                    Task {
                        await speechManager.downloadModel()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will download approximately 800 MB of data for on-device speech recognition. The model runs entirely on your device for privacy.")
            }

        case .downloading(let progress):
            HStack {
                Label("Downloading...", systemImage: "arrow.down.circle")
                Spacer()
                if progress > 0 {
                    ProgressView(value: Double(progress))
                        .frame(width: 100)
                } else {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

        case .ready:
            HStack {
                Label("Voice input enabled", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Spacer()
            }
            Button("Delete Speech Model", role: .destructive) {
                speechManager.deleteModel()
            }

        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry") {
                    Task {
                        await speechManager.downloadModel()
                    }
                }
            }
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }
}

#Preview {
    SettingsView()
        .environmentObject(GhosttyApp())
        .environmentObject(AppState())
        .environmentObject(SSHKeyStore())
}

private struct SSHKeyManagementView: View {
    @EnvironmentObject var sshKeyStore: SSHKeyStore

    @State private var showingKeyImportSheet = false
    @State private var showingKeyContentSheet = false
    @State private var keyContentPreview = ""
    @State private var keyContentPreviewLabel = ""
    @State private var keyToDelete: SSHKey?
    @State private var errorMessage = ""
    @State private var showingError = false

    private var sortedKeys: [SSHKey] {
        sshKeyStore.keys.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if sortedKeys.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No SSH keys saved")
                        .foregroundColor(.secondary)
                    Text("Add a key to use SSH key authentication for your servers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(sortedKeys) { key in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(key.label)
                            .font(.headline)

                        Text("Added \(key.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 16) {
                            Button {
                                showPrivateKeyContent(for: key)
                            } label: {
                                Label("View", systemImage: "doc.text.magnifyingglass")
                            }

                            Button(role: .destructive) {
                                keyToDelete = key
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingKeyImportSheet = true
                } label: {
                    Label("Add Key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingKeyImportSheet) {
            SSHKeyImportSheet(sshKeyStore: sshKeyStore) { _ in }
        }
        .sheet(isPresented: $showingKeyContentSheet) {
            SSHKeyContentSheet(
                keyLabel: keyContentPreviewLabel,
                keyContent: keyContentPreview
            )
        }
        .alert("Delete SSH Key?", isPresented: deleteAlertPresented) {
            Button("Delete", role: .destructive) {
                guard let key = keyToDelete else { return }
                do {
                    try sshKeyStore.deleteKey(key)
                } catch {
                    errorMessage = "Failed to delete key: \(error.localizedDescription)"
                    showingError = true
                }
                keyToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                keyToDelete = nil
            }
        } message: {
            Text("This removes the key from this device. Connections using this key will need another key.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { keyToDelete != nil },
            set: { newValue in
                if !newValue {
                    keyToDelete = nil
                }
            }
        )
    }

    private func showPrivateKeyContent(for key: SSHKey) {
        do {
            keyContentPreview = try sshKeyStore.privateKeyContent(for: key.id)
            keyContentPreviewLabel = key.label
            showingKeyContentSheet = true
        } catch {
            errorMessage = "Failed to load key content: \(error.localizedDescription)"
            showingError = true
        }
    }
}

private struct SSHKeyContentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let keyLabel: String
    let keyContent: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sensitive: this is your full private key.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: .constant(keyContent))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .navigationTitle(keyLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = keyContent
                    }
                }
            }
        }
    }
}
