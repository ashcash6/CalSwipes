import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BerkeleyPlate

enum CaptureFixture {
    static func image(width: Int = 400, height: Int = 200) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return try XCTUnwrap(context.makeImage())
    }

    static func jpeg(orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString:Any] = [kCGImagePropertyOrientation:orientation,
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.87, kCGImagePropertyGPSLongitude:122.26]]
        CGImageDestinationAddImage(destination, try image(), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func photo() throws -> CapturedPhoto {
        try CapturedPhoto.prepare(jpeg(), capturedAt: Date())
    }

    static func menu() throws -> MenuEnvelope {
        let url = try XCTUnwrap(Bundle(for: CaptureTests.self).url(forResource: "menu", withExtension: "json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
        let date = ISO8601DateFormatter()
        object["date"] = BerkeleyClock.serviceDate()
        object["fetched_at"] = date.string(from: Date().addingTimeInterval(-1))
        object["expires_at"] = date.string(from: Date().addingTimeInterval(3600))
        return try JSONCoding.decoder().decode(MenuEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

final class CaptureTests: XCTestCase {
    func testOrientationDownsamplingAndMetadataRemoval() throws {
        let photo = try CapturedPhoto.prepare(CaptureFixture.jpeg(orientation: 6), capturedAt: Date(), maxDimension: 256)
        XCTAssertEqual(photo.image.width, 128)
        XCTAssertEqual(photo.image.height, 256)
        XCTAssertEqual(photo.sha256.count, 64)
        XCTAssertFalse(photo.hasMetricDepth)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.jpegData as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String:Any])
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary as String])
        let orientation = metadata[kCGImagePropertyOrientation as String] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1)
    }

    func testInvalidPhotoAndOversizedPreparationRejected() {
        XCTAssertThrowsError(try CapturedPhoto.prepare(Data("not an image".utf8), capturedAt: Date()))
        XCTAssertThrowsError(try CapturedPhoto.prepare(Data(), capturedAt: Date(), maxDimension: 8192))
    }
}
