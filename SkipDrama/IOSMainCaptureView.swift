import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSMainCaptureView: View {
    @Bindable var viewModel: IOSCaptureViewModel
    let pairingViewModel: PairingViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTextFieldFocused: Bool

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isShowingDocumentPicker = false
    @State private var isShowingSettings = false
    @State private var isPulsing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let banner = viewModel.banner {
                        statusBannerView(banner)
                    }

                    voiceCaptureCard
                    quickTextAndAttachmentCard
                    recentCapturesCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SkipDrama")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                IOSSettingsView(pairingViewModel: pairingViewModel)
            }
            .fileImporter(
                isPresented: $isShowingDocumentPicker,
                allowedContentTypes: [.pdf, .image, .plainText, .audio, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.loadDocumentURL(url)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await viewModel.loadPhotoItem(newItem)
                    selectedPhotoItem = nil
                }
            }
            .onChange(of: viewModel.shouldFocusTextField) { _, shouldFocus in
                if shouldFocus {
                    isTextFieldFocused = true
                    viewModel.shouldFocusTextField = false
                }
            }
            .onChange(of: isRecording) { _, recording in
                if recording && !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPulsing = false
                    }
                }
            }
        }
    }

    // MARK: - Status Banner

    private func statusBannerView(_ banner: IOSCaptureViewModel.StatusBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)

            Text(banner.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                viewModel.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(banner.isError ? Color.orange.opacity(0.14) : Color.green.opacity(0.14))
        )
    }

    // MARK: - Primary Voice Capture Card

    private var voiceCaptureCard: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Voice Capture", systemImage: "mic.fill")
                    .font(.headline)
                Spacer()
                if case .recording(let duration, _) = viewModel.voiceState {
                    Text("\(formattedDuration(duration)) / 1:00")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.red)
                } else if case .sending = viewModel.voiceState {
                    Text("Sending…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to Record")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                viewModel.toggleVoiceCapture()
            } label: {
                ZStack {
                    if isRecording {
                        Circle()
                            .stroke(Color.red.opacity(isPulsing ? 0.15 : 0.45), lineWidth: 8)
                            .frame(width: 122, height: 122)
                            .scaleEffect(isPulsing ? 1.12 : 1.0)
                    }

                    Circle()
                        .fill(voiceCircleColor)
                        .frame(width: 106, height: 106)

                    Circle()
                        .stroke(voiceRingColor, lineWidth: 4)
                        .frame(width: 106, height: 106)

                    if case .sending = viewModel.voiceState {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(isRecording ? .red : Color.accentColor)
                    }
                }
                .frame(height: 132)
            }
            .buttonStyle(.plain)
            .disabled(isSendingVoice)
            .accessibilityLabel(isRecording ? "Stop voice capture" : "Start voice capture")

            audioLevelMeter
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var audioLevelMeter: some View {
        HStack(spacing: 4) {
            ForEach(Array(viewModel.audioLevels.enumerated()), id: \.offset) { _, level in
                let barHeight = isRecording ? max(6, CGFloat(level) * 34) : 6
                Capsule()
                    .fill(isRecording ? Color.red.opacity(0.85) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: barHeight)
                    .animation(.easeOut(duration: 0.08), value: barHeight)
            }
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }

    // MARK: - Quick Text & Attachment Card

    private var quickTextAndAttachmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Text & Attachment", systemImage: "square.and.pencil")
                .font(.headline)

            TextField("Capture a thought, task, or URL…", text: $viewModel.textDraft, axis: .vertical)
                .lineLimit(2...6)
                .focused($isTextFieldFocused)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            chipRow(title: "Context", chips: IOSCaptureViewModel.gtdContexts)
            chipRow(title: "Duration", chips: IOSCaptureViewModel.durationChips)

            if let attachment = viewModel.pendingAttachment {
                HStack(spacing: 10) {
                    Image(systemName: attachment.kind == .image ? "photo.fill" : "doc.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text(attachment.sizeDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.clearPendingAttachment()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attachment")
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images
                ) {
                    Label("Photo", systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)

                Button {
                    isShowingDocumentPicker = true
                } label: {
                    Label("File", systemImage: "paperclip")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    isTextFieldFocused = false
                    Task {
                        await viewModel.submitTextOrAttachment()
                    }
                } label: {
                    if viewModel.isSubmittingText {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 12)
                    } else {
                        Label("Capture", systemImage: "arrow.up.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitComposer)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chipRow(title: String, chips: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    let isSelected = viewModel.isChipSelected(chip)
                    Button {
                        viewModel.toggleChip(chip)
                    } label: {
                        Text(chip)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(chip)")
                }
            }
        }
    }

    // MARK: - Recent Captures Log

    private var recentCapturesCard: some View {
        let items = viewModel.historyStore.items
        let hasPending = items.contains { $0.status == .queued || $0.status == .failed }
        let hasSent = items.contains { $0.status == .sent }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recent Captures", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                Spacer()

                if hasPending {
                    Button("Retry All") {
                        Task { await viewModel.historyStore.retryAllPending() }
                    }
                    .font(.caption.weight(.semibold))
                }

                if hasSent {
                    Button("Clear Sent") {
                        viewModel.historyStore.clearSent()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if items.isEmpty {
                Text("Captures from iPhone, Share Sheet, Action Button, and Shortcuts appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        historyRow(item)
                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func historyRow(_ item: CaptureHistoryItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(item.createdAt, style: .relative)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text("• \(subtitle)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let errorMessage = item.errorMessage, item.status == .failed {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()

            statusBadge(for: item)
        }
        .contextMenu {
            if item.status == .failed || item.status == .queued {
                Button {
                    Task { await viewModel.historyStore.retry(itemID: item.id) }
                } label: {
                    Label("Retry Upload", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                viewModel.historyStore.remove(itemID: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for item: CaptureHistoryItem) -> some View {
        switch item.status {
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .sending:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Sending")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .queued:
            Text("Queued")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        case .failed:
            Button {
                Task { await viewModel.historyStore.retry(itemID: item.id) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.mini)
        }
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = viewModel.voiceState { return true }
        return false
    }

    private var isSendingVoice: Bool {
        if case .sending = viewModel.voiceState { return true }
        return false
    }

    private var voiceCircleColor: Color {
        switch viewModel.voiceState {
        case .idle:
            return Color.accentColor.opacity(0.14)
        case .recording:
            return Color.red.opacity(0.16)
        case .sending:
            return Color.secondary.opacity(0.14)
        }
    }

    private var voiceRingColor: Color {
        switch viewModel.voiceState {
        case .idle:
            return Color.accentColor.opacity(0.65)
        case .recording:
            return Color.red
        case .sending:
            return Color.secondary.opacity(0.45)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
