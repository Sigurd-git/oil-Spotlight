import AppKit
import SwiftUI

private final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class CaptureOverlayController {
    enum Mode { case confirm, annotate, copyImmediately }

    #if DEBUG
    static func snapshotView() -> NSView {
        let view = CaptureOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        view.selection = CGRect(x: 160, y: 124, width: 570, height: 340)
        var markup = CaptureMarkup()
        markup.tool = .rectangle
        markup.beginStroke(at: CGPoint(x: 95, y: 83))
        markup.endStroke(at: CGPoint(x: 263, y: 166))
        markup.tool = .arrow
        markup.beginStroke(at: CGPoint(x: 365, y: 230))
        markup.endStroke(at: CGPoint(x: 268, y: 158))
        view.markup = markup
        view.label = ""
        view.showMarkupToolbar(true)
        return view
    }
    #endif
    private var windows: [NSWindow] = [], views: [CaptureOverlayView] = []
    private let catalog: CaptureCatalog, mainHeight: CGFloat
    private var windowMode: Bool, anchor: CGPoint?, current: CGPoint?
    private var hovered: CaptureWindow?
    private(set) var pendingSelection: CaptureSelection?
    private let mode: Mode
    private var markup: CaptureMarkup?
    private weak var textEntryView: CaptureOverlayView?
    private var submitted = false
    private var keyMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let frontmostProcessID: () -> pid_t?
    private var activeProcessID: pid_t?
    var onSelect: ((CaptureSelection) -> Void)?, onCancel: (() -> Void)?
    var onMarkupFinish: ((CaptureMarkupSubmission) -> Void)?
    var hasMarkup: Bool { markup?.canUndo == true || textEntryView?.hasText == true }
    init(catalog: CaptureCatalog, windowMode: Bool, mode: Mode = .confirm,
         frontmostProcessID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.catalog = catalog; self.windowMode = windowMode
        self.mode = mode
        markup = mode == .annotate ? CaptureMarkup() : nil
        self.frontmostProcessID = frontmostProcessID
        mainHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }
    func present() {
        guard windows.isEmpty else { return }
        submitted = false
        activeProcessID = frontmostProcessID()
        for display in catalog.displays {
            // Like the launcher, acquire keyboard focus without waiting for app activation.
            let window = CaptureOverlayWindow(contentRect: CaptureGeometry.cocoa(display.frame, mainHeight: mainHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false; window.isRestorable = false; window.level = .screenSaver
            // The system fade can leave the selection visible after orderOut.
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.acceptsMouseMovedEvents = true; window.isReleasedWhenClosed = false
            let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: display.frame.size)); view.controller = self
            window.contentView = view; window.makeFirstResponder(view)
            windows.append(window); views.append(view); window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        (windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first)?.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.windows.isEmpty else { return event }
            // Windowless keys still belong to the focused capture session.
            if let window = event.window ?? NSApp.keyWindow, !self.windows.contains(where: { $0 === window }) { return event }
            return self.handleKey(event) ? nil : event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  self.windows.contains(where: { $0 === window }) else { return }
            // Another overlay may take focus on a different display in the same turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.windows.isEmpty,
                      !self.windows.contains(where: { $0.isKeyWindow }) else { return }
                AppLog.logger.info("capture overlay cancelled reason=key-focus")
                self.onCancel?()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, !self.windows.isEmpty,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processID = application.processIdentifier
            // Nonactivating panels leave the original app in front. Repeated or
            // late activation notifications are not a switch away from capture.
            guard processID == self.frontmostProcessID(), processID != self.activeProcessID else { return }
            self.activeProcessID = processID
            guard processID != ProcessInfo.processInfo.processIdentifier else { return }
            AppLog.logger.info("capture overlay cancelled reason=application-switch")
            self.onCancel?()
        }
        redraw()
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        if let textEntryView {
            if textEntryView.isEditingText {
                guard !textEntryView.hasMarkedText else { return false }
                switch event.keyCode {
                case 53: onCancel?()
                case 36, 76: commitText(); redraw()
                default: return false
                }
                return true
            }
            commitText()
            redraw()
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if markup != nil, pendingSelection != nil, modifiers == .command || modifiers == [.command, .shift] {
            switch event.keyCode {
            case 6: modifiers.contains(.shift) ? redo() : undo()
            case 8 where modifiers == .command: finishMarkup(.copy)
            case 1 where modifiers == .command: finishMarkup(.save)
            default: return false
            }
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: confirmSelection()
        case 15: reselect()
        case 49:
            // A held Space key must switch modes only once per press.
            if !event.isARepeat { windowMode.toggle(); clearSelection() }
        default: return false
        }
        return true
    }
    private func position(for event: NSEvent) -> CGPoint {
        // Read the position attached to this event, rather than a later global
        // cursor position when queued or directly delivered events are handled.
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }
    func move(with event: NSEvent) {
        guard pendingSelection == nil else { return }
        current = position(for: event); hovered = catalog.windows.first { $0.frame.contains(current!) }; redraw()
    }
    func drag(with event: NSEvent) {
        if markup?.stroke != nil, let rect = selectedRect {
            markup?.updateStroke(to: markupPoint(for: event, in: rect))
            for view in views { view.markup = markup; view.needsDisplay = true }
        } else {
            move(with: event)
        }
    }
    func down(with event: NSEvent) {
        commitText()
        if pendingSelection != nil, let rect = selectedRect, rect.contains(position(for: event)),
           let tool = markup?.tool, tool != .select {
            let point = markupPoint(for: event, in: rect)
            if tool == .text, let view = event.window?.contentView as? CaptureOverlayView {
                if view.beginText(at: point, color: markup?.color ?? CaptureColor()) { textEntryView = view }
            } else if tool != .text {
                markup?.beginStroke(at: point)
            }
            redraw()
            return
        }
        if pendingSelection != nil { reselect() } else { clearSelection() }
        move(with: event); anchor = current
    }
    func up(with event: NSEvent) {
        if pendingSelection != nil {
            if markup?.stroke != nil, let rect = selectedRect {
                markup?.endStroke(at: markupPoint(for: event, in: rect))
                redraw()
            }
            return
        }
        move(with: event)
        if windowMode, let hovered { select(.window(hovered.id, alignToFrame: markup != nil)) }
        else if let anchor, let current {
            let rect = CGRect.between(anchor, current).integral
            if rect.width >= 2 && rect.height >= 2 { select(.region(rect)) }
        }
    }
    func select(_ selection: CaptureSelection) {
        pendingSelection = selection
        if mode == .copyImmediately { confirmSelection() } else { redraw() }
    }
    func confirmSelection() {
        if markup != nil { finishMarkup(.copy); return }
        guard let selection = pendingSelection else { return }
        pendingSelection = nil; onSelect?(selection)
    }
    func finishMarkup(_ output: CaptureMarkupOutput) {
        guard !submitted, let selection = pendingSelection, let rect = selectedRect,
              !rect.isEmpty, markup?.stroke == nil, let onMarkupFinish else { return }
        commitText()
        guard let markup else { return }
        submitted = true
        onMarkupFinish(CaptureMarkupSubmission(selection: selection, size: rect.size, annotations: markup.annotations, output: output))
    }
    func chooseTool(_ tool: CaptureTool) {
        commitText()
        let next: CaptureTool = markup?.tool == tool ? .select : tool
        markup?.tool = next
        redraw()
    }
    func chooseColor(_ color: CaptureColor) {
        commitText()
        markup?.color = color
        redraw()
    }
    func undo() { commitText(); markup?.undo(); redraw() }
    func redo() { commitText(); markup?.redo(); redraw() }
    private func commitText() {
        guard let view = textEntryView else { return }
        textEntryView = nil
        if let (value, rect) = view.takeText() { markup?.addText(value, in: rect) }
    }
    private func markupPoint(for event: NSEvent, in rect: CGRect) -> CGPoint {
        let point = position(for: event)
        return CGPoint(x: min(rect.width, max(0, point.x - rect.minX)),
                       y: min(rect.height, max(0, point.y - rect.minY)))
    }
    func reselect() { windowMode = false; clearSelection() }
    private func clearSelection() {
        _ = textEntryView?.takeText()
        textEntryView = nil
        if markup != nil { markup = CaptureMarkup() }
        pendingSelection = nil; anchor = nil; current = nil; hovered = nil
        redraw()
    }
    var selectedRect: CGRect? {
        if let pendingSelection {
            switch pendingSelection {
            case .region(let rect): return rect
            case .window(let id, _): return catalog.windows.first { $0.id == id }?.frame
            }
        }
        return windowMode ? hovered?.frame : anchor.flatMap { start in current.map { CGRect.between(start, $0) } }
    }
    private func redraw() {
        let rect = selectedRect
        let toolbarDisplay = current.flatMap { point in catalog.displays.first { $0.frame.contains(point) } }
            ?? catalog.displays.first { display in rect.map { display.frame.intersects($0) } == true }
        for (view, display) in zip(views, catalog.displays) {
            if let rect, let window = view.window {
                let cocoa = CaptureGeometry.cocoa(rect, mainHeight: mainHeight)
                view.selection = view.convert(window.convertFromScreen(cocoa), from: nil)
            } else { view.selection = nil }
            let showsControls = pendingSelection != nil && display.id == toolbarDisplay?.id
            if pendingSelection != nil, let markup {
                view.markup = markup
                view.label = ""
                view.showMarkupToolbar(showsControls)
            } else {
                view.markup = nil
                view.label = pendingSelection != nil ? L10n.text("capture.overlay.confirmHint") : L10n.text(mode == .copyImmediately ? "capture.overlay.copyHint" : "capture.overlay.hint")
                view.showMarkupToolbar(false)
                view.showControls(showsControls)
            }
            view.needsDisplay = true
        }
    }
    var visibleWindowIDs: Set<CGWindowID> {
        Set(windows.compactMap { window in
            guard window.isVisible, window.windowNumber > 0 else { return nil }
            return CGWindowID(exactly: window.windowNumber)
        })
    }
    func hide() {
        commitText()
        markup?.cancelStroke()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
        activeProcessID = nil
        windows.forEach { $0.orderOut(nil); $0.close() }; windows = []; views = []
    }
    func close() { hide(); clearSelection() }
    deinit { close() }
}
private final class CaptureOverlayView: NSView {
    weak var controller: CaptureOverlayController?
    var selection: CGRect?, label = L10n.text("capture.overlay.hint")
    var markup: CaptureMarkup?
    private var controls: CaptureSelectionControls?
    private var markupToolbar: CaptureMarkupToolbar?
    private var textField: NSTextField?
    private var textRect: CGRect?
    var isEditingText: Bool { textField?.currentEditor() != nil }
    var hasText: Bool { !(textField?.currentEditor()?.string ?? textField?.stringValue ?? "").isEmpty }
    var hasMarkedText: Bool { (textField?.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { controller?.onCancel?() }
    func showControls(_ visible: Bool) {
        guard visible else { controls?.isHidden = true; return }
        if controls == nil {
            let controls = CaptureSelectionControls()
            controls.onConfirm = { [weak self] in self?.controller?.confirmSelection() }
            controls.onReselect = { [weak self] in self?.controller?.reselect() }
            controls.onCancel = { [weak self] in self?.controller?.onCancel?() }
            addSubview(controls); self.controls = controls
        }
        let width = min(360, max(1, bounds.width - 24)), rect = selection ?? bounds
        controls?.frame = CGRect(x: min(max(12, rect.minX), bounds.maxX - width - 12),
                                  y: min(max(58, rect.minY - 52), max(58, bounds.maxY - 56)), width: width, height: 44)
        controls?.isHidden = false
    }
    func showMarkupToolbar(_ visible: Bool) {
        guard visible, let selection, let markup else { markupToolbar?.isHidden = true; return }
        let portion = selection.intersection(bounds)
        guard !portion.isEmpty else { markupToolbar?.isHidden = true; return }
        let toolbar: CaptureMarkupToolbar
        if let markupToolbar {
            toolbar = markupToolbar
        } else {
            toolbar = CaptureMarkupToolbar(chooseTool: { [weak self] in self?.controller?.chooseTool($0) },
                                           chooseColor: { [weak self] in self?.controller?.chooseColor($0) },
                                           undo: { [weak self] in self?.controller?.undo() },
                                           redo: { [weak self] in self?.controller?.redo() },
                                           reselect: { [weak self] in self?.controller?.reselect() },
                                           cancel: { [weak self] in self?.controller?.onCancel?() },
                                           finish: { [weak self] in self?.controller?.finishMarkup($0) })
            markupToolbar = toolbar
            addSubview(toolbar)
        }
        let size = toolbar.update(from: markup, availableWidth: bounds.width - 24)
        let bottom = bounds.minY + 6
        let top = bounds.maxY - 6
        let below = portion.minY - bottom, above = top - portion.maxY
        let placeBelow = below >= size.height || (above < size.height && below >= above)
        let y = placeBelow ? max(bottom, portion.minY - size.height - 8) : min(top - size.height, portion.maxY + 8)
        let x = max(12, min(portion.maxX - size.width, bounds.maxX - size.width - 12))
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        toolbar.isHidden = false
    }
    func beginText(at point: CGPoint, color: CaptureColor) -> Bool {
        guard let selection, let window else { return false }
        let region = bounds.intersection(selection).insetBy(dx: 3, dy: 3)
        guard !region.isNull, region.width >= 64, region.height >= 30 else { return false }
        let x = max(region.minX, min(selection.minX + point.x, region.maxX - 64))
        let top = max(region.minY + 30, min(selection.maxY - point.y, region.maxY))
        let frame = CGRect(x: x, y: top - 30, width: min(250, region.maxX - x), height: 30)
        let field = NSTextField(frame: frame)
        field.font = .systemFont(ofSize: CaptureMarkup.textSize)
        field.textColor = color.nsColor
        field.backgroundColor = color.red + color.green + color.blue > 1.4 ? .black : .white
        field.placeholderString = CaptureTool.text.title
        field.usesSingleLineMode = true
        field.focusRingType = .none
        addSubview(field)
        textField = field
        textRect = CGRect(x: x - selection.minX + 3, y: selection.maxY - top + 3, width: frame.width - 6, height: 27)
        if window.makeFirstResponder(field) { return true }
        _ = takeText()
        return false
    }
    func takeText() -> (String, CGRect)? {
        guard let field = textField, let rect = textRect else { return nil }
        let value = field.currentEditor()?.string ?? field.stringValue
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        textField = nil
        textRect = nil
        return (value, rect)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { controller?.move(with: event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        controller?.down(with: event)
    }
    override func mouseDragged(with event: NSEvent) { controller?.drag(with: event) }
    override func mouseUp(with event: NSEvent) { controller?.up(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill(); bounds.fill()
        if let selection, let context = NSGraphicsContext.current?.cgContext {
            // Fully transparent pixels in a nonopaque window let native clicks
            // through to the app below, cancelling capture before mouseUp.
            context.saveGState(); context.setBlendMode(.copy)
            context.setFillColor(NSColor.black.withAlphaComponent(0.02).cgColor)
            context.fill(selection); context.restoreGState()
            if let markup {
                context.saveGState()
                context.clip(to: selection)
                context.translateBy(x: selection.minX, y: selection.maxY)
                context.scaleBy(x: 1, y: -1)
                for item in markup.annotations {
                    CaptureRenderer.draw(item, resources: [:], original: nil, originalSize: selection.size, in: context)
                }
                if let item = markup.stroke {
                    CaptureRenderer.draw(item, resources: [:], original: nil, originalSize: selection.size, in: context)
                }
                context.restoreGState()
            }
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 2; path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        (label as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: attributes)
    }
}

private final class CaptureSelectionControls: NSVisualEffectView {
    var onConfirm: (() -> Void)?, onReselect: (() -> Void)?, onCancel: (() -> Void)?
    init() {
        super.init(frame: .zero)
        material = .hudWindow; state = .active; appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true; layer?.cornerRadius = 8
        let confirm = NSButton(title: L10n.text("capture.overlay.confirm"), target: self, action: #selector(confirmSelection))
        let reselect = NSButton(title: L10n.text("capture.editor.reselect"), target: self, action: #selector(reselectRegion))
        let cancel = NSButton(title: L10n.text("action.cancel"), target: self, action: #selector(cancelSelection))
        let stack = NSStackView(views: [reselect, cancel, confirm]); stack.orientation = .horizontal; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func confirmSelection() { onConfirm?() }
    @objc private func reselectRegion() { onReselect?() }
    @objc private func cancelSelection() { onCancel?() }
}

final class CaptureScrollModel: ObservableObject {
    @Published var height = 0
    @Published var additions = 0
    @Published var status = L10n.text("capture.scroll.hint")
    var finish: (() -> Void)?, cancel: (() -> Void)?
}
struct CaptureScrollView: View {
    @ObservedObject var model: CaptureScrollModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("capture.action.scroll")).font(.headline)
            Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("capture.scroll.lines", String(model.height), String(model.additions))).monospacedDigit()
            HStack { Button(L10n.text("action.cancel")) { model.cancel?() }; Button(L10n.text("capture.scroll.finish")) { model.finish?() }.buttonStyle(.borderedProminent) }
        }.padding(16).frame(width: 300)
    }
}

struct CaptureHistoryView: View {
    @ObservedObject var history: CaptureHistory
    var open: (CaptureArchiveEntry) -> Void
    var body: some View {
        VStack {
            Text(L10n.text("capture.history.warning")).font(.caption).foregroundStyle(.secondary).padding()
            if let error = history.error { Text(error).foregroundStyle(.red).padding() }
            if history.entries.isEmpty { Text(L10n.text("capture.history.empty")).padding(); Spacer() }
            else {
                List(history.entries) { entry in
                    HStack {
                        CaptureThumbnail(history: history, entry: entry)
                        VStack(alignment: .leading) { Text(entry.title); Text("\(entry.width) × \(entry.height) · \(entry.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button(L10n.text("capture.action.edit")) { open(entry) }
                    }.contextMenu { Button(L10n.text("capture.history.delete")) { history.remove(entry.id) } }
                }
            }
        }.frame(minWidth: 560, minHeight: 380).onAppear { history.load() }
    }
}
private struct CaptureThumbnail: View {
    let history: CaptureHistory, entry: CaptureArchiveEntry
    @State var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo") } }.frame(width: 90, height: 60)
            .onAppear { history.thumbnail(entry) { value in if let cg = try? value?.image(maximumDimension: 160) { image = NSImage(cgImage: cg, size: .zero) } } }
            .onDisappear { image = nil }
    }
}

final class CapturePinController: NSWindowController, NSWindowDelegate {
    let image: CGImage?, text: String?
    var onCopy: (() -> Void)?, onClose: (() -> Void)?
    init(image: CGImage? = nil, text: String? = nil) {
        self.image = image; self.text = text
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: image.map { min(600, max(160, 360 * Double($0.height) / Double($0.width))) } ?? 240), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = L10n.text("capture.action.pin"); window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false; window.isRestorable = false
        window.isMovableByWindowBackground = true; window.collectionBehavior = [.fullScreenAuxiliary]
        let content: NSView
        if let image {
            let view = NSImageView(); view.image = NSImage(cgImage: image, size: .zero); view.imageScaling = .scaleProportionallyUpOrDown; content = view
        } else {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true
            let view = NSTextView(); view.string = text ?? ""; view.isEditable = false; view.isRichText = false; view.font = .systemFont(ofSize: 17); view.autoresizingMask = [.width]; view.isVerticallyResizable = true
            view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view; content = scroll
        }
        let copy = NSButton(title: L10n.text("launcher.copy"), target: nil, action: nil)
        let spaces = NSButton(checkboxWithTitle: L10n.text("capture.pin.allSpaces"), target: nil, action: nil)
        let alpha = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: nil, action: nil); alpha.toolTip = L10n.text("capture.pin.opacity")
        let controls = NSStackView(views: [copy, spaces, alpha]); controls.orientation = .horizontal
        let stack = NSStackView(views: [content, controls]); stack.orientation = .vertical; stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)
        stack.alignment = .leading; window.contentView = stack
        content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        content.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -42).isActive = true
        super.init(window: window); window.delegate = self
        copy.target = self; copy.action = #selector(copyContent); spaces.target = self; spaces.action = #selector(changeSpaces(_:)); alpha.target = self; alpha.action = #selector(changeAlpha(_:))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copyContent() { onCopy?() }
    @objc private func changeSpaces(_ button: NSButton) { window?.collectionBehavior = button.state == .on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary] }
    @objc private func changeAlpha(_ slider: NSSlider) { window?.alphaValue = slider.doubleValue }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
