import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

struct CaptureDisplay: Equatable {
    let id: CGDirectDisplayID, frame: CGRect, scale: Double
}
struct CaptureWindow: Equatable {
    let id: CGWindowID, frame: CGRect, title: String, owner: String
}
struct CaptureCatalog { var displays: [CaptureDisplay]; var windows: [CaptureWindow] }
enum CaptureSelection: Equatable { case region(CGRect), window(CGWindowID) }

enum CaptureGeometry {
    static func quartz(_ cocoa: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: mainHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }
    static func cocoa(_ quartz: CGRect, mainHeight: CGFloat) -> CGRect { self.quartz(quartz, mainHeight: mainHeight) }
    static func plan(region: CGRect, displays: [CaptureDisplay]) throws -> (scale: Double, width: Int, height: Int, parts: [(CaptureDisplay, CGRect)]) {
        guard region.finite, region.width >= 1, region.height >= 1 else { throw CaptureFailure.invalidImage }
        let parts = displays.compactMap { display -> (CaptureDisplay, CGRect)? in
            let rect = display.frame.intersection(region); return rect.isNull || rect.isEmpty ? nil : (display, rect)
        }
        guard let scale = parts.map({ $0.0.scale }).max(), scale.isFinite, scale >= 1 else { throw CaptureFailure.invalidImage }
        let pixelWidth = ceil(region.width * scale), pixelHeight = ceil(region.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth <= Double(CaptureRaster.maximumDimension), pixelHeight <= Double(CaptureRaster.maximumDimension) else { throw CaptureFailure.capacity }
        let width = Int(pixelWidth), height = Int(pixelHeight)
        guard CaptureRaster.accepts(width: width, height: height) else { throw CaptureFailure.capacity }
        return (scale, width, height, parts)
    }
    static func compose(region: CGRect, scale: Double, images: [(CGRect, CGImage)]) throws -> CGImage {
        guard region.finite, scale.isFinite, scale >= 1,
              region.width * scale <= Double(CaptureRaster.maximumDimension),
              region.height * scale <= Double(CaptureRaster.maximumDimension) else { throw CaptureFailure.capacity }
        let width = Int(ceil(region.width * scale)), height = Int(ceil(region.height * scale))
        guard CaptureRaster.accepts(width: width, height: height), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.capacity }
        // Quartz global coordinates use top-left origins; bitmap drawing uses bottom-left.
        for (rect, image) in images {
            let target = CGRect(x: (rect.minX - region.minX) * scale, y: (region.maxY - rect.maxY) * scale,
                                width: rect.width * scale, height: rect.height * scale)
            context.draw(image, in: target)
        }
        guard let image = context.makeImage() else { throw CaptureFailure.invalidImage }; return image
    }
}

protocol CaptureBackend: AnyObject {
    var hasPermission: Bool { get }
    func requestPermission() -> Bool
    func catalog(completion: @escaping (Result<CaptureCatalog, Error>) -> Void)
    func capture(_ selection: CaptureSelection, completion: @escaping (Result<CGImage, Error>) -> Void)
    func startStream(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void)
    func stopStream()
}

