import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Encoded pixels stay inside the encrypted archive, never in temporary image files.
struct ClipboardImage: Codable, Equatable {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumPixels = 64_000_000
    let data: Data
    let typeIdentifier: String
    let width: Int
    let height: Int
    let fingerprint: Data

    private enum CodingKeys: String, CodingKey { case data, typeIdentifier, width, height }

    init?(data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width <= Self.maximumPixels / height,
              // HEIC cannot decode to a one-pixel thumbnail on some systems.
              Self.thumbnail(source: source, maximumSize: 64) != nil else { return nil }
        self.data = data; typeIdentifier = type; self.width = width; self.height = height
        fingerprint = Data(SHA256.hash(data: data))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let data = try values.decode(Data.self, forKey: .data)
        guard let image = Self(data: data),
              image.typeIdentifier == (try values.decode(String.self, forKey: .typeIdentifier)),
              image.width == (try values.decode(Int.self, forKey: .width)),
              image.height == (try values.decode(Int.self, forKey: .height)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid clipboard image"))
        }
        self = image
    }

    var format: String { (UTType(typeIdentifier)?.preferredFilenameExtension ?? "image").uppercased() }
    var summary: String { "\(format) · \(width) × \(height)" }

    func thumbnail(maximumSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return Self.thumbnail(source: source, maximumSize: maximumSize)
    }

    private static func thumbnail(source: CGImageSource, maximumSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    // Called on the bounded image-copy worker. Preserve the original format too,
    // including animated GIF bytes; PNG provides a first-frame paste fallback.
    func compatiblePNG() throws -> Data? {
        if typeIdentifier == UTType.png.identifier { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let frame = Self.thumbnail(source: source, maximumSize: max(width, height)) else {
            throw ClipboardFailure.invalidImage
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw ClipboardFailure.invalidImage
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClipboardFailure.invalidImage }
        // An incompressible fallback may exceed the limit; the original is still valid.
        return bytes.length <= Self.maximumBytes ? bytes as Data : nil
    }

    #if DEBUG
    static func sample() -> ClipboardImage? {
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.12, green: 0.36, blue: 0.62, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1)); context.fill(CGRect(x: 80, y: 80, width: 210, height: 200))
        context.setFillColor(CGColor(red: 0.8, green: 0.92, blue: 0.95, alpha: 1)); context.fillEllipse(in: CGRect(x: 340, y: 110, width: 170, height: 170))
        guard let frame = context.makeImage() else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        return CGImageDestinationFinalize(destination) ? Self(data: bytes as Data) : nil
    }
    #endif
}
