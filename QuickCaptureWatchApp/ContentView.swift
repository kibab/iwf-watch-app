import SwiftUI

/// Primary watch-first capture interface dynamically scaled for Series 6 (40/44mm) and Series 7 (41/45mm).
struct ContentView: View {
    let viewModel: RecordingViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        GeometryReader { geometry in
            let shortestSide = min(geometry.size.width, geometry.size.height)
            let buttonDiameter = shortestSide * 0.66
            let ringWidth = max(3, buttonDiameter * 0.06)
            let iconSize = buttonDiameter * 0.36
            let verticalSpacing = geometry.size.height * 0.06

            VStack(spacing: verticalSpacing) {
                Spacer(minLength: 0)

                actionButton(
                    ringWidth: ringWidth,
                    iconSize: iconSize
                )

                statusFooter(shortestSide: shortestSide)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, geometry.size.width * 0.05)
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

    // MARK: - Subviews

    private func actionButton(
        ringWidth: CGFloat,
        iconSize: CGFloat
    ) -> some View {
        Button(action: viewModel.toggleRecording) {
            ZStack {
                if case .recording = viewModel.state {
                    Circle()
                        .stroke(Color.red.opacity(isPulsing ? 0.2 : 0.55), lineWidth: ringWidth * 0.9)
                        .scaleEffect(isPulsing ? 1.16 : 1.0)
                }

                Circle()
                    .fill(circleFillColor)

                Circle()
                    .stroke(baseRingColor, lineWidth: ringWidth)

                if case .recording(let duration) = viewModel.state {
                    let progress = min(max(duration / Config.maxRecordingDuration, 0), 1)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.red,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: progress)
                }

                centerGlyph(iconSize: iconSize)
            }
            .aspectRatio(1, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { width, _ in
                width * 0.66
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isUploading)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private func centerGlyph(iconSize: CGFloat) -> some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.red)
        case .uploading:
            ProgressView()
                .controlSize(.large)
                .tint(.primary)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: iconSize * 0.9, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private func statusFooter(shortestSide: CGFloat) -> some View {
        let labelFont = Font.system(size: max(12, shortestSide * 0.095), weight: .semibold, design: .rounded)

        return Group {
            switch viewModel.state {
            case .idle:
                Text("Tap to Record")
                    .font(labelFont)
                    .foregroundStyle(.secondary)
            case .recording(let duration):
                Text(formattedDuration(duration))
                    .font(labelFont.monospacedDigit())
                    .foregroundStyle(.red)
            case .uploading:
                Text("Sending...")
                    .font(labelFont)
                    .foregroundStyle(.secondary)
            case .success:
                Text("Captured")
                    .font(labelFont)
                    .foregroundStyle(.green)
            case .error(let message):
                Text(message)
                    .font(labelFont)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived State

    private var isRecording: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    private var isUploading: Bool {
        if case .uploading = viewModel.state { return true }
        return false
    }

    private var circleFillColor: Color {
        switch viewModel.state {
        case .idle:
            return Color.accentColor.opacity(0.16)
        case .recording:
            return Color.red.opacity(0.18)
        case .uploading:
            return Color.secondary.opacity(0.16)
        case .success:
            return Color.green.opacity(0.18)
        case .error:
            return Color.orange.opacity(0.18)
        }
    }

    private var baseRingColor: Color {
        switch viewModel.state {
        case .idle:
            return Color.accentColor.opacity(0.75)
        case .recording:
            return Color.red.opacity(0.28)
        case .uploading:
            return Color.secondary.opacity(0.55)
        case .success:
            return Color.green
        case .error:
            return Color.orange
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle:
            return "Record voice memo"
        case .recording:
            return "Stop recording"
        case .uploading:
            return "Uploading voice memo"
        case .success:
            return "Voice memo captured"
        case .error(let message):
            return "Capture error: \(message)"
        }
    }

    private var accessibilityValue: String {
        switch viewModel.state {
        case .recording(let duration):
            return formattedDuration(duration)
        default:
            return ""
        }
    }

    private var accessibilityHint: String {
        switch viewModel.state {
        case .idle:
            return "Double tap to start recording."
        case .recording:
            return "Double tap to stop and upload."
        case .error:
            return "Double tap to dismiss."
        case .uploading, .success:
            return ""
        }
    }
}

#Preview("Idle") {
    ContentView(viewModel: RecordingViewModel())
}
