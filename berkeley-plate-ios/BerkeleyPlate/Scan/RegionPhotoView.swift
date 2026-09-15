import SwiftUI
import CoreGraphics

struct RegionPhotoView: View {
    let photo: CapturedPhoto
    let foods: [FoodRegion]
    let plate: FoodRegion?
    let candidate: FoodRegion?
    let points: [SAMPoint]
    let tap: (CGPoint) -> Void

    var body: some View {
        Image(decorative: photo.image, scale: 1)
            .resizable().scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if let plate { mask(plate, color: .blue, size: geometry.size) }
                        ForEach(foods) { region in mask(region, color: .green, size: geometry.size) }
                        if let candidate { mask(candidate, color: .orange, size: geometry.size) }
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            Image(systemName: point.positive ? "plus.circle.fill" : "minus.circle.fill")
                                .foregroundStyle(point.positive ? .green : .red)
                                .background(.white, in: Circle())
                                .position(x: point.location.x * geometry.size.width, y: point.location.y * geometry.size.height)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                        tap(CGPoint(x: location.x / geometry.size.width, y: location.y / geometry.size.height))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("Meal photo. Tap inside the plate or a food to outline it.")
    }

    @ViewBuilder
    private func mask(_ region: FoodRegion, color: Color, size: CGSize) -> some View {
        if let image = Self.image(region) {
            color.opacity(0.4)
                .mask(Image(decorative: image, scale: 1).resizable().interpolation(.none))
                .frame(width: region.bounds.width * size.width, height: region.bounds.height * size.height)
                .offset(x: region.bounds.minX * size.width, y: region.bounds.minY * size.height)
                .allowsHitTesting(false)
        }
    }

    private static func image(_ region: FoodRegion) -> CGImage? {
        // White premultiplied RGBA foreground, transparent background, tightly cropped.
        let bytes = region.mask.flatMap { value -> [UInt8] in
            let alpha: UInt8 = value > 0.5 ? 255 : 0
            return [alpha, alpha, alpha, alpha]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: region.maskWidth, height: region.maskHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: region.maskWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
