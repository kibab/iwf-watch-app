import CoreGraphics
import QRCodeGenerator
import SwiftUI

/// Renders a high-contrast QR code using pure Swift (`QRCodeGenerator`) and `CoreGraphics` (watchOS-safe, no `CoreImage`).
struct QRCodeView: View {
    let urlString: String
    var quietZoneModules: Int = 4

    var body: some View {
        Group {
            if let qrImage = Self.makeCGImage(for: urlString, quietZoneModules: quietZoneModules) {
                Image(decorative: qrImage, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.largeTitle)
                    .foregroundStyle(.black)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
        )
        .accessibilityLabel("Pairing QR Code")
    }

    private static func makeCGImage(for text: String, quietZoneModules: Int) -> CGImage? {
        guard let qr = try? QRCode.encode(text: text, ecl: .medium) else {
            return nil
        }

        let border = max(4, quietZoneModules)
        let totalModules = qr.size + (border * 2)
        guard totalModules > 0 else { return nil }

        // 1 byte per pixel (8-bit grayscale): 0xFF = white, 0x00 = black.
        var pixels = [UInt8](repeating: 0xFF, count: totalModules * totalModules)
        for y in 0..<qr.size {
            for x in 0..<qr.size where qr.getModule(x: x, y: y) {
                let row = y + border
                let col = x + border
                pixels[row * totalModules + col] = 0x00
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            guard let context = CGContext(
                data: baseAddress,
                width: totalModules,
                height: totalModules,
                bitsPerComponent: 8,
                bytesPerRow: totalModules,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return nil
            }
            return context.makeImage()
        }
    }
}

#Preview {
    QRCodeView(urlString: "https://gtd.bakulin.de/settings/integrations?pair_watch=482915")
        .frame(width: 130, height: 130)
}

