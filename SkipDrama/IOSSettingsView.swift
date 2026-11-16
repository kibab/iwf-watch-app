import SwiftUI

struct IOSSettingsView: View {
    @Bindable var pairingViewModel: PairingViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var serverURLInput: String = Config.apiBaseURL
    @State private var manualTokenInput: String = ""
    @State private var showUnpairConfirmation = false
    @State private var watchSync = WatchSyncManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if pairingViewModel.isPaired {
                        LabeledContent("Status") {
                            Label("Connected (••••\(pairingViewModel.tokenLastChars))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        LabeledContent("Status") {
                            Text("Not Connected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Apple Watch Sync") {
                    LabeledContent("Watch Connectivity") {
                        Text(watchSync.isWatchPaired ? (watchSync.isWatchAppInstalled ? "Paired & Installed" : "Watch Paired") : "No Watch Paired")
                            .foregroundStyle(.secondary)
                    }

                    if let lastSyncedAt = watchSync.lastSyncedAt {
                        LabeledContent("Last Synced") {
                            Text(lastSyncedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if pairingViewModel.isPaired {
                        Button("Push Token to Apple Watch") {
                            WatchSyncManager.shared.pushCurrentStateToWatch()
                        }
                    }
                }

                Section("Replace Capture Token") {
                    HStack {
                        SecureField("iwf_cap_...", text: $manualTokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Paste") {
                            if let pasted = UIPasteboard.general.string {
                                manualTokenInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }

                    if let error = pairingViewModel.manualTokenError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Save Token") {
                        if pairingViewModel.pairWithManualToken(manualTokenInput) {
                            manualTokenInput = ""
                        }
                    }
                    .disabled(manualTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Server") {
                    TextField("Backend URL", text: $serverURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit {
                            applyServerURL()
                        }

                    if normalizedInput != Config.apiBaseURL {
                        Button("Save URL") {
                            applyServerURL()
                        }
                    }

                    if Config.apiBaseURL != Config.defaultAPIBaseURL {
                        Button("Reset to Default") {
                            serverURLInput = Config.defaultAPIBaseURL
                            Config.setAPIBaseURL(nil)
                            pairingViewModel.handleServerURLChanged()
                        }
                    }
                }

                Section("System Integrations") {
                    Label("Action Button: Settings → Action Button → Shortcut → Start Voice Capture", systemImage: "button.programmable")
                        .font(.footnote)
                    Label("Control Center & Lock Screen: Customize controls and add SkipDrama Voice / Text Capture", systemImage: "switch.2")
                        .font(.footnote)
                    Label("Share Sheet: Share links, text, images, or PDFs directly from Safari and Files", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }

                if pairingViewModel.isPaired {
                    Section {
                        Button("Unpair iPhone", role: .destructive) {
                            showUnpairConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyServerURL()
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Unpair iPhone?",
                isPresented: $showUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("Unpair iPhone", role: .destructive) {
                    pairingViewModel.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the SkipDrama capture token from the shared Keychain. Standalone Watch pairing remains intact.")
            }
        }
    }

    private var normalizedInput: String {
        let trimmed = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Config.defaultAPIBaseURL : trimmed
    }

    private func applyServerURL() {
        let trimmed = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = Config.apiBaseURL
        if trimmed.isEmpty || trimmed == Config.defaultAPIBaseURL {
            Config.setAPIBaseURL(nil)
            serverURLInput = Config.defaultAPIBaseURL
        } else {
            Config.setAPIBaseURL(trimmed)
        }
        if Config.apiBaseURL != previous {
            pairingViewModel.handleServerURLChanged()
        }
    }
}