final class ScreenCaptureBackend: NSObject, CaptureBackend, SCStreamOutput, SCStreamDelegate {
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
    private var content: SCShareableContent?
    private var catalogGeneration = 0
    private var stream: SCStream?
    private var streamGeneration = 0
    private var frameHandler: ((CGImage) -> Void)?, failureHandler: ((Error) -> Void)?
    private let outputQueue = DispatchQueue(label: "com.oiloil.find.capture-frames", qos: .userInitiated)
    private lazy var imageContext = CIContext(options: [.cacheIntermediates: false])
    func catalog(completion: @escaping (Result<CaptureCatalog, Error>) -> Void) {
        catalogGeneration += 1; let token = catalogGeneration
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displayValues = content.displays.map { display -> CaptureDisplay in
                    let mode = CGDisplayCopyDisplayMode(display.displayID)
                    let scale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
                    return .init(id: display.displayID, frame: CGDisplayBounds(display.displayID), scale: scale)
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
                let windows = content.windows.filter { $0.owningApplication?.processID != ownPID && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20 }
                    .sorted { (order.firstIndex(of: $0.windowID) ?? Int.max) < (order.firstIndex(of: $1.windowID) ?? Int.max) }
                    .map { CaptureWindow(id: $0.windowID, frame: $0.frame, title: $0.title ?? "", owner: $0.owningApplication?.applicationName ?? "") }
                await MainActor.run {
                    guard self.catalogGeneration == token else { return }
                    self.content = content; completion(.success(.init(displays: displayValues, windows: windows)))
                }
            } catch { await MainActor.run { if self.catalogGeneration == token { completion(.failure(error)) } } }
        }
    }
    private func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }
    private func configuration(rect: CGRect, scale: Double) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect; configuration.width = max(1, Int(ceil(rect.width * scale))); configuration.height = max(1, Int(ceil(rect.height * scale)))
        configuration.showsCursor = false; configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best; configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        return configuration
    }
    func capture(_ selection: CaptureSelection, completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard hasPermission, let content else { completion(.failure(CaptureFailure.permission)); return }
        Task {
            do {
                let image: CGImage
                switch selection {
                case .window(let id):
                    guard let window = content.windows.first(where: { $0.windowID == id }), window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else { throw CaptureFailure.invalidImage }
                    let scale = (try CaptureGeometry.plan(region: window.frame, displays: content.displays.map { .init(id: $0.displayID, frame: CGDisplayBounds($0.displayID), scale: Double(CGDisplayCopyDisplayMode($0.displayID)?.pixelWidth ?? $0.width) / Double(max(1, $0.width))) })).scale
                    let config = configuration(rect: CGRect(origin: .zero, size: window.frame.size), scale: scale)
                    config.sourceRect = .zero
                    guard CaptureRaster.accepts(width: config.width, height: config.height) else { throw CaptureFailure.capacity }
                    image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                case .region(let region):
                    let displays = content.displays.map { display in CaptureDisplay(id: display.displayID, frame: CGDisplayBounds(display.displayID), scale: Double(CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? display.width) / Double(max(1, display.width))) }
                    let plan = try CaptureGeometry.plan(region: region, displays: displays)
                    var images: [(CGRect, CGImage)] = []
                    for (display, part) in plan.parts {
                        guard let actual = content.displays.first(where: { $0.displayID == display.id }) else { continue }
                        let local = part.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                        let image = try await SCScreenshotManager.captureImage(contentFilter: displayFilter(actual, content: content), configuration: configuration(rect: local, scale: plan.scale))
                        images.append((part, image))
                    }
                    image = try CaptureGeometry.compose(region: region, scale: plan.scale, images: images)
                }
                await MainActor.run { completion(.success(image)) }
            } catch { await MainActor.run { completion(.failure(error)) } }
        }
    }
    func startStream(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        stopStream()
        guard hasPermission, let content, let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(region) }) else { completion(.failure(CaptureFailure.mismatch)); return }
        let bounds = CGDisplayBounds(display.displayID), scale = Double(CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? display.width) / Double(max(1, display.width))
        let config = configuration(rect: region.offsetBy(dx: -bounds.minX, dy: -bounds.minY), scale: scale)
        guard CaptureRaster.accepts(width: config.width, height: config.height) else { completion(.failure(CaptureFailure.capacity)); return }
        let next = SCStream(filter: displayFilter(display, content: content), configuration: config, delegate: self)
        streamGeneration += 1; let token = streamGeneration
        stream = next; frameHandler = frame; failureHandler = failure
        do { try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue) }
        catch { stopStream(); completion(.failure(error)); return }
        next.startCapture { [weak self] error in DispatchQueue.main.async {
            guard let self, self.streamGeneration == token, self.stream === next else { return }
            completion(error.map(Result.failure) ?? .success(()))
        } }
    }
    func stopStream() {
        streamGeneration += 1
        let old = stream; stream = nil; frameHandler = nil; failureHandler = nil
        old?.stopCapture { _ in }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in guard let self, self.stream === stream else { return }; self.failureHandler?(error); self.stopStream() }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(buffer), let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let image = imageContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { [weak self] in guard let self, self.stream === stream else { return }; self.frameHandler?(image) }
    }
    deinit { stopStream() }
}
