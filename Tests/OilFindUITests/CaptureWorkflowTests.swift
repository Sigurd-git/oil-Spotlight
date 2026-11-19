import AppKit
import Carbon
import CryptoKit
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class CaptureWorkflowTests: XCTestCase {
    private final class KeyReceiver: NSView {
        var keys: [UInt16] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }
    private final class Keys: ClipboardKeyProviding {
        let value = SymmetricKey(data: Data(repeating: 39, count: 32))
        func key(createIfMissing: Bool) throws -> SymmetricKey { value }
    }
    private final class Backend: CaptureBackend {
        var hasPermission = true, permissionRequests = 0
        var catalogReply: ((Result<CaptureCatalog, Error>) -> Void)?
        var captureReply: ((Result<CGImage, Error>) -> Void)?
        var selections: [CaptureSelection] = []
        var beforeCapture: (() -> Void)?
        func requestPermission() -> Bool { permissionRequests += 1; return hasPermission }
        func catalog(completion: @escaping (Result<CaptureCatalog, Error>) -> Void) { catalogReply = completion }
        func capture(_ selection: CaptureSelection, completion: @escaping (Result<CGImage, Error>) -> Void) {
            beforeCapture?()
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
    private func image(width: Int = 48, height: Int = 32) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
    func testReselectingWindowReturnsToRegionDrawing() throws {
        try assertWindowReselectionDrawsRegion(resetFirst: true)
    }
    func testDraggingAgainAfterWindowSelectionReturnsToRegionDrawing() throws {
        try assertWindowReselectionDrawsRegion(resetFirst: false)
    }
    private func assertWindowReselectionDrawsRegion(resetFirst: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil); defer { window.close() }
        let bounds = CaptureGeometry.quartz(window.frame, mainHeight: try XCTUnwrap(NSScreen.screens.first).frame.height)
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: [.init(id: 7, frame: bounds, title: "Synthetic", owner: "QA")]), windowMode: true)
        var selections: [CaptureSelection] = []; overlay.onSelect = { selections.append($0) }
        overlay.select(.window(7))
        if resetFirst { overlay.reselect() }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 240, y: 170), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        overlay.down(with: down); overlay.up(with: up)
        let expected = CaptureSelection.region(CaptureGeometry.quartz(CGRect(x: 120, y: 230, width: 220, height: 140), mainHeight: try XCTUnwrap(NSScreen.screens.first).frame.height))
        XCTAssertEqual(overlay.pendingSelection, expected)
        overlay.confirmSelection(); XCTAssertEqual(selections, [expected])
    }
    private func key(_ code: UInt16, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code))
    }
    private func drag(from start: CGPoint, to end: CGPoint, in window: NSWindow) throws {
        let events: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)]
        for (type, point) in events {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
    }
    private func button(_ label: String, in view: NSView) -> NSButton? {
        guard !view.isHidden else { return nil }
        if let button = view as? NSButton, button.accessibilityLabel() == label { return button }
        return view.subviews.lazy.compactMap { self.button(label, in: $0) }.first
    }
    private func presentOverlay(displayCount: Int = 1, candidates: [CaptureWindow] = [], requiresConfirmation: Bool = true,
                                frontmostProcessID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) throws -> (CaptureOverlayController, [NSWindow]) {
        _ = NSApplication.shared
        let height = try XCTUnwrap(NSScreen.screens.first).frame.height
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let displays = (0..<displayCount).map { CaptureDisplay(id: UInt32($0 + 1), frame: CaptureGeometry.quartz(CGRect(x: 100 + $0 * 350, y: 200, width: 320, height: 240), mainHeight: height), scale: 1) }
        let overlay = CaptureOverlayController(catalog: .init(displays: displays, windows: candidates), windowMode: false,
                                               mode: requiresConfirmation ? .confirm : .copyImmediately, frontmostProcessID: frontmostProcessID)
        addTeardownBlock { overlay.close() }
        overlay.present()
        let windows = NSApp.windows.filter { !existing.contains($0.windowNumber) && $0.isVisible }
        XCTAssertEqual(windows.count, displayCount)
        return (overlay, windows)
    }
    func testOverlayTakesKeyboardFocusWithoutActivatingApplication() throws {
        let (_, windows) = try presentOverlay(), window = try XCTUnwrap(windows.first)
        XCTAssertTrue(window is NSPanel)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.firstResponder === window.contentView)
    }
    func testOverlayAcceptsTheFirstMouseClickWithoutActivatingApplication() throws {
        let (_, windows) = try presentOverlay(), view = try XCTUnwrap(windows.first?.contentView)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.needsPanelToBecomeKey)
    }
    func testWindowHighlightRetainsMouseSurfaceBeforeAndAfterSelection() throws {
        let height = try XCTUnwrap(NSScreen.screens.first).frame.height
        let bounds = CaptureGeometry.quartz(CGRect(x: 140, y: 240, width: 220, height: 160), mainHeight: height)
        let (overlay, windows) = try presentOverlay(candidates: [.init(id: 7, frame: bounds, title: "Synthetic", owner: "QA")])
        let window = try XCTUnwrap(windows.first), view = try XCTUnwrap(window.contentView)
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        overlay.handleKey(try key(49)); overlay.move(with: move)
        XCTAssertNotNil(overlay.selectedRect)
        for pending in [false, true] {
            if pending { overlay.select(.window(7)) }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage), pixels = try CapturePixels(image)
            let x = pixels.width / 2, y = pixels.height / 2
            let alpha = pixels.bytes[(y * pixels.width + x) * 4 + 3]
            // AppKit must not expose a fully transparent hole to WindowServer.
            // Directly sending mouse events bypasses this native hit testing.
            XCTAssertGreaterThan(alpha, 0, "Window highlight lets clicks reach the underlying app (pending=\(pending))")
            XCTAssertLessThan(alpha, 20, "The selected window should remain visually clear")
            // Query WindowServer's native mouse-down target without moving the
            // pointer or injecting input into the foreground application.
            view.displayIfNeeded(); window.displayIfNeeded()
            let point = window.convertPoint(toScreen: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            waitFor { NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber }
        }
    }
    func testReactivatingTheForegroundApplicationKeepsWindowSelectionPending() throws {
        let application = try otherApplication()
        let (overlay, _) = try presentOverlay(frontmostProcessID: { application.processIdentifier })
        var cancellations = 0
        overlay.onCancel = { cancellations += 1; overlay.close() }
        overlay.handleKey(try key(49)); overlay.select(.window(7))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application])
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(overlay.pendingSelection, .window(7))
    }
    func testStaleApplicationActivationDoesNotCancelFocusedCapture() throws {
        let (overlay, _) = try presentOverlay(frontmostProcessID: { ProcessInfo.processInfo.processIdentifier })
        let application = try otherApplication()
        var cancellations = 0
        overlay.onCancel = { cancellations += 1; overlay.close() }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application])
        XCTAssertEqual(cancellations, 0)
    }
    func testWindowClickAfterSpaceSurvivesRepeatedActivationAndCapturesOnlyOnce() throws {
        let application = try otherApplication()
        let bounds = CaptureGeometry.quartz(CGRect(x: 100, y: 200, width: 320, height: 240), mainHeight: try XCTUnwrap(NSScreen.screens.first).frame.height)
        for requiresConfirmation in [true, false] {
            let (overlay, windows) = try presentOverlay(candidates: [.init(id: 7, frame: bounds, title: "Synthetic", owner: "QA")],
                requiresConfirmation: requiresConfirmation, frontmostProcessID: { application.processIdentifier })
            let window = try XCTUnwrap(windows.first)
            var selections: [CaptureSelection] = [], cancellations = 0
            overlay.onSelect = { selections.append($0); overlay.close() }
            overlay.onCancel = { cancellations += 1; overlay.close() }
            NSApp.sendEvent(try key(49))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 80, y: 100), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: application])
            }
            XCTAssertEqual(cancellations, 0)
            if requiresConfirmation {
                XCTAssertEqual(overlay.pendingSelection, .window(7)); XCTAssertTrue(window.isVisible)
                XCTAssertTrue(selections.isEmpty)
                NSApp.sendEvent(try key(36))
            }
            overlay.confirmSelection()
            XCTAssertEqual(selections, [.window(7)])
            XCTAssertFalse(window.isVisible)
            XCTAssertNil(overlay.pendingSelection)
        }
    }
    func testWindowMouseEventsCopyOnReturnOrImmediatelyInQuickMode() throws {
        _ = NSApplication.shared
        let height = try XCTUnwrap(NSScreen.screens.first).frame.height
        let display = CaptureDisplay(id: 1, frame: CaptureGeometry.quartz(CGRect(x: 100, y: 200, width: 320, height: 240), mainHeight: height), scale: 1)
        let catalog = CaptureCatalog(displays: [display], windows: [.init(id: 7, frame: display.frame, title: "Synthetic", owner: "QA")])
        for action in [CaptureAction.region, .copyRegion] {
            let backend = Backend(), board = pasteboard(), history = try history()
            let previous = Set(NSApp.windows.map(\.windowNumber))
            let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history,
                defaults: defaults(), pasteboard: board, focusRestorer: { _ in })
            coordinator.onDocument = { _ in XCTFail("Copying the chosen window should finish in the overlay") }
            coordinator.onErrorMessage = { XCTFail($0) }
            defer { coordinator.cancel() }
            coordinator.run(action); backend.catalogReply?(.success(catalog))
            let window = try XCTUnwrap(NSApp.windows.first { !previous.contains($0.windowNumber) && $0.isVisible })
            NSApp.sendEvent(try key(49))
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
            }
            if action == .region {
                XCTAssertTrue(backend.selections.isEmpty)
                NSApp.sendEvent(try key(36))
            }
            waitFor { backend.selections == [.window(7, alignToFrame: action == .region)] }
            XCTAssertFalse(window.isVisible)
            backend.captureReply?(.success(try image()))
            waitFor { board.data(forType: .png) != nil && history.pending == 0 && history.entries.count == 1 }
            XCTAssertTrue(coordinator.editors.isEmpty)
            XCTAssertEqual(try CaptureRaster(data: XCTUnwrap(board.data(forType: .png))).width, 48)
        }
    }
    private func otherApplication() throws -> NSRunningApplication {
        try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy != .prohibited
        })
    }
    func testOverlayResponderCancelsAfterSpace() throws {
        let (overlay, windows) = try presentOverlay(), window = try XCTUnwrap(windows.first)
        var cancellations = 0
        overlay.onCancel = { cancellations += 1; overlay.close() }
        let responder = try XCTUnwrap(window.firstResponder)
        responder.keyDown(with: try key(49))
        responder.cancelOperation(nil)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(window.isVisible)
    }
    func testWindowlessEscapeUsesApplicationEventRoute() throws {
        let (overlay, windows) = try presentOverlay(), window = try XCTUnwrap(windows.first)
        var cancellations = 0
        overlay.onCancel = { cancellations += 1; overlay.close() }
        NSApp.sendEvent(try key(49))
        NSApp.sendEvent(try key(53))
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(window.isVisible)
    }
    func testMovingFocusBetweenDisplayOverlaysKeepsCaptureActive() throws {
        let (overlay, windows) = try presentOverlay(displayCount: 2)
        var cancellations = 0; overlay.onCancel = { cancellations += 1 }
        for window in windows {
            window.makeKey()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            XCTAssertTrue(window.isKeyWindow)
        }
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
    }
    func testLosingOverlayFocusCancelsInsteadOfLeavingAnUnresponsiveSelection() throws {
        let (overlay, windows) = try presentOverlay()
        let other = SearchPanel(snapshot: true); defer { other.close() }
        var cancellations = 0; overlay.onCancel = { cancellations += 1; overlay.close() }
        other.makeKeyAndOrderFront(nil)
        waitFor { cancellations == 1 }
        XCTAssertTrue(other.isKeyWindow)
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }
    func testOtherWindowReceivesEscapeAfterCaptureLosesFocus() throws {
        let (overlay, _) = try presentOverlay()
        let other = SearchPanel(snapshot: true); defer { other.close() }
        let receiver = KeyReceiver(); other.contentView = receiver; other.makeFirstResponder(receiver)
        var cancellations = 0; overlay.onCancel = { cancellations += 1; overlay.close() }
        other.makeKeyAndOrderFront(nil)
        waitFor { cancellations == 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: other.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(event.window === other)
        NSApp.sendEvent(event)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(receiver.keys, [53])
    }
    func testOtherApplicationActivationCancelsEvenWhileOverlayStillHasKeyStatus() throws {
        var foregroundProcessID = ProcessInfo.processInfo.processIdentifier
        let (overlay, windows) = try presentOverlay(frontmostProcessID: { foregroundProcessID }), window = try XCTUnwrap(windows.first)
        var cancellations = 0; overlay.onCancel = { cancellations += 1; overlay.close() }
        window.makeKey(); XCTAssertTrue(window.isKeyWindow)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertEqual(cancellations, 0)
        let application = try otherApplication()
        foregroundProcessID = application.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: application])
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(window.isVisible)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: application])
        XCTAssertEqual(cancellations, 1)
    }
    func testReturningToOriginalApplicationAfterOwnActivationCancelsCapture() throws {
        let application = try otherApplication()
        var foregroundProcessID = application.processIdentifier
        let (overlay, _) = try presentOverlay(frontmostProcessID: { foregroundProcessID })
        var cancellations = 0
        overlay.onCancel = { cancellations += 1; overlay.close() }
        let center = NSWorkspace.shared.notificationCenter
        foregroundProcessID = ProcessInfo.processInfo.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertEqual(cancellations, 0)
        foregroundProcessID = application.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application])
        XCTAssertEqual(cancellations, 1)
    }
    func testCaptureMonitorPassesUnhandledKeysToTheResponder() throws {
        let (_, windows) = try presentOverlay(), window = try XCTUnwrap(windows.first)
        let receiver = KeyReceiver(); window.contentView = receiver; window.makeFirstResponder(receiver)
        window.makeKey()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        NSApp.sendEvent(event)
        XCTAssertEqual(receiver.keys, [0])
    }
    func testSpaceTogglesWindowModeBackToRegionWithoutCapturing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil); defer { window.close() }
        let height = try XCTUnwrap(NSScreen.screens.first).frame.height
        let bounds = CaptureGeometry.quartz(window.frame, mainHeight: height)
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: [.init(id: 7, frame: bounds, title: "Synthetic", owner: "QA")]), windowMode: false)
        var captured: [CaptureSelection] = []; overlay.onSelect = { captured.append($0) }
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        overlay.handleKey(try key(49)); overlay.move(with: move); XCTAssertEqual(overlay.selectedRect, bounds)
        overlay.handleKey(try key(49, repeatKey: true)); overlay.move(with: move); XCTAssertEqual(overlay.selectedRect, bounds)
        overlay.select(.window(7)); overlay.handleKey(try key(49)); overlay.move(with: move)
        XCTAssertNil(overlay.selectedRect); XCTAssertNil(overlay.pendingSelection); XCTAssertTrue(captured.isEmpty)
    }
    func testREntersRegionModeAfterSpaceEvenBeforeChoosingWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil); defer { window.close() }
        let bounds = CaptureGeometry.quartz(window.frame, mainHeight: try XCTUnwrap(NSScreen.screens.first).frame.height)
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: [.init(id: 7, frame: bounds, title: "Synthetic", owner: "QA")]), windowMode: false)
        overlay.handleKey(try key(49)); overlay.handleKey(try key(15))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 240, y: 170), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        overlay.down(with: down); overlay.up(with: up)
        guard case .region = overlay.pendingSelection else { return XCTFail("R must restore region drawing") }
    }
    func testEscapeAfterSpaceCancelsNormalAndQuickCaptureWithoutChangingClipboard() throws {
        for action in [CaptureAction.region, .copyRegion] {
            for chosenWindow in [false, true] {
                let backend = Backend(), board = pasteboard(), history = try history()
                var overlay: CaptureOverlayController?
                let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board, presentSelection: { overlay = $0 }, focusRestorer: { _ in })
                coordinator.onDocument = { _ in XCTFail("Cancelled selection opened an editor") }
                board.setString("original synthetic content", forType: .string); let revision = board.changeCount
                coordinator.run(action); let token = coordinator.generation
                backend.catalogReply?(.success(.init(displays: [], windows: [])))
                let selection = try XCTUnwrap(overlay); selection.handleKey(try key(49))
                if chosenWindow && action == .region { selection.select(.window(7)) }
                XCTAssertTrue(selection.handleKey(try key(53)))
                XCTAssertGreaterThan(coordinator.generation, token); XCTAssertNil(selection.pendingSelection)
                XCTAssertTrue(backend.selections.isEmpty); XCTAssertEqual(board.changeCount, revision)
                XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(history.pending, 0)
            }
        }
    }
    func testQuickSelectionSubmitsImmediatelyAndConfirmationCannotSubmitTwice() {
        let overlay = CaptureOverlayController(catalog: .init(displays: [], windows: []), windowMode: false, mode: .copyImmediately)
        var captured: [CaptureSelection] = []; overlay.onSelect = { captured.append($0) }
        overlay.select(.window(19)); overlay.confirmSelection()
        XCTAssertEqual(captured, [.window(19)]); XCTAssertNil(overlay.pendingSelection)
    }
    func testSelectionToolbarDrawsAndCopiesFlattenedPixelsWithEditableHistory() throws {
        _ = NSApplication.shared
        let backend = Backend(), board = pasteboard(), history = try history()
        var overlay: CaptureOverlayController?
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(),
            pasteboard: board, presentSelection: { overlay = $0; $0.present() })
        defer { coordinator.cancel() }
        coordinator.onDocument = { _ in XCTFail("Inline copy opened an editor") }
        coordinator.onErrorMessage = { XCTFail($0) }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CaptureGeometry.quartz(CGRect(x: (screen.frame.midX - 340).rounded(), y: (screen.frame.midY - 170).rounded(), width: 680, height: 340),
                                           mainHeight: screen.frame.height)
        board.setString("synthetic original", forType: .string); let revision = board.changeCount
        coordinator.run(.region)
        backend.catalogReply?(.success(.init(displays: [.init(id: 1, frame: frame, scale: 2)], windows: [])))
        let windowID = try XCTUnwrap(overlay?.visibleWindowIDs.first)
        let window = try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(windowID) })
        let view = try XCTUnwrap(window.contentView)
        func isOnScreen() -> Bool {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
        }
        waitFor { isOnScreen() }
        backend.beforeCapture = { XCTAssertFalse(isOnScreen()) }

        try drag(from: CGPoint(x: 310, y: 83), to: CGPoint(x: 580, y: 260), in: window)
        try XCTUnwrap(button(CaptureTool.ellipse.title, in: view)).performClick(nil)
        try drag(from: CGPoint(x: 337, y: 125), to: CGPoint(x: 392, y: 198), in: window)
        XCTAssertTrue(coordinator.hasUnsavedEdits)
        NSApp.sendEvent(try key(15))
        XCTAssertNil(overlay?.pendingSelection)
        XCTAssertFalse(coordinator.hasUnsavedEdits)

        try drag(from: CGPoint(x: 100, y: 120), to: CGPoint(x: 280, y: 230), in: window)
        let selection = CaptureSelection.region(CGRect(x: frame.minX + 100, y: frame.minY + 110, width: 180, height: 110).integral)
        view.layoutSubtreeIfNeeded()
        let arrow = try XCTUnwrap(button(CaptureTool.arrow.title, in: view))
        let arrowPoint = arrow.convert(CGPoint(x: arrow.bounds.midX, y: arrow.bounds.midY), to: view)
        XCTAssertTrue(view.hitTest(arrowPoint) === arrow)
        arrow.performClick(nil)
        try drag(from: CGPoint(x: 115, y: 145), to: CGPoint(x: 180, y: 205), in: window)
        try XCTUnwrap(button(CaptureTool.rectangle.title, in: view)).performClick(nil)
        try drag(from: CGPoint(x: 206, y: 164), to: CGPoint(x: 260, y: 191), in: window)
        NSApp.sendEvent(try key(6, modifiers: .command))
        XCTAssertTrue(try XCTUnwrap(button(L10n.text("capture.editor.redo"), in: view)).isEnabled)
        NSApp.sendEvent(try key(6, modifiers: [.command, .shift]))
        try XCTUnwrap(button(CaptureTool.text.title, in: view)).performClick(nil)
        let textPoint = CGPoint(x: 120, y: 221)
        try drag(from: textPoint, to: textPoint, in: window)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.insertText("中文 R", replacementRange: NSRange(location: NSNotFound, length: 0))
        NSApp.sendEvent(try key(36))
        XCTAssertTrue(window.firstResponder === view)

        XCTAssertEqual(overlay?.pendingSelection, selection)
        XCTAssertTrue(coordinator.hasUnsavedEdits)
        XCTAssertTrue(backend.selections.isEmpty)
        XCTAssertEqual(board.changeCount, revision)
        XCTAssertTrue(history.entries.isEmpty)
        NSApp.sendEvent(try key(36))
        overlay?.confirmSelection()
        waitFor { backend.selections == [selection] }
        let base = try image(width: 360, height: 220)
        backend.captureReply?(.success(base))
        waitFor { board.data(forType: .png) != nil && history.entries.count == 1 && history.pending == 0 }
        let raster = try CaptureRaster(data: XCTUnwrap(board.data(forType: .png)))
        let flattened = try CapturePixels(raster.image())
        let source = try CapturePixels(base)
        XCTAssertEqual(flattened.width, 360); XCTAssertEqual(flattened.height, 220)
        let edge = (78 * 360 + 250) * 4
        XCTAssertGreaterThan(flattened.bytes[edge], 200)
        let untouched = (38 * 360 + 250) * 4
        XCTAssertEqual(Array(flattened.bytes[untouched..<untouched + 4]), Array(source.bytes[untouched..<untouched + 4]))
        XCTAssertFalse(coordinator.hasUnsavedEdits)

        let recovered = expectation(description: "Annotated capture reopens")
        history.read(try XCTUnwrap(history.entries.first)) { result in
            defer { recovered.fulfill() }
            do {
                let document = try result.get()
                XCTAssertEqual(try CapturePixels(document.original.image()).bytes, source.bytes)
                XCTAssertEqual(document.annotations.map(\.tool), [.arrow, .rectangle, .text])
                XCTAssertEqual(document.annotations.first { $0.tool == .rectangle }?.rect, CGRect(x: 212, y: 78, width: 108, height: 54))
                XCTAssertEqual(document.annotations.last?.text, "中文 R")
                XCTAssertEqual(try CapturePixels(CaptureRenderer.image(document)).bytes, flattened.bytes)
            } catch { XCTFail(String(describing: error)) }
        }
        wait(for: [recovered], timeout: 3)
    }
    func testSelectionSaveCanBeCancelledAndRetriedWithoutLosingMarks() throws {
        _ = NSApplication.shared
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let backend = Backend(), board = pasteboard(), history = try history(), preferences = defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindExport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var overlay: CaptureOverlayController?
        var finishChoosing: ((CaptureCoordinator.ExportDestination?) -> Void)?
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: preferences,
            pasteboard: board, presentSelection: { overlay = $0; $0.present() }, pickSelectionDestination: { _, completion in
                finishChoosing = completion
                return nil
            })
        defer { coordinator.cancel() }
        coordinator.onDocument = { _ in XCTFail("Saving inline opened an editor") }
        coordinator.onErrorMessage = { XCTFail($0) }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CaptureGeometry.quartz(CGRect(x: 100, y: 160, width: 680, height: 340), mainHeight: screen.frame.height)
        let originalText = "Synthetic clipboard content"
        board.setString(originalText, forType: .string)
        coordinator.run(.region)
        backend.catalogReply?(.success(.init(displays: [.init(id: 1, frame: frame, scale: 1)], windows: [])))

        func overlayWindow() throws -> NSWindow {
            let id = try XCTUnwrap(overlay?.visibleWindowIDs.first)
            return try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(id) })
        }
        func chooseSave(atAttempt count: Int) throws -> (CaptureCoordinator.ExportDestination?) -> Void {
            finishChoosing = nil
            let view = try XCTUnwrap(try overlayWindow().contentView)
            try XCTUnwrap(button(L10n.text("capture.editor.save"), in: view)).performClick(nil)
            waitFor { backend.selections.count == count }
            backend.captureReply?(.success(try image(width: 180, height: 110)))
            waitFor { finishChoosing != nil }
            return try XCTUnwrap(finishChoosing)
        }

        let window = try overlayWindow()
        try drag(from: CGPoint(x: 100, y: 120), to: CGPoint(x: 280, y: 230), in: window)
        try XCTUnwrap(button(CaptureTool.rectangle.title, in: XCTUnwrap(window.contentView))).performClick(nil)
        try drag(from: CGPoint(x: 138, y: 151), to: CGPoint(x: 220, y: 202), in: window)
        let selection = try XCTUnwrap(overlay?.pendingSelection)
        let cancelSave = try chooseSave(atAttempt: 1)
        cancelSave(nil)
        waitFor { overlay?.visibleWindowIDs.isEmpty == false }
        XCTAssertTrue(coordinator.hasUnsavedEdits)
        XCTAssertEqual(overlay?.pendingSelection, selection)
        XCTAssertTrue(history.entries.isEmpty)
        let output = directory.appendingPathComponent("Annotated.png")
        let save = try chooseSave(atAttempt: 2)
        save((output, .png))
        waitFor { history.entries.count == 1 && history.pending == 0 }
        let exported = try CaptureRaster(data: Data(contentsOf: output))
        let pixels = try CapturePixels(exported.image())
        XCTAssertEqual(pixels.width, 180); XCTAssertEqual(pixels.height, 110)
        XCTAssertGreaterThan(pixels.bytes[(28 * 180 + 70) * 4], 200)
        XCTAssertEqual(board.string(forType: .string), originalText)
        XCTAssertFalse(coordinator.hasUnsavedEdits)
    }
    func testQuickCaptureCopiesPNGWithoutEditorAndRestoresEditableHistory() throws {
        _ = NSApplication.shared
        let backend = Backend(), board = pasteboard(), history = try history()
        var overlay: CaptureOverlayController?, focusRestoredAfterCopy = false
        let coordinator = CaptureCoordinator(clipboard: ClipboardHistory(snapshot: true), backend: backend, history: history, defaults: defaults(), pasteboard: board, presentSelection: { overlay = $0; $0.present() }, focusRestorer: { _ in focusRestoredAfterCopy = board.data(forType: .png) != nil })
        coordinator.onDocument = { _ in XCTFail("Quick copy must not open an editor") }
        coordinator.onErrorMessage = { XCTFail($0) }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CaptureGeometry.quartz(CGRect(x: (screen.frame.midX - 120).rounded(), y: (screen.frame.midY - 80).rounded(), width: 240, height: 160), mainHeight: screen.frame.height)
        coordinator.run(.copyRegion)
        defer { coordinator.cancel() }
        backend.catalogReply?(.success(.init(displays: [.init(id: CGMainDisplayID(), frame: frame, scale: 1)], windows: [])))
        let windowID = try XCTUnwrap(overlay?.visibleWindowIDs.first)
        let window = try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(windowID) })
        func overlayIsOnScreen() -> Bool {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
        }
        waitFor { overlayIsOnScreen() }
        backend.beforeCapture = { XCTAssertFalse(overlayIsOnScreen(), "The selection overlay must be off screen before reading pixels") }
        let selection = CaptureSelection.region(CGRect(x: frame.minX + 20, y: frame.minY + 20, width: 48, height: 32))
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 20, y: 140)),
                              (.leftMouseUp, CGPoint(x: 68, y: 108))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        waitFor { backend.selections == [selection] }
        backend.captureReply?(.success(try image()))
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
