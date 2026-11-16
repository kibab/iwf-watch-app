import SwiftUI

struct IOSOnboardingView: View {
    enum PairingMode: String, CaseIterable, Identifiable {
        case code = "6-Digit Code"
        case manualToken = "Paste Token"

        var id: String { rawValue }
    }

    @Bindable var pairingViewModel: PairingViewModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: PairingMode = .code
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection

                    Picker("Pairing Method", selection: $mode) {
                        ForEach(PairingMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .code {
                        codePairingCard
                    } else {
                        manualTokenCard
                    }

                    watchSyncFootnote
                }
                .padding(20)
            }
            .navigationTitle("Connect SkipDrama")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Server Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                IOSSettingsView(pairingViewModel: pairingViewModel)
            }
            .onAppear {
                pairingViewModel.onAppear(isSceneActive: scenePhase == .active)
            }
            .onDisappear {
                pairingViewModel.onDisappear()
            }
            .onChange(of: scenePhase) { _, newPhase in
                pairingViewModel.handleScenePhaseChange(newPhase)
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Pair your iPhone")
                .font(.title2.bold())

            Text("Connect to \(Config.displayHost()) to capture voice memos, tasks, links, and files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var codePairingCard: some View {
        VStack(spacing: 16) {
            switch pairingViewModel.phase {
            case .loading:
                ProgressView("Requesting pairing code…")
                    .padding(.vertical, 32)

            case .active(let session):
                VStack(spacing: 14) {
                    Text("Open \(session.pairHost)\(Config.settingsIntegrationsPath) and enter:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(session.userCodeFormatted)
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for approval…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        let remaining = max(0, Int(ceil(session.expiresAt.timeIntervalSince(context.date))))
                        Text("Expires in \(formattedCountdown(seconds: remaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(remaining <= 30 ? .orange : .secondary)
                    }

                    if let pairURL = URL(string: session.pairURL) {
                        Link(destination: pairURL) {
                            Label("Open Integrations Page", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    QRCodeView(urlString: session.pairURL)
                        .frame(width: 150, height: 150)
                        .padding(.top, 4)
                }

            case .expired:
                statusCard(
                    icon: "clock.badge.exclamationmark",
                    title: "Code Expired",
                    message: "Generate a fresh 6-digit pairing code to continue.",
                    buttonTitle: "New Code"
                )

            case .rateLimited:
                statusCard(
                    icon: "hourglass",
                    title: "Slow Down",
                    message: "Too many pairing attempts. Wait a moment and retry.",
                    buttonTitle: "Retry"
                )

            case .error(let message):
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "Pairing Error",
                    message: message,
                    buttonTitle: "Retry"
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var manualTokenCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Capture Token")
                .font(.headline)

            Text("Copy an iwf_cap_... token from /settings/integrations on \(Config.displayHost()) and paste it below.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("iwf_cap_...", text: $pairingViewModel.manualTokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        pairingViewModel.manualTokenInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.bordered)
            }

            if let error = pairingViewModel.manualTokenError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                pairingViewModel.pairWithManualToken(pairingViewModel.manualTokenInput)
            } label: {
                Text("Connect with Token")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingViewModel.manualTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var watchSyncFootnote: some View {
        Label(
            "Once connected, SkipDrama automatically syncs your capture token across your iPhone, iPad (via iCloud Keychain), and paired Apple Watch.",
            systemImage: "icloud.and.arrow.up"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func statusCard(icon: String, title: String, message: String, buttonTitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(buttonTitle) {
                pairingViewModel.requestNewCode()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 12)
    }

    private func formattedCountdown(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
