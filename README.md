# Quick Capture (Standalone watchOS)

Standalone watchOS 10.0+ SwiftUI voice memo capture app optimized for Apple Watch Series 6 (40mm/44mm) and Series 7 (41mm/45mm).

## Features

- **Adaptive Watch-First UI**: Uses `GeometryReader` and `containerRelativeFrame` with zero hardcoded pixel dimensions so the circular capture target scales cleanly across 40mm, 41mm, 44mm, and 45mm displays.
- **Low-Memory Disk Streaming**: Encodes AAC-LC mono 44.1 kHz @ 64 kbps `.m4a` audio to `FileManager.default.temporaryDirectory` and streams uploads directly from disk via `URLSession.shared.upload(for:fromFile:)`.
- **Haptic & Visual State Machine**: `@Observable` state machine (`RecordingViewModel`) with `.idle`, `.recording(duration:)`, `.uploading`, `.success`, and `.error(String)` states, 60-second auto-stop timer, native `WKInterfaceDevice` haptics, and 2-second auto-reset.
- **Watch Face Complication**: WidgetKit extension (`CaptureWidget`) supporting `.accessoryCircular` and `.accessoryCorner` slots, deep-linking into recording mode via `quickcapture://record`.

## Configuration

Update `QuickCaptureWatchApp/Config.swift` before running against your backend:

- `defaultAPIBaseURL`: Your Cloud Run / HTTPS service base URL (`https://<your-service>.run.app`)
- `defaultAPIToken`: Bearer token prefixed with `iwf_cap_`

You can also override both values at runtime via `UserDefaults.standard` (`Config.setAPIBaseURL(_:)`, `Config.setAPIToken(_:)`) or Xcode scheme environment variables (`QUICK_CAPTURE_API_BASE_URL`, `QUICK_CAPTURE_API_TOKEN`).

## Building

Open `QuickCapture.xcodeproj` in Xcode, select your Development Team for signing, and run the `QuickCapture` scheme on an Apple Watch Series 6 / Series 7 simulator or physical watch.

