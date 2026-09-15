import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CapturedPhoto: Identifiable {
    let id: UUID
    let image: CGImage
    let jpegData: Data
    let sha256: String
    let capturedAt: Date
    // Phase 3 captures RGB only. Camera count is never treated as metric depth.
    var hasMetricDepth: Bool { false }

    static func prepare(_ data: Data, capturedAt: Date, maxDimension: Int = 1600) throws -> CapturedPhoto {
        guard data.count <= 40 * 1024 * 1024, (256...2048).contains(maxDimension),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CameraFailure.invalidPhoto
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CameraFailure.invalidPhoto
        }
        // Re-encode upright pixels without carrying source EXIF/GPS metadata forward.
        let clean = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(clean, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraFailure.invalidPhoto
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.invalidPhoto }
        let jpeg = clean as Data
        return CapturedPhoto(id: UUID(), image: image, jpegData: jpeg,
            sha256: SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined(), capturedAt: capturedAt)
    }
}

enum CameraFailure: LocalizedError {
    case unavailable, configuration, invalidPhoto, capture
    var errorDescription: String? {
        switch self {
        case .unavailable: return "A rear camera is not available. Use a physical iPhone to capture a meal."
        case .configuration: return "The camera could not be configured. Close other camera apps and try again."
        case .invalidPhoto: return "This photo could not be prepared. Please retake it."
        case .capture: return "The photo could not be captured. Please try again."
        }
    }
}
