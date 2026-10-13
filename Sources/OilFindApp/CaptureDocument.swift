import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureFailure: Error, LocalizedError {
    case permission, invalidImage, capacity, cancelled, mismatch, storage, protectedArchive
    var errorDescription: String? { L10n.text("capture.error." + String(describing: self)) }
}

struct CaptureRaster: Codable, Equatable {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumPixels = 64_000_000
    static let maximumDimension = 32_768
    let data: Data
    let width: Int
    let height: Int

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              Self.accepts(width: w, height: h),
              Self.decode(source, size: 64) != nil else { throw CaptureFailure.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        self.data = data; width = orientation >= 5 ? h : w; height = orientation >= 5 ? w : h
    }
    init(image: CGImage) throws { try self.init(data: CaptureRenderer.encode(image, type: .png)) }
    private enum CodingKeys: String, CodingKey { case data, width, height }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(data: values.decode(Data.self, forKey: .data))
        guard width == (try values.decode(Int.self, forKey: .width)), height == (try values.decode(Int.self, forKey: .height)) else { throw CaptureFailure.invalidImage }
    }
    static func accepts(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumDimension && height <= maximumDimension && width <= maximumPixels / height
    }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    func image(maximumDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = Self.decode(source, size: maximumDimension ?? max(width, height)) else { throw CaptureFailure.invalidImage }
        return image
    }
    private static func decode(_ source: CGImageSource, size: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct CaptureColor: Codable, Equatable {
    var red: Double = 0.95, green: Double = 0.25, blue: Double = 0.18, alpha: Double = 1
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var valid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    init(red: Double = 0.95, green: Double = 0.25, blue: Double = 0.18, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let value = color.usingColorSpace(.sRGB) ?? .systemRed
        red = value.redComponent; green = value.greenComponent; blue = value.blueComponent; alpha = value.alphaComponent
    }
}

enum CaptureTool: String, CaseIterable, Codable {
    case select, arrow, line, rectangle, ellipse, step, text, pen, highlight, mosaic, redact, crop, emoji, sticker
    var title: String { L10n.text("capture.tool." + rawValue) }
}

struct CaptureAnnotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var tool: CaptureTool
    var rect: CGRect
    var points: [CGPoint] = []
    var color = CaptureColor()
    var lineWidth: Double = 3
    var fontSize: Double = 24
    var text = ""
    var resourceID: UUID?
    var valid: Bool {
        rect.finite && points.count <= 100_000 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            && color.valid && lineWidth.isFinite && (1...128).contains(lineWidth)
            && fontSize.isFinite && (6...512).contains(fontSize) && text.utf8.count <= 65_536
            && tool != .select && tool != .crop
    }
}

extension CGRect {
    var finite: Bool { [minX, minY, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
    static func between(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    }
}

struct CaptureDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = L10n.text("capture.document.title")
    var createdAt = Date()
    var updatedAt = Date()
    var sourceBundleID: String?
    var sourceName: String?
    var original: CaptureRaster
    var crop: CGRect
    var annotations: [CaptureAnnotation] = []
    var resources: [UUID: CaptureRaster] = [:]
    init(original: CaptureRaster, sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.original = original; crop = original.bounds
        self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
    }
    var storageBytes: Int { original.data.count + resources.values.reduce(0) { $0 + $1.data.count } + annotations.reduce(0) { $0 + $1.text.utf8.count + $1.points.count * 16 + 256 } }
    var valid: Bool {
        crop.finite && crop.width >= 1 && crop.height >= 1 && original.bounds.contains(crop)
            && annotations.count <= 10_000 && resources.count <= 256 && storageBytes <= CaptureRaster.maximumBytes
            && annotations.allSatisfy { $0.valid && ($0.resourceID == nil || resources[$0.resourceID!] != nil) }
            && title.utf8.count <= 4096
    }
}

struct CaptureMaterial: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var annotations: [CaptureAnnotation]
    var resources: [UUID: CaptureRaster]
    var storageBytes: Int { resources.values.reduce(0, { $0 + $1.data.count }) + annotations.reduce(0, { $0 + $1.text.utf8.count + $1.points.count * 16 + 256 }) }
    var valid: Bool {
        !annotations.isEmpty && annotations.count <= 1000 && resources.count <= 256 && title.utf8.count <= 4096
            && annotations.allSatisfy { $0.valid && ($0.resourceID == nil || resources[$0.resourceID!] != nil) }
            && storageBytes <= CaptureRaster.maximumBytes
    }
}

