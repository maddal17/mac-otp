import AppKit
import Foundation
import Vision

public enum QRScanError: LocalizedError {
    case noImageInClipboard
    case screenCaptureCancelled
    case unreadableImage
    case noQRCodeFound

    public var errorDescription: String? {
        switch self {
        case .noImageInClipboard:
            return "В буфере обмена нет изображения с QR-кодом."
        case .screenCaptureCancelled:
            return "Выделение области экрана отменено."
        case .unreadableImage:
            return "Не удалось прочитать изображение."
        case .noQRCodeFound:
            return "На изображении не найден QR-код."
        }
    }
}

public enum QRScannerService {
    /// Extracts QR payload strings from a `CGImage` using Apple Vision.
    public static func detectQRStrings(in cgImage: CGImage) throws -> [String] {
        var extracted: [String] = []
        let request = VNDetectBarcodesRequest { req, _ in
            guard let observations = req.results as? [VNBarcodeObservation] else { return }
            for obs in observations where obs.symbology == .qr {
                if let payload = obs.payloadStringValue, !payload.isEmpty {
                    extracted.append(payload)
                }
            }
        }
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard !extracted.isEmpty else {
            throw QRScanError.noQRCodeFound
        }
        return extracted
    }

    public static func scanFromImageURL(_ url: URL) throws -> [String] {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw QRScanError.unreadableImage
        }
        return try detectQRStrings(in: cgImage)
    }

    @MainActor
    public static func scanFromClipboard() throws -> [String] {
        let pb = NSPasteboard.general
        guard let nsImage = NSImage(pasteboard: pb),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw QRScanError.noImageInClipboard
        }
        return try detectQRStrings(in: cgImage)
    }

    /// Launches interactive macOS region screenshot (`screencapture -i`) into a temporary file,
    /// scans QR codes via Vision, and immediately deletes the temporary screenshot.
    public static func scanInteractiveScreenSelection() async throws -> [String] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macotp-qr-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-i", "-x", tempURL.path]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }

        guard exitCode == 0, FileManager.default.fileExists(atPath: tempURL.path) else {
            throw QRScanError.screenCaptureCancelled
        }

        return try scanFromImageURL(tempURL)
    }
}
