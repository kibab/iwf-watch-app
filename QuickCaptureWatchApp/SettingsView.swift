import SwiftUI

/// Watch Settings sheet showing pairing status, backend URL override, and Unpair action.
struct SettingsView: View {
    let pairingViewModel: PairingViewModel
    let pendingQueueCount: Int

    @Environment(\.dismiss) private var dismiss
    @State private var serverURLInput: String = Config.apiBaseURL
    @State private var showUnpairConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if pairingViewModel.isPaired {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected (••••\(pairingViewModel.tokenLastChars))")
                                .font(.footnote)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                                .foregroundStyle(.secondary)
                            Text("Not Connected")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if pendingQueueCount > 0 {
                        Text("\(pendingQueueCount) queued \(pendingQueueCount == 1 ? "memo" : "memos") waiting to upload")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Server") {
                    TextField("Backend URL", text: $serverURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption2)
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
                        .font(.caption2)
                    }
                }

                if pairingViewModel.isPaired {
                    Section {
                        Button("Unpair Watch", role: .destructive) {
                            showUnpairConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        applyServerURL()
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Unpair Watch?",
                isPresented: $showUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("Unpair Watch", role: .destructive) {
                    pairingViewModel.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the Watch token from Keychain. You will need to pair again.")
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

#Preview {
    SettingsView(pairingViewModel: PairingViewModel(), pendingQueueCount: 1)
}

