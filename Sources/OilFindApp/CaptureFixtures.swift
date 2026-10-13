#if DEBUG
import AppKit

// Debug snapshots use generated content only, with no screen, key or archive reads.
enum CaptureFixtures {
    static func document() throws -> CaptureDocument {
        guard let context = CGContext(data: nil, width: 1000, height: 560, bitsPerComponent: 8, bytesPerRow: 4000,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.capacity }
        context.setFillColor(NSColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 560))
        context.translateBy(x: 0, y: 560); context.scaleBy(x: 1, y: -1)
        CaptureRenderer.draw(CaptureAnnotation(tool: .text, rect: CGRect(x: 50, y: 35, width: 900, height: 70), color: CaptureColor(red: 0.1, green: 0.15, blue: 0.25), fontSize: 36, text: "Oil Find · " + L10n.text("capture.document.title")), resources: [:], original: nil, originalSize: CGSize(width: 1000, height: 560), in: context)
        CaptureRenderer.draw(CaptureAnnotation(tool: .text, rect: CGRect(x: 50, y: 135, width: 850, height: 240), color: CaptureColor(red: 0.25, green: 0.3, blue: 0.4), fontSize: 24, text: L10n.chinese ? "合成演示图片\n箭头、标注、裁剪与本地识字\nPNG / JPEG · 加密可编辑历史\n🙂  1  2  3" : "Synthetic demo image\nArrows, annotations, crop and local OCR\nPNG / JPEG · Encrypted editable history\n🙂  1  2  3"), resources: [:], original: nil, originalSize: CGSize(width: 1000, height: 560), in: context)
        guard let image = context.makeImage() else { throw CaptureFailure.invalidImage }
        var document = CaptureDocument(original: try CaptureRaster(image: image))
        document.annotations = [CaptureAnnotation(tool: .rectangle, rect: CGRect(x: 36, y: 116, width: 460, height: 65), lineWidth: 4),
            CaptureAnnotation(tool: .arrow, rect: CGRect(x: 520, y: 220, width: 220, height: 100), points: [CGPoint(x: 750, y: 330), CGPoint(x: 520, y: 220)], lineWidth: 5),
            CaptureAnnotation(tool: .step, rect: CGRect(x: 840, y: 420, width: 55, height: 55), text: "1")]
        return document
    }
}
#endif
