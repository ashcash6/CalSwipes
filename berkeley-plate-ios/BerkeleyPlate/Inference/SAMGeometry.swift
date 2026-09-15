import CoreGraphics
import CoreML
import Foundation

struct SAMTransform {
    let width: Int
    let height: Int
    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ModelFailure.imageInput }
        let scale = 1024.0 / Double(max(width, height))
        self.width = Int(Double(width) * scale + 0.5)
        self.height = Int(Double(height) * scale + 0.5)
    }
    func modelPoint(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite, (0..<1).contains(point.x), (0..<1).contains(point.y) else {
            throw ModelFailure.imageInput
        }
        return CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))
    }
}

enum SAMImageInput {
    /// SAM resizes the longest side, normalizes RGB, THEN pads bottom/right with zero.
    /// Centered letterboxing or normalizing black padding would change the model input.
    static func make(_ image: CGImage) throws -> (MLMultiArray, SAMTransform) {
        let transform = try SAMTransform(width: image.width, height: image.height)
        let w = transform.width, h = transform.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ModelFailure.imageInput
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let tensor = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float32)
        let ptr = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        // Newly allocated MLMultiArray is not guaranteed to be zero-filled.
        ptr.update(repeating: 0, count: tensor.count)
        let mean: [Float] = [123.675, 116.28, 103.53]
        let std: [Float] = [58.395, 57.12, 57.375]
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                for c in 0..<3 {
                    ptr[c * 1024 * 1024 + y * 1024 + x] = (Float(rgba[(y * w + x) * 4 + c]) - mean[c]) / std[c]
                }
            }
        }
        return (tensor, transform)
    }
}

enum SAMMask {
    /// Decode logits at 256² using half-pixel bilinear interpolation to the 1024²
    /// canvas, crop padding, then retain a <=512px mask in photo coordinates.
    static func region(logits: [Float], transform: SAMTransform) throws -> FoodRegion {
        guard logits.count == 256 * 256, logits.allSatisfy(\.isFinite) else { throw PipelineFailure.invalidOutput }
        let w = max(1, transform.width / 2), h = max(1, transform.height / 2)
        var mask = [Float](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                // Crop in 1024-space before resizing to display-mask resolution.
                let sx = (Double(x) + 0.5) * Double(transform.width) / Double(w) / 4 - 0.5
                let sy = (Double(y) + 0.5) * Double(transform.height) / Double(h) / 4 - 0.5
                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                let dx = Float(sx - floor(sx)), dy = Float(sy - floor(sy))
                func sample(_ a: Int, _ b: Int) -> Float { logits[min(255, max(0, b)) * 256 + min(255, max(0, a))] }
                let top = sample(x0, y0) * (1-dx) + sample(x0+1, y0) * dx
                let bottom = sample(x0, y0+1) * (1-dx) + sample(x0+1, y0+1) * dx
                if top * (1-dy) + bottom * dy > 0 {
                    mask[y*w+x] = 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw PipelineFailure.unavailable("No outline was found. Try a tap farther inside the object.") }
        let cw = maxX-minX+1, ch = maxY-minY+1
        var cropped: [Float] = []
        cropped.reserveCapacity(cw*ch)
        for y in minY...maxY { cropped.append(contentsOf: mask[(y*w+minX)...(y*w+maxX)]) }
        let region = FoodRegion(id: UUID(), bounds: CGRect(x: Double(minX)/Double(w), y: Double(minY)/Double(h),
            width: Double(cw)/Double(w), height: Double(ch)/Double(h)), maskWidth: cw, maskHeight: ch, mask: cropped)
        try region.validate()
        return region
    }
}
