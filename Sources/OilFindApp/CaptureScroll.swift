import AppKit

struct CapturePixels {
    let width: Int, height: Int
    let bytes: [UInt8]
    init(_ image: CGImage) throws {
        guard CaptureRaster.accepts(width: image.width, height: image.height), let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { throw CaptureFailure.capacity }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        width = image.width; height = image.height
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    init(width: Int, height: Int, bytes: [UInt8]) { self.width = width; self.height = height; self.bytes = bytes }
    func image() throws -> CGImage {
        guard bytes.count == width * height * 4, CaptureRaster.accepts(width: width, height: height),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptureFailure.capacity }
        return image
    }
    func rows(_ range: Range<Int>) -> [UInt8] { Array(bytes[(range.lowerBound * width * 4)..<(range.upperBound * width * 4)]) }
    func rowError(_ other: CapturePixels, y: Int, otherY: Int, stride: Int = 1) -> Double {
        var total = 0, samples = 0
        for x in Swift.stride(from: 0, to: width, by: stride) {
            let a = (y * width + x) * 4, b = (otherY * width + x) * 4
            for c in 0..<3 { total += abs(Int(bytes[a + c]) - Int(other.bytes[b + c])); samples += 1 }
        }
        return Double(total) / Double(max(1, samples))
    }
}

// Conservative matching deliberately rejects repeated/ambiguous content. Only
// stable frames enter the matcher; the last successful document is always retained.
final class CaptureScrollStitcher {
    enum Outcome: Equatable { case waiting, unchanged, appended(Int), uncertain, capacity }
    private var candidate: CapturePixels?, previous: CapturePixels?
    private var header = 0, footer = 0, bandsKnown = false
    private var strips: [[UInt8]] = []
    private(set) var width = 0, height = 0, appendedFrames = 0
    private let maximumPixels: Int, maximumDimension: Int
    init(maximumPixels: Int = CaptureRaster.maximumPixels, maximumDimension: Int = CaptureRaster.maximumDimension) {
        self.maximumPixels = maximumPixels; self.maximumDimension = maximumDimension
    }
    func consume(_ image: CGImage) throws -> Outcome { try consume(CapturePixels(image)) }
    func consume(_ frame: CapturePixels) throws -> Outcome {
        guard CaptureRaster.accepts(width: frame.width, height: frame.height), frame.bytes.count == frame.width * frame.height * 4 else { throw CaptureFailure.invalidImage }
        guard let candidate, candidate.width == frame.width, candidate.height == frame.height else {
            if previous != nil, (width != frame.width || previous?.height != frame.height) { return .uncertain }
            self.candidate = frame; return .waiting
        }
        let rowStride = max(1, frame.height / 48), columnStride = max(1, frame.width / 64)
        let stable = stride(from: 0, to: frame.height, by: rowStride).allSatisfy { candidate.rowError(frame, y: $0, otherY: $0, stride: columnStride) < 1.5 }
        self.candidate = frame
        guard stable else { return .waiting }
        return appendStable(frame)
    }
    func appendStable(_ frame: CapturePixels) -> Outcome {
        guard let old = previous else {
            guard frame.width <= maximumPixels / frame.height, frame.height <= maximumDimension else { return .capacity }
            width = frame.width; height = frame.height; previous = frame; strips = [frame.bytes]; return .appended(frame.height)
        }
        guard old.width == frame.width, old.height == frame.height else { return .uncertain }
        let columnStride = max(1, width / 96)
        func same(_ y: Int, _ otherY: Int) -> Bool { old.rowError(frame, y: y, otherY: otherY, stride: columnStride) < 1.5 }
        if (0..<frame.height).allSatisfy({ same($0, $0) }) { return .unchanged }
        var top = header, bottom = footer
        if !bandsKnown {
            top = 0; bottom = 0
            while top < frame.height / 4 && same(top, top) { top += 1 }
            while bottom < frame.height / 4 && same(frame.height - 1 - bottom, frame.height - 1 - bottom) { bottom += 1 }
        } else if !(0..<top).allSatisfy({ same($0, $0) }) || !(0..<bottom).allSatisfy({ same(frame.height - 1 - $0, frame.height - 1 - $0) }) { return .uncertain }
        let end = frame.height - bottom, body = end - top, minimumOverlap = max(12, body / 4)
        guard body > minimumOverlap else { return .uncertain }
        var matches: [Int] = []
        for offset in 1...(body - minimumOverlap) {
            let overlap = body - offset
            let sampleStep = max(1, overlap / 16)
            guard stride(from: 0, to: overlap, by: sampleStep).allSatisfy({ same(top + offset + $0, top + $0) }) else { continue }
            // Validate every row with denser sampling after the cheap candidate pass.
            guard (0..<overlap).allSatisfy({ old.rowError(frame, y: top + offset + $0, otherY: top + $0, stride: max(1, width / 256)) < 1.5 }) else { continue }
            matches.append(offset)
            if matches.count > 1 { return .uncertain }
        }
        guard let offset = matches.first else { return .uncertain }
        let nextHeight = height + offset
        guard nextHeight <= maximumDimension, width <= maximumPixels / nextHeight else { return .capacity }
        if !bandsKnown {
            strips = [old.rows(0..<end)]; header = top; footer = bottom; bandsKnown = true
        }
        strips.append(frame.rows((end - offset)..<end))
        height = nextHeight; previous = frame; appendedFrames += 1
        return .appended(offset)
    }
    func image() throws -> CGImage {
        guard let previous else { throw CaptureFailure.invalidImage }
        var bytes: [UInt8] = []; bytes.reserveCapacity(width * height * 4)
        for strip in strips { bytes.append(contentsOf: strip) }
        if bandsKnown && footer > 0 { bytes.append(contentsOf: previous.rows((previous.height - footer)..<previous.height)) }
        return try CapturePixels(width: width, height: height, bytes: bytes).image()
    }
}