enum CaptureRenderer {
    static func reduced(_ image: CGImage) throws -> CGImage {
        let width = max(1, image.width / 2), height = max(1, image.height / 2)
        guard CaptureRaster.accepts(width: width, height: height), let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.capacity }
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = context.makeImage() else { throw CaptureFailure.invalidImage }; return reduced
    }
    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.9) throws -> Data {
        guard CaptureRaster.accepts(width: image.width, height: image.height) else { throw CaptureFailure.capacity }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw CaptureFailure.invalidImage }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(output), data.length <= CaptureRaster.maximumBytes else { throw CaptureFailure.capacity }
        return data as Data
    }
    static func image(_ document: CaptureDocument, maximumDimension: Int? = nil) throws -> CGImage {
        guard document.valid else { throw CaptureFailure.invalidImage }
        let scale = min(1, maximumDimension.map { Double($0) / max(document.crop.width, document.crop.height) } ?? 1)
        let w = max(1, Int((document.crop.width * scale).rounded())), h = max(1, Int((document.crop.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.capacity }
        let base = try document.original.image(maximumDimension: maximumDimension.map { max($0, Int(Double(max(document.original.width, document.original.height)) * scale)) })
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -document.crop.minX, y: -document.crop.minY)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(document.original.height)); context.scaleBy(x: 1, y: -1)
        context.draw(base, in: document.original.bounds)
        context.restoreGState()
        for annotation in document.annotations { draw(annotation, resources: document.resources, original: base, originalSize: document.original.bounds.size, in: context) }
        guard let result = context.makeImage() else { throw CaptureFailure.invalidImage }
        return result
    }
    static func draw(_ item: CaptureAnnotation, resources: [UUID: CaptureRaster], resourceImages: [UUID: CGImage]? = nil, original: CGImage?, originalSize: CGSize, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(item.color.nsColor.cgColor); context.setFillColor(item.color.nsColor.cgColor)
        context.setLineWidth(item.lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        let rect = item.rect
        switch item.tool {
        case .arrow, .line, .pen:
            let points = item.points.isEmpty ? [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)] : item.points
            guard let first = points.first else { return }
            context.move(to: first); points.dropFirst().forEach { context.addLine(to: $0) }; context.strokePath()
            if item.tool == .arrow, let end = points.last, points.count >= 2 {
                let before = points[points.count - 2], angle = atan2(end.y - before.y, end.x - before.x), length = max(12, item.lineWidth * 4)
                for delta in [-Double.pi / 6, Double.pi / 6] {
                    context.move(to: end); context.addLine(to: CGPoint(x: end.x - cos(angle + delta) * length, y: end.y - sin(angle + delta) * length)); context.strokePath()
                }
            }
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .highlight: context.setAlpha(0.28); context.fill(rect)
        case .redact: context.setFillColor(NSColor.black.cgColor); context.fill(rect)
        case .mosaic:
            guard let original else { return }
            let sx = CGFloat(original.width) / originalSize.width, sy = CGFloat(original.height) / originalSize.height
            let visibleRect = rect.intersection(CGRect(origin: .zero, size: originalSize))
            guard !visibleRect.isNull, !visibleRect.isEmpty else { return }
            let pieceRect = CGRect(x: visibleRect.minX * sx, y: visibleRect.minY * sy, width: visibleRect.width * sx, height: visibleRect.height * sy).intersection(CGRect(x: 0, y: 0, width: original.width, height: original.height))
            guard !pieceRect.isEmpty, let piece = original.cropping(to: pieceRect),
                  let tiny = CGContext(data: nil, width: max(1, Int(visibleRect.width / 12)), height: max(1, Int(visibleRect.height / 12)), bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            tiny.interpolationQuality = .low; tiny.draw(piece, in: CGRect(x: 0, y: 0, width: tiny.width, height: tiny.height))
            if let image = tiny.makeImage() { context.interpolationQuality = .none; drawUpright(image, rect: visibleRect, in: context) }
        case .step:
            context.fillEllipse(in: rect)
            drawText(item.text, rect: rect, size: item.fontSize, color: .white, centered: true, in: context)
        case .text, .emoji: drawText(item.text, rect: rect, size: item.fontSize, color: item.color.nsColor, in: context)
        case .sticker:
            if let id = item.resourceID {
                let image: CGImage?
                if let resourceImages { image = resourceImages[id] } else { image = try? resources[id]?.image() }
                if let image { drawUpright(image, rect: rect, in: context) }
            }
        case .select, .crop: break
        }
    }
    private static func drawUpright(_ image: CGImage, rect: CGRect, in context: CGContext) {
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    private static func drawText(_ text: String, rect: CGRect, size: Double, color: NSColor, centered: Bool = false, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
        let font = NSFont.systemFont(ofSize: size, weight: centered ? .semibold : .regular)
        let target = centered ? rect.offsetBy(dx: 0, dy: max(0, (rect.height - font.boundingRectForFont.height) / 2)) : rect
        (text as NSString).draw(in: target, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
