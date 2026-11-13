import SwiftUI

/// Zero-typing RFC 8628 pairing view with a 6-digit code page and a swipe-down wrist QR page.
struct PairingView: View {
    let viewModel: PairingViewModel
    let pendingQueueCount: Int

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPage = 0
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                loadingView
            case .active(let session):
                activePairingTabs(session: session)
            case .expired:
                statusActionView(
                    icon: "clock.badge.exclamationmark",
                    iconColor: .orange,
                    title: "Code Expired",
                    message: nil,
                    buttonTitle: "New Code"
                )
            case .rateLimited:
                statusActionView(
                    icon: "hourglass",
                    iconColor: .orange,
                    title: "Slow Down",
                    message: "Too many attempts, tap Retry in a moment",
                    buttonTitle: "Retry"
                )
            case .error(let message):
                statusActionView(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    title: "Pairing Error",
                    message: message,
                    buttonTitle: "Retry"
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if selectedPage == 0 || !isActiveSession {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                pairingViewModel: viewModel,
                pendingQueueCount: pendingQueueCount
            )
        }
        .onAppear {
            viewModel.onAppear(isSceneActive: scenePhase == .active)
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
    }

    // MARK: - Subviews

    private var isActiveSession: Bool {
        if case .active = viewModel.phase { return true }
        return false
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)
            Text("Getting code…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            queuedMemosHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private func activePairingTabs(session: PairingViewModel.SessionDisplay) -> some View {
        TabView(selection: $selectedPage) {
            codePage(session: session)
                .tag(0)

            qrCodePage(session: session)
                .tag(1)
        }
        .tabViewStyle(.verticalPage)
    }

    private func codePage(session: PairingViewModel.SessionDisplay) -> some View {
        GeometryReader { geometry in
            VStack(spacing: max(4, geometry.size.height * 0.03)) {
                Spacer(minLength: 0)

                Text("Enter on \(session.pairHost)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(session.userCodeFormatted)
                    .font(.system(.title2, design: .monospaced).bold())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)

                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Waiting to connect…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    let remaining = max(0, Int(ceil(session.expiresAt.timeIntervalSince(context.date))))
                    Text("Expires in \(formattedCountdown(seconds: remaining))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(remaining <= 30 ? .orange : .secondary)
                }

                queuedMemosHint

                Spacer(minLength: 0)

                Label("Swipe down for QR", systemImage: "chevron.compact.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        }
    }

    private func qrCodePage(session: PairingViewModel.SessionDisplay) -> some View {
        GeometryReader { geometry in
            let qrSide = min(geometry.size.width * 0.78, geometry.size.height * 0.74)

            VStack(spacing: 6) {
                Spacer(minLength: 0)

                QRCodeView(urlString: session.pairURL)
                    .frame(width: qrSide, height: qrSide)

                Text("Scan with iPhone Camera")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
        }
    }

    private func statusActionView(
        icon: String,
        iconColor: Color,
        title: String,
        message: String?,
        buttonTitle: String
    ) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }

            queuedMemosHint

            Button(buttonTitle) {
                viewModel.requestNewCode()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var queuedMemosHint: some View {
        if pendingQueueCount > 0 {
            Text("\(pendingQueueCount) \(pendingQueueCount == 1 ? "memo" : "memos") queued")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    private func formattedCountdown(seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview("Pairing") {
    PairingView(viewModel: PairingViewModel(), pendingQueueCount: 1)
}

