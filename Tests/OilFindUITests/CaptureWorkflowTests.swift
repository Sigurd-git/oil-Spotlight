import AppKit
import Carbon
import CryptoKit
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class CaptureWorkflowTests: XCTestCase {
    private final class Keys: ClipboardKeyProviding {
        let value = SymmetricKey(data: Data(repeating: 39, count: 32))
        func key(createIfMissing: Bool) throws -> SymmetricKey { value }
    }
    private final class Backend: CaptureBackend {
        var hasPermission = true, permissionRequests = 0
        var catalogReply: ((Result<CaptureCatalog, Error>) -> Void)?
        var captureReply: ((Result<CGImage, Error>) -> Void)?
        var selections: [CaptureSelection] = []
        func requestPermission() -> Bool { permissionRequests += 1; return hasPermission }
        func catalog(completion: @escaping (Result<CaptureCatalog, Error>) -> Void) { catalogReply = completion }
        func capture(_ selection: CaptureSelection, completion: @escaping (Result<CGImage, Error>) -> Void) {
            selections.append(selection); captureReply = completion
        }
        func startStream(region: CGRect, frame: @escaping (CGImage) -> Void, failure: @escaping (Error) -> Void, completion: @escaping (Result<Void, Error>) -> Void) { XCTFail("Unexpected stream") }
        func stopStream() {}
    }
    private func defaults() -> UserDefaults {
        let name = "test.oilfind.capture-workflow." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }; return defaults
    }
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("test.oilfind.capture-workflow." + UUID().uuidString))
        addTeardownBlock { board.releaseGlobally() }; return board
    }
    private func history() throws -> CaptureHistory {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindCaptureWorkflow-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CaptureHistory(archive: CaptureArchive(directory: root.appendingPathComponent("history"), keys: Keys(), existingMasterArchive: { false }),
                              materialArchive: CaptureArchive(directory: root.appendingPathComponent("materials"), keys: Keys(), purpose: "materials", existingMasterArchive: { false }))
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        return try XCTUnwrap(context.makeImage())
    }
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testReselectionDropsFirstRegionAndConfirmsFinalSelectionOnlyOnce() {
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: []), windowMode: false)
        let first = CaptureSelection.region(CGRect(x: -300, y: 10, width: 200, height: 150))
        let final = CaptureSelection.region(CGRect(x: 30, y: 50, width: 80, height: 90))
        var captured: [CaptureSelection] = []; overlay.onSelect = { captured.append($0) }
        overlay.select(first); XCTAssertTrue(captured.isEmpty); XCTAssertNotNil(overlay.selectedRect)
        overlay.reselect(); XCTAssertNil(overlay.pendingSelection); XCTAssertNil(overlay.selectedRect)
        overlay.select(final); overlay.confirmSelection(); overlay.confirmSelection()
        XCTAssertEqual(captured, [final])
    }
    func testPendingWindowBoundsRemainFrozenUntilReselection() {
        let rect = CGRect(x: -600, y: -100, width: 500, height: 400)
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: [.init(id: 7, frame: rect, title: "Synthetic", owner: "QA")]), windowMode: true)
        overlay.select(.window(7)); XCTAssertEqual(overlay.selectedRect, rect)
        overlay.reselect(); XCTAssertNil(overlay.selectedRect)
    }
    func testQuickSelectionSubmitsImmediatelyAndConfirmationCannotSubmitTwice() {
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: []), windowMode: false, requiresConfirmation: false)
        var captured: [CaptureSelection] = []; overlay.onSelect = { captured.append($0) }
        overlay.select(.window(19)); overlay.confirmSelection()
        XCTAssertEqual(captured, [.window(19)]); XCTAssertNil(overlay.pendingSelection)
    }
    func testNormalCaptureWaitsForConfirmationAndDoesNotChangeClipboardOrHistory() throws {
        let backend = Backend(), board = pasteboard(), history = try history()
        var overlay: CaptureOverlayController?, opened: CaptureDocument?
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board, presentSelection: { overlay = $0 }, focusRestorer: { _ in })
        coordinator.onDocument = { opened = $0 }
        board.setString("synthetic original", forType: .string); let revision = board.changeCount
        coordinator.run(.region); backend.catalogReply?(.success(.init(displays: [], windows: [])))
        overlay?.select(.region(CGRect(x: 0, y: 0, width: 30, height: 20)))
        XCTAssertTrue(backend.selections.isEmpty); overlay?.reselect()
        let final = CaptureSelection.region(CGRect(x: 12, y: 30, width: 48, height: 32))
        overlay?.select(final); overlay?.confirmSelection(); backend.captureReply?(.success(try image()))
        waitFor { opened != nil }
        XCTAssertEqual(backend.selections, [final]); XCTAssertEqual(board.changeCount, revision); XCTAssertTrue(history.entries.isEmpty)
    }
    func testQuickCaptureCopiesPNGWithoutEditorAndRestoresEditableHistory() throws {
        let backend = Backend(), board = pasteboard(), history = try history()
        var overlay: CaptureOverlayController?, focusRestoredAfterCopy = false
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board, presentSelection: { overlay = $0 }, focusRestorer: { _ in focusRestoredAfterCopy = board.data(forType: .png) != nil })
        coordinator.onDocument = { _ in XCTFail("Quick copy must not open an editor") }
        coordinator.run(.copyRegion); backend.catalogReply?(.success(.init(displays: [], windows: [])))
        overlay?.select(.region(CGRect(x: 0, y: 0, width: 48, height: 32))); backend.captureReply?(.success(try image()))
        waitFor { board.data(forType: .png) != nil && history.entries.count == 1 && history.pending == 0 }
        XCTAssertTrue(coordinator.editors.isEmpty); XCTAssertNotNil(board.data(forType: ClipboardSystemPasteboard.ownCopyType))
        XCTAssertTrue(focusRestoredAfterCopy)
        let raster = try CaptureRaster(data: XCTUnwrap(board.data(forType: .png)))
        XCTAssertEqual(raster.width, 48); XCTAssertEqual(raster.height, 32)
        let recovered = expectation(description: "Quick screenshot reopens")
        history.read(try XCTUnwrap(history.entries.first)) { result in
            switch result {
            case .success(let document): XCTAssertEqual(document.original.data, raster.data); XCTAssertTrue(document.annotations.isEmpty)
            case .failure(let error): XCTFail(String(describing: error))
            }; recovered.fulfill()
        }
        wait(for: [recovered], timeout: 3)
    }
    func testQuickCopyHonorsDisabledScreenshotHistory() throws {
        let backend = Backend(), board = pasteboard(), history = try history(), preferences = defaults()
        preferences.set(false, forKey: "captureHistoryEnabled")
        var overlay: CaptureOverlayController?
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: preferences, pasteboard: board, presentSelection: { overlay = $0 }, focusRestorer: { _ in })
        coordinator.onDocument = { _ in XCTFail("Quick copy opened editor") }
        coordinator.run(.copyRegion); backend.catalogReply?(.success(.init(displays: [], windows: [])))
        overlay?.select(.window(42)); backend.captureReply?(.success(try image()))
        waitFor { board.data(forType: .png) != nil }
        XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.pending, 0)
    }
    func testCancelledQuickCaptureRejectsLatePixelsAndPreservesClipboard() throws {
        let backend = Backend(), board = pasteboard(), history = try history()
        var overlay: CaptureOverlayController?
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board, presentSelection: { overlay = $0 })
        board.setString("original synthetic content", forType: .string); let revision = board.changeCount
        coordinator.onDocument = { _ in XCTFail("Cancelled capture opened editor") }
        coordinator.run(.copyRegion); backend.catalogReply?(.success(.init(displays: [], windows: [])))
        overlay?.select(.window(1)); coordinator.cancel(); backend.captureReply?(.success(try image()))
        XCTAssertEqual(board.changeCount, revision); XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.pending, 0)
    }
    func testDeniedQuickCapturePreservesClipboardAndRequestsPermissionOnlyOnce() throws {
        let backend = Backend(), board = pasteboard(), history = try history(); backend.hasPermission = false
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board)
        coordinator.onErrorMessage = { _ in }
        board.setString("original synthetic content", forType: .string); let revision = board.changeCount
        coordinator.run(.copyRegion); coordinator.run(.copyRegion)
        XCTAssertEqual(backend.permissionRequests, 1); XCTAssertTrue(backend.selections.isEmpty)
        XCTAssertEqual(board.changeCount, revision); XCTAssertTrue(history.entries.isEmpty)
    }
    func testEditorReselectionPreservesOriginalDocumentAndUnsavedAnnotations() throws {
        _ = NSApplication.shared
        let backend = Backend(), board = pasteboard(), coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: try history(), defaults: defaults(), pasteboard: board, presentSelection: { _ in })
        var document = CaptureDocument(original: try CaptureRaster(image: image()))
        document.annotations = [CaptureAnnotation(tool: .rectangle, rect: CGRect(x: 2, y: 2, width: 20, height: 10))]
        coordinator.open(document)
        let editor = try XCTUnwrap(coordinator.editors.first)
        editor.model.onReselect?(); coordinator.cancel()
        XCTAssertEqual(editor.model.document, document); XCTAssertTrue(editor.model.dirty); XCTAssertEqual(coordinator.editors.count, 1)
        editor.model.dirty = false; editor.window?.close()
    }
    func testQuickShortcutPreferencesAndConflictStatusAreIndependent() {
        let preferences = defaults()
        preferences.set(42, forKey: "captureHotKeyCode"); preferences.set(768, forKey: "captureHotKeyModifiers")
        preferences.set(12, forKey: "captureCopyHotKeyCode"); preferences.set(4096, forKey: "captureCopyHotKeyModifiers")
        let model = CaptureSettingsModel(defaults: preferences)
        XCTAssertEqual(model.keyCode, 42); XCTAssertEqual(model.copyKeyCode, 12)
        model.onRegisterCopy = { _, _ in false }; model.restoreDefault(copy: true)
        XCTAssertEqual(model.copyKeyCode, 21); XCTAssertEqual(model.copyModifiers, CaptureSettingsModel.defaultCopyModifiers)
        XCTAssertEqual(model.keyCode, 42); XCTAssertEqual(model.modifiers, 768); XCTAssertNil(model.actualCopyShortcut)
        model.status(bound: true); XCTAssertNotNil(model.actualShortcut); XCTAssertNotNil(model.copyShortcutError)
        let reopened = CaptureSettingsModel(defaults: preferences)
        XCTAssertEqual(reopened.copyModifiers, CaptureSettingsModel.defaultCopyModifiers); XCTAssertEqual(reopened.keyCode, 42)
    }
    func testThreeHotKeyEventIDsAndSystemQuickScreenshotConflictStayDistinct() {
        let identities: [HotKey.Identifier] = [.search, .capture, .captureCopy]
        for identity in identities {
            for target in identities { XCTAssertEqual(HotKey.matches(EventHotKeyID(signature: HotKey.signature, id: identity.rawValue), identifier: target), identity == target) }
        }
        let preferences: [String: Any] = ["AppleSymbolicHotKeys": ["31": ["enabled": true, "value": ["parameters": [52, 21, NSEvent.ModifierFlags([.control, .shift, .command]).rawValue]]]]]
        XCTAssertTrue(SpotlightShortcut.isReserved(keyCode: 21, modifiers: CaptureSettingsModel.defaultCopyModifiers, preferences: preferences))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: 21, modifiers: CaptureSettingsModel.defaultModifiers, preferences: preferences))
        for query in ["直接截图", "zhijiejietu", "copy screenshot"] { XCTAssertTrue(CaptureAction.search(query).contains(.copyRegion)) }
    }
}
