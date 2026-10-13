import AppKit
import CryptoKit
import XCTest
import Carbon
@testable import OilFindApp
@testable import OilFindCore

final class CaptureTests: XCTestCase {
    final class Keys: ClipboardKeyProviding {
        var available = true, creates: [Bool] = []
        let value = SymmetricKey(data: Data(repeating: 17, count: 32))
        func key(createIfMissing: Bool) throws -> SymmetricKey { creates.append(createIfMissing); guard available else { throw ClipboardFailure.keyUnavailable }; return value }
    }
    final class Backend: CaptureBackend {
        var hasPermission = true, permissionRequests = 0, stopped = 0
        var completion: ((Result<CaptureCatalog, Error>) -> Void)?
        func requestPermission() -> Bool { permissionRequests += 1; return hasPermission }
        func catalog(completion: @escaping (Result<CaptureCatalog, Error>) -> Void) { self.completion = completion }
        func capture(_ selection: CaptureSelection, completion: @escaping (Result<CGImage, Error>) -> Void) { XCTFail("Unexpected capture after cancellation") }
        func startStream(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) { XCTFail("Unexpected stream") }
        func stopStream() { stopped += 1 }
    }
    private func raster(_ width: Int = 64, _ height: Int = 64, offset: Int = 0) throws -> CaptureRaster { try CaptureRaster(image: pixels(width, height, offset: offset).image()) }
    private func pixels(_ width: Int, _ height: Int, offset: Int = 0) -> CapturePixels {
        var bytes: [UInt8] = []
        for y in 0..<height { for x in 0..<width {
            let hash = UInt64(y + offset + 1) &* 2654435761 ^ (UInt64(x + 1) &* 2246822519)
            bytes += [UInt8(truncatingIfNeeded: hash), UInt8(truncatingIfNeeded: hash >> 8), UInt8(truncatingIfNeeded: hash >> 16), 255]
        } }
        return CapturePixels(width: width, height: height, bytes: bytes)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindCaptureTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func archive(_ root: URL, keys: Keys, purpose: String = "history") -> CaptureArchive {
        CaptureArchive(directory: root, keys: keys, purpose: purpose, existingMasterArchive: { false })
    }

    func testRendererPreservesOrientationAndExactPixels() throws {
        let source = pixels(80, 60), document = CaptureDocument(original: try CaptureRaster(image: source.image()))
        let rendered = try CapturePixels(CaptureRenderer.image(document))
        XCTAssertEqual(rendered.width, source.width); XCTAssertEqual(rendered.height, source.height)
        XCTAssertEqual(rendered.bytes, source.bytes)
    }
    func testCropUsesOriginalPixelCoordinatesAfterAnnotationsAndExport() throws {
        var document = CaptureDocument(original: try raster(80, 60))
        document.crop = CGRect(x: 17, y: 11, width: 25, height: 20)
        let result = try CapturePixels(CaptureRenderer.image(document)), source = pixels(80, 60)
        XCTAssertEqual(result.width, 25); XCTAssertEqual(result.height, 20)
        for y in 0..<20 { for x in 0..<25 {
            XCTAssertEqual(Array(result.bytes[((y * 25 + x) * 4)..<((y * 25 + x) * 4 + 4)]), Array(source.bytes[(((y + 11) * 80 + x + 17) * 4)..<(((y + 11) * 80 + x + 17) * 4 + 4)]))
        } }
    }
    func testRedactionExportsOpaquePixelsAndPreservesEditableOriginal() throws {
        let original = try raster(80, 60)
        var document = CaptureDocument(original: original)
        document.annotations = [CaptureAnnotation(tool: .redact, rect: CGRect(x: 10, y: 10, width: 20, height: 20))]
        let flattened = try CapturePixels(CaptureRenderer.image(document))
        for y in 12..<28 { for x in 12..<28 { let i = (y * 80 + x) * 4; XCTAssertEqual(Array(flattened.bytes[i..<i+4]), [0,0,0,255]) } }
        XCTAssertEqual(document.original, original)
        let encoded = try CaptureRenderer.encode(flattened.image(), type: .png)
        XCTAssertFalse(encoded.contains(original.data))
        XCTAssertEqual(try CaptureRaster(data: encoded).width, 80)
        XCTAssertNoThrow(try CaptureRenderer.encode(flattened.image(), type: .jpeg))
    }
    func testEveryAnnotationToolRendersWithChineseEmojiAndSticker() throws {
        for tool in CaptureTool.allCases where tool != .select && tool != .crop {
            var document = CaptureDocument(original: try raster(180, 120))
            var item = CaptureAnnotation(tool: tool, rect: CGRect(x: 20, y: 20, width: 110, height: 70), points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 90)], text: tool == .emoji ? "🙂" : tool == .step ? "1" : "测试 Text")
            if tool == .sticker { let id = UUID(); document.resources[id] = try raster(20, 30); item.resourceID = id }
            document.annotations = [item]
            let changed = try CapturePixels(CaptureRenderer.image(document))
            XCTAssertNotEqual(changed.bytes, pixels(180, 120).bytes, tool.rawValue)
        }
    }
    func testUndoRedoCropAndMaterialDoesNotIncludeBaseImage() throws {
        let model = CaptureEditorModel(document: CaptureDocument(original: try raster()))
        let object = CaptureAnnotation(tool: .text, rect: CGRect(x: 4, y: 4, width: 30, height: 20), text: "合成")
        model.change { $0.annotations.append(object) }; model.selected = [object.id]
        let material = try XCTUnwrap(model.material(title: "Label"))
        XCTAssertEqual(material.annotations.count, 1); XCTAssertTrue(material.resources.isEmpty)
        model.change { $0.crop = CGRect(x: 2, y: 3, width: 40, height: 30) }
        model.undo(); XCTAssertEqual(model.document.crop, model.document.original.bounds)
        model.redo(); XCTAssertEqual(model.document.crop.origin, CGPoint(x: 2, y: 3))
        model.insert(material); XCTAssertEqual(model.document.annotations.count, 2)
        XCTAssertNotEqual(model.document.annotations[0].id, model.document.annotations[1].id)
        model.undo(); XCTAssertEqual(model.document.annotations.count, 1)
        model.selected = [object.id]; model.deleteSelection(); XCTAssertTrue(model.document.annotations.isEmpty)
        model.undo(); XCTAssertEqual(model.document.annotations.first?.text, "合成")
    }
    func testInvalidDocumentAndOversizeMetadataAreRejected() throws {
        XCTAssertFalse(CaptureRaster.accepts(width: 32769, height: 1)); XCTAssertFalse(CaptureRaster.accepts(width: 8001, height: 8000))
        var document = CaptureDocument(original: try raster())
        document.crop = CGRect(x: -1, y: 0, width: 20, height: 20); XCTAssertFalse(document.valid)
        document.crop = document.original.bounds
        document.annotations = [CaptureAnnotation(tool: .text, rect: .zero, fontSize: .infinity)]
        XCTAssertFalse(document.valid); XCTAssertThrowsError(try CaptureRenderer.image(document))
        XCTAssertThrowsError(try CaptureRaster(data: Data("not an image".utf8)))
    }
    func testSelectedAnnotationStyleEditsClampInputAndUndo() throws {
        let model = CaptureEditorModel(document: CaptureDocument(original: try raster()))
        let item = CaptureAnnotation(tool: .text, rect: CGRect(x: 3, y: 3, width: 50, height: 30), text: "Old")
        model.change { $0.annotations = [item] }; model.selected = [item.id]
        model.setWidth(999); model.setFont(.nan); model.setFont(999); model.setText("中文🙂")
        XCTAssertEqual(model.document.annotations[0].lineWidth, 128); XCTAssertEqual(model.document.annotations[0].fontSize, 512)
        XCTAssertEqual(model.document.annotations[0].text, "中文🙂")
        model.undo(); XCTAssertEqual(model.document.annotations[0].text, "Old")
        XCTAssertTrue(model.document.valid)
    }
    func testMultiDisplayCoordinatePlanUsesHighestScaleAndTransparentGaps() throws {
        let displays: [CaptureDisplay] = [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 60), scale: 1), .init(id: 2, frame: CGRect(x: 120, y: 0, width: 80, height: 60), scale: 2)]
        let region = CGRect(x: 60, y: 0, width: 100, height: 40), plan = try CaptureGeometry.plan(region: region, displays: displays)
        XCTAssertEqual(plan.scale, 2); XCTAssertEqual(plan.width, 200); XCTAssertEqual(plan.parts.count, 2)
        let images = try plan.parts.map { ($0.1, try pixels(Int($0.1.width * 2), Int($0.1.height * 2)).image()) }
        let result = try CapturePixels(CaptureGeometry.compose(region: region, scale: plan.scale, images: images))
        for y in 0..<result.height { for x in 80..<120 { XCTAssertEqual(result.bytes[(y * result.width + x) * 4 + 3], 0) } }
        let cocoa = CGRect(x: -500, y: -100, width: 400, height: 200)
        XCTAssertEqual(CaptureGeometry.cocoa(CaptureGeometry.quartz(cocoa, mainHeight: 900), mainHeight: 900), cocoa)
    }
    func testScrollNoMissingOrDuplicatedRows() throws {
        let stitcher = CaptureScrollStitcher()
        XCTAssertEqual(stitcher.appendStable(pixels(48, 90)), .appended(90))
        XCTAssertEqual(stitcher.appendStable(pixels(48, 90, offset: 37)), .appended(37))
        XCTAssertEqual(stitcher.appendStable(pixels(48, 90, offset: 65)), .appended(28))
        XCTAssertEqual(try CapturePixels(stitcher.image()).bytes, pixels(48, 155).bytes)
    }
    func testScrollRemovesOnlyRepeatedFixedHeaderAndFooter() throws {
        let width = 48, header = pixels(width, 7, offset: 900), footer = pixels(width, 9, offset: 1900)
        func frame(_ offset: Int) -> CapturePixels { CapturePixels(width: width, height: 86, bytes: header.bytes + pixels(width, 70, offset: offset).bytes + footer.bytes) }
        let stitcher = CaptureScrollStitcher()
        XCTAssertEqual(stitcher.appendStable(frame(0)), .appended(86))
        XCTAssertEqual(stitcher.appendStable(frame(31)), .appended(31))
        XCTAssertEqual(stitcher.appendStable(frame(60)), .appended(29))
        XCTAssertEqual(try CapturePixels(stitcher.image()).bytes, header.bytes + pixels(width, 130).bytes + footer.bytes)
    }
    func testScrollRejectsAmbiguityDynamicContentFastScrollAndSizeChange() throws {
        let stitcher = CaptureScrollStitcher(); _ = stitcher.appendStable(pixels(48, 80))
        let before = try CapturePixels(stitcher.image()).bytes
        XCTAssertEqual(stitcher.appendStable(pixels(48, 80, offset: 200)), .uncertain)
        XCTAssertEqual(stitcher.appendStable(pixels(47, 80, offset: 20)), .uncertain)
        var dynamic = pixels(48, 80, offset: 20).bytes
        for index in stride(from: 0, to: dynamic.count, by: 4) { dynamic[index] = 0 }
        XCTAssertEqual(stitcher.appendStable(.init(width: 48, height: 80, bytes: dynamic)), .uncertain)
        XCTAssertEqual(try CapturePixels(stitcher.image()).bytes, before)
        let repeating = CaptureScrollStitcher()
        let stripe: [UInt8] = [20,60,90,255], alternate: [UInt8] = [60,20,90,255]
        let repeated = CapturePixels(width: 48, height: 80, bytes: (0..<80).flatMap { row in (0..<48).flatMap { _ in row % 2 == 0 ? stripe : alternate } })
        _ = repeating.appendStable(repeated)
        let shifted = CapturePixels(width: 48, height: 80, bytes: Array(repeated.bytes.dropFirst(48*4)) + Array(repeated.bytes.prefix(48*4)))
        XCTAssertEqual(repeating.appendStable(shifted), .uncertain)
    }
    func testScrollRequiresStableFramesAndPreservesContentAtCapacity() throws {
        let stitcher = CaptureScrollStitcher(maximumPixels: 48 * 100)
        let frame = pixels(48, 80)
        XCTAssertEqual(try stitcher.consume(frame), .waiting); XCTAssertEqual(try stitcher.consume(frame), .appended(80))
        let moving = pixels(48, 80, offset: 30)
        XCTAssertEqual(try stitcher.consume(moving), .waiting); XCTAssertEqual(try stitcher.consume(moving), .capacity)
        XCTAssertEqual(try CapturePixels(stitcher.image()).bytes, frame.bytes)
    }
    func testEncryptedDocumentRestartPruningAndAtomicFailurePreservePreviousVersion() throws {
        let root = try temporary(), keys = Keys(), archive = archive(root, keys: keys), now = Date()
        var first = CaptureDocument(original: try raster()); first.title = "Private synthetic original"
        try archive.save(first, retention: .init(), now: now)
        let entry = try XCTUnwrap(archive.entries.first), oldIndex = try Data(contentsOf: root.appendingPathComponent("index.encrypted"))
        XCTAssertEqual(try archive.document(entry), first)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: url); XCTAssertFalse(data.contains(Data(first.title.utf8))); XCTAssertFalse(data.contains(first.original.data))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        archive.beforeIndexCommit = { throw CaptureFailure.storage }
        first.annotations.append(CaptureAnnotation(tool: .redact, rect: CGRect(x: 2, y: 3, width: 20, height: 20)))
        XCTAssertThrowsError(try archive.save(first, retention: .init(), now: now))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.encrypted")), oldIndex)
        XCTAssertTrue(try archive.document(entry).annotations.isEmpty)
        archive.beforeIndexCommit = nil; try archive.save(first, retention: .init(), now: now.addingTimeInterval(1))
        let restarted = self.archive(root, keys: keys); try restarted.load()
        XCTAssertEqual(try restarted.document(restarted.entries[0]), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 3)
        try restarted.prune(retention: .init(days: 1), now: now.addingTimeInterval(86402)); XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
    }
    func testHistoryCountCapacityDisableAndCorruptionDoNotReplaceArchives() throws {
        let root = try temporary(), keys = Keys(), archive = archive(root, keys: keys), now = Date()
        for i in 0..<4 { try archive.save(CaptureDocument(original: raster(30, 20, offset: i)), retention: .init(count: 2), now: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(archive.entries.count, 2)
        let previous = archive.entries
        XCTAssertThrowsError(try archive.save(CaptureDocument(original: raster()), retention: .init(bytes: 1), now: now))
        XCTAssertEqual(archive.entries, previous)
        let index = root.appendingPathComponent("index.encrypted"); try Data("damaged".utf8).write(to: index)
        let reopened = self.archive(root, keys: keys)
        XCTAssertThrowsError(try reopened.load()); XCTAssertThrowsError(try reopened.save(CaptureDocument(original: raster()), retention: .init(), now: now))
        XCTAssertEqual(try Data(contentsOf: index), Data("damaged".utf8))
        let history = CaptureHistory(archive: reopened, materialArchive: self.archive(try temporary(), keys: keys, purpose: "materials")); history.enabled = false
        var called = false; history.save(CaptureDocument(original: try raster())) { success in called = true; XCTAssertTrue(success) }; XCTAssertTrue(called); XCTAssertEqual(history.pending, 0)
    }
    func testMissingMasterKeyNeverCreatesReplacementForExistingHistory() throws {
        let root = try temporary(), keys = Keys(), archive = archive(root, keys: keys)
        try archive.save(CaptureDocument(original: raster()), retention: .init(), now: Date())
        let before = try Data(contentsOf: root.appendingPathComponent("index.encrypted")); keys.available = false; keys.creates = []
        let reopened = self.archive(root, keys: keys)
        XCTAssertThrowsError(try reopened.load()); XCTAssertEqual(keys.creates, [false])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.encrypted")), before)
    }
    func testHistoryAndMaterialsUseDifferentDerivedKeys() throws {
        let root = try temporary(), keys = Keys(), archive = archive(root, keys: keys)
        let doc = CaptureDocument(original: try raster()); try archive.save(doc, retention: .init(), now: Date())
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: root.appendingPathComponent("index.encrypted")))
        let wrong = HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.value, salt: Data("OilFindCapture.v1".utf8), info: Data("materials".utf8), outputByteCount: 32)
        XCTAssertThrowsError(try AES.GCM.open(box, using: wrong, authenticating: Data("OilFindCapture.v1:history".utf8)))
        let materialRoot = try temporary(), materials = self.archive(materialRoot, keys: keys, purpose: "materials")
        let material = CaptureMaterial(title: "Chinese 文本", annotations: [CaptureAnnotation(tool: .text, rect: CGRect(x: 0, y: 0, width: 50, height: 20), text: "素材")], resources: [:])
        try materials.save(material, now: Date()); let reopened = self.archive(materialRoot, keys: keys, purpose: "materials"); try reopened.load()
        XCTAssertEqual(try reopened.material(reopened.entries[0]), material)
    }
    func testCaptureCancellationIgnoresOutdatedCatalogAndDoesNotReadPasteboard() {
        let backend = Backend(), coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend)
        var opened = 0; coordinator.onDocument = { _ in opened += 1 }
        coordinator.run(.region); coordinator.cancel()
        backend.completion?(.success(.init(displays: [], windows: [])))
        XCTAssertEqual(opened, 0); XCTAssertEqual(backend.permissionRequests, 0); XCTAssertGreaterThan(backend.stopped, 0)
    }
    func testDeniedPermissionIsRequestedOnceAndNeverStartsStream() {
        let backend = Backend(); backend.hasPermission = false
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend)
        var errors: [String] = []; coordinator.onErrorMessage = { errors.append($0) }
        coordinator.run(.region); coordinator.run(.region)
        XCTAssertEqual(backend.permissionRequests, 1); XCTAssertNil(backend.completion)
        XCTAssertEqual(errors.count, 2); XCTAssertFalse(coordinator.settings.granted)
    }
    func testCaptureCommandsHaveChineseEnglishPinyinAndDistinctIdentity() {
        for query in ["截图", "jietu", "jt", "screenshot"] { XCTAssertTrue(CaptureAction.search(query).contains(.region), query) }
        XCTAssertTrue(CaptureAction.search("长截图").contains(.scroll))
        XCTAssertTrue(CaptureAction.search("ocr").contains(.ocr))
        XCTAssertTrue(CaptureAction.search("").isEmpty)
        XCTAssertEqual(LauncherRow.action(.region).identity, "capture:region")
        XCTAssertNotEqual(LauncherRow.action(.region).identity, LauncherRow.action(.window).identity)
    }
    func testHotKeysDispatchOnlyMatchingEventIDAndCaptureConflictDetection() {
        let search = EventHotKeyID(signature: HotKey.signature, id: 1), capture = EventHotKeyID(signature: HotKey.signature, id: 2)
        XCTAssertTrue(HotKey.matches(search, identifier: .search)); XCTAssertFalse(HotKey.matches(search, identifier: .capture))
        XCTAssertTrue(HotKey.matches(capture, identifier: .capture)); XCTAssertFalse(HotKey.matches(capture, identifier: .search))
        XCTAssertFalse(HotKey.matches(EventHotKeyID(signature: 0, id: 2), identifier: .capture))
        let preferences: [String: Any] = ["AppleSymbolicHotKeys": ["30": ["enabled": true, "value": ["parameters": [52, 21, 1179648]]]]]
        XCTAssertTrue(SpotlightShortcut.isReserved(keyCode: CaptureSettingsModel.defaultKeyCode, modifiers: CaptureSettingsModel.defaultModifiers, preferences: preferences))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers, preferences: preferences))
    }
    func testCapturePreferencesPreserveCustomShortcutAndClampRetention() throws {
        let suite = "CaptureSettings-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "captureHotKeyCode"); defaults.set(768, forKey: "captureHotKeyModifiers")
        let model = CaptureSettingsModel(defaults: defaults)
        XCTAssertEqual(model.keyCode, 42); XCTAssertEqual(model.days, 7); XCTAssertEqual(model.count, 100)
        model.days = 0; model.count = 9000; XCTAssertEqual(model.days, 1); XCTAssertEqual(model.count, 1000)
        model.onRegister = { _, _ in true }; model.restoreDefault()
        XCTAssertEqual(model.keyCode, 21); XCTAssertNotNil(model.actualShortcut)
    }
    func testOCRRecognizesSyntheticLocalText() throws {
        var document = CaptureDocument(original: try raster(700, 220))
        document.annotations = [CaptureAnnotation(tool: .redact, rect: document.original.bounds), CaptureAnnotation(tool: .text, rect: CGRect(x: 20, y: 30, width: 660, height: 160), color: CaptureColor(red: 1, green: 1, blue: 1), fontSize: 48, text: "Oil Find 12345")]
        let recognized = try CaptureOCR.recognize(CaptureRenderer.image(document))
        XCTAssertTrue(recognized.contains("12345"), recognized)
    }
    func testGeometryRejectsExtremeFiniteSizesBeforeIntegerConversion() {
        let rect = CGRect(x: 0, y: 0, width: 1e100, height: 20)
        let display = CaptureDisplay(id: 1, frame: rect, scale: 2)
        XCTAssertThrowsError(try CaptureGeometry.plan(region: rect, displays: [display]))
        XCTAssertThrowsError(try CaptureGeometry.compose(region: rect, scale: 2, images: []))
        XCTAssertThrowsError(try CaptureGeometry.compose(region: CGRect(x: 0, y: 0, width: 40, height: 20), scale: .nan, images: []))
    }
    func testMosaicOutsideImageUsesOnlyVisiblePixelsAndBoundedBuffers() throws {
        var document = CaptureDocument(original: try raster(80, 60))
        document.annotations = [CaptureAnnotation(tool: .mosaic, rect: CGRect(x: -1e20, y: -1e20, width: 2e20, height: 2e20))]
        let rendered = try CapturePixels(CaptureRenderer.image(document))
        XCTAssertEqual(rendered.width, 80); XCTAssertEqual(rendered.height, 60)
        XCTAssertNotEqual(rendered.bytes, pixels(80, 60).bytes)
    }
    func testResolutionReductionKeepsAspectRatioAndProducesEditableRaster() throws {
        let image = try pixels(80, 60).image(), reduced = try CaptureRenderer.reduced(image)
        XCTAssertEqual(reduced.width, 40); XCTAssertEqual(reduced.height, 30)
        XCTAssertTrue(CaptureDocument(original: try CaptureRaster(image: reduced)).valid)
    }
    func testArchiveReadsMaximumCountWithLongValidEncryptedMetadata() throws {
        let root = try temporary(), keys = Keys()
        let entries = (0..<1000).map { index in CaptureArchiveEntry(id: UUID(), blob: UUID(), title: String(format: "%04d-", index) + String(repeating: "a", count: 4090), updatedAt: Date(), width: 1, height: 1, bytes: 4096) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let plain = try encoder.encode(entries); XCTAssertGreaterThan(plain.count, 2 * 1024 * 1024)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.value, salt: Data("OilFindCapture.v1".utf8), info: Data("history".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(plain, using: derived, authenticating: Data("OilFindCapture.v1:history".utf8)).combined!
        try sealed.write(to: root.appendingPathComponent("index.encrypted"))
        XCTAssertEqual(try archive(root, keys: keys).load().count, 1000)
    }
    func testArchiveKeepsNewestSaveAfterClockRollbackAndIncludesIndexInQuota() throws {
        let root = try temporary(), keys = Keys(), store = archive(root, keys: keys)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CaptureDocument(original: try raster()), second = CaptureDocument(original: try raster(offset: 1))
        try store.save(first, retention: .init(count: 1), now: earlier.addingTimeInterval(3600))
        try store.save(second, retention: .init(count: 1), now: earlier)
        XCTAssertEqual(store.entries.map(\.id), [second.id]); XCTAssertEqual(try store.document(store.entries[0]).id, second.id)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.filter { $0.pathExtension == "encrypted" }.count, 3)
        let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let quota = total - 1
        XCTAssertThrowsError(try store.save(second, retention: .init(count: 1, bytes: quota), now: earlier))
        XCTAssertEqual(store.entries.map(\.id), [second.id])
    }
    func testTextWindowsAllocateReadableContentAndReleaseOnClose() {
        let controller = CaptureTextController(text: "合成 OCR\nOil Find 12345"), window = controller.window!
        XCTAssertFalse(window.isRestorable)
        window.contentView!.layoutSubtreeIfNeeded()
        let scroll = (window.contentView as! NSStackView).arrangedSubviews[0]
        XCTAssertGreaterThan(scroll.frame.width, 300); XCTAssertGreaterThan(scroll.frame.height, 200)
        XCTAssertEqual(controller.textView.string, "合成 OCR\nOil Find 12345")
        var closed = false; controller.onClose = { closed = true }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(closed); window.close()
        let pin = CapturePinController(text: "Synthetic pin"), pinWindow = pin.window!
        XCTAssertFalse(pinWindow.isRestorable)
        pinWindow.contentView!.layoutSubtreeIfNeeded()
        let pinContent = (pinWindow.contentView as! NSStackView).arrangedSubviews[0]
        XCTAssertGreaterThan(pinContent.frame.width, 250); XCTAssertGreaterThan(pinContent.frame.height, 100)
        pinWindow.close()
    }
}
