# SkipDrama (Standalone watchOS)

Standalone watchOS 10.0+ SwiftUI voice memo capture app optimized for Apple Watch Series 6 (40mm/44mm) and Series 7 (41mm/45mm).

## Features

- **Zero-Typing Pairing & Keychain Auth**: RFC 8628-style device-code and wrist-QR pairing (`PairingView`, `PairingService`, `QRCodeView`) storing the Bearer token in the watchOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- **Adaptive Watch-First UI**: Uses `GeometryReader` and `containerRelativeFrame` with zero hardcoded pixel dimensions so the circular capture target scales cleanly across 40mm, 41mm, 44mm, and 45mm displays.
- **Low-Memory Disk Streaming & Queue Preservation**: Encodes AAC-LC mono 44.1 kHz @ 64 kbps `.m4a` audio to `ApplicationSupport/PendingCaptures`, streams uploads from disk via `URLSession.shared.upload(for:fromFile:)`, and preserves queued recordings across `401` re-pairing or offline errors until `202 Accepted`.
- **Haptic & Visual State Machine**: `@Observable` state machine (`RecordingViewModel`) with `.idle`, `.recording(duration:)`, `.uploading`, `.success`, and `.error(String)` states, 60-second auto-stop timer, native `WKInterfaceDevice` haptics, and 2-second auto-reset.
- **Watch Face Complication**: WidgetKit extension (`CaptureWidget`) supporting `.accessoryCircular` and `.accessoryCorner` slots, deep-linking into recording mode via `skipdrama://record`.

## Configuration

The backend base URL defaults to `https://skipdrama.app` in `SkipDramaWatchApp/Config.swift` (`defaultAPIBaseURL`) and can also be overridden at runtime via Watch Settings (`Config.setAPIBaseURL(_:)`) or the `SKIPDRAMA_API_BASE_URL` environment variable.

## Building

Open `SkipDrama.xcodeproj` in Xcode, select your Development Team for signing, and run the `SkipDrama` scheme on an Apple Watch simulator or physical watch.
