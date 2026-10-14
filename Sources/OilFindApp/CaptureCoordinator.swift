import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class CaptureCoordinator: NSObject {
    let backend: CaptureBackend, history: CaptureHistory, settings: CaptureSettingsModel
    let clipboard: ClipboardHistory
    var hideSearch: (() -> Void)?, showSettings: (() -> Void)?
    var onDocument: ((CaptureDocument) -> Void)?
    var onErrorMessage: ((String) -> Void)?
    private(set) var generation = 0
    private var requestedPermission = false
    private var overlay: CaptureOverlayController?, scrollWindow: NSWindow?
    private var scrollModel: CaptureScrollModel?, stitcher: CaptureScrollStitcher?
    private(set) var editors: [CaptureEditorController] = []
    private var pins: [CapturePinController] = [], textWindows: [CaptureTextController] = []
    private var historyWindow: NSWindow?
    private let worker = DispatchQueue(label: "com.oiloil.find.capture-render", qos: .userInitiated)
    private let pasteboard: NSPasteboard
    private let presentSelection: (CaptureOverlayController) -> Void
    private let focusRestorer: (NSRunningApplication?) -> Void
    private var source: (String?, String?) = (nil, nil)
    init(clipboard: ClipboardHistory, backend: CaptureBackend = ScreenCaptureBackend(), history: CaptureHistory = CaptureHistory(), defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general, presentSelection: @escaping (CaptureOverlayController) -> Void = { $0.present() },
         focusRestorer: ((NSRunningApplication?) -> Void)? = nil) {
        self.clipboard = clipboard; self.backend = backend; self.history = history
        self.pasteboard = pasteboard; self.presentSelection = presentSelection
        self.focusRestorer = focusRestorer ?? { application in
            guard let application, !application.isTerminated, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            application.activate(options: [])
        }
        settings = CaptureSettingsModel(history: history, defaults: defaults)
        super.init()
        settings.onRetry = { [weak self] in self?.run(.region) }
        settings.onHistory = { [weak self] in self?.showHistory() }
    }
    var hasUnsavedEdits: Bool { editors.contains { $0.model.dirty } }
    var preventsTermination: Bool { hasUnsavedEdits || history.pending > 0 }
    func prepareToQuit() -> Bool {
        if history.pending > 0 { showError(CaptureFailure.storage); return false }
        guard hasUnsavedEdits else { return true }
        let alert = NSAlert(); alert.messageText = L10n.text("capture.editor.close"); alert.informativeText = L10n.text("capture.editor.closeHint")
        alert.addButton(withTitle: L10n.text("capture.editor.keep")); alert.addButton(withTitle: L10n.text("capture.editor.discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func cancel() { generation += 1; overlay?.close(); overlay = nil; backend.stopStream(); scrollWindow?.close(); scrollWindow = nil; stitcher = nil; scrollModel = nil }
    func stop() { cancel(); settings.cancelRecording(); history.flush(); pins.forEach { $0.close() } }
    func run(_ action: CaptureAction) {
        switch action {
        case .history: hideSearch?(); showHistory(); return
        case .edit: hideSearch?(); openFile(); return
        case .pin: hideSearch?(); pinClipboard(); return
        case .ocr:
            hideSearch?()
            if let data = clipboardImage(), let raster = try? CaptureRaster(data: data) { open(CaptureDocument(original: raster), recognize: true) }
            else { openFile(recognize: true) }; return
        default: break
        }
        cancel(); let token = generation
        AppLog.logger.info("capture started action=\(action.rawValue, privacy: .public) session=\(token, privacy: .public)")
        let front = NSWorkspace.shared.frontmostApplication
        let directCopy = action == .copyRegion
        source = (front?.bundleIdentifier, front?.localizedName)
        hideSearch?()
        if !backend.hasPermission {
            if !requestedPermission { requestedPermission = true; _ = backend.requestPermission() }
            settings.refreshPermission(backend.hasPermission)
            guard backend.hasPermission else { showError(CaptureFailure.permission); showSettings?(); return }
        }
        settings.refreshPermission(true)
        backend.catalog { [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .failure(let error): self.showError(error)
            case .success(let catalog):
                if action == .display {
                    let point = NSEvent.mouseLocation
                    let quartz = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
                    guard let display = catalog.displays.first(where: { $0.frame.contains(quartz) }) else { return }
                    self.capture(.region(display.frame), action: action, token: token)
                } else {
                    let overlay = CaptureOverlayController(catalog: catalog, windowMode: action == .window, requiresConfirmation: !directCopy)
                    self.overlay = overlay
                    overlay.onCancel = { [weak self] in
                        guard let self, token == self.generation else { return }; self.cancel()
                        // Cancelling after focus loss must not reactivate the previous app.
                        if directCopy, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { self.restoreFocus(front) }
                    }
                    overlay.onSelect = { [weak self] selection in
                        guard let self, token == self.generation else { return }
                        AppLog.logger.info("capture selection confirmed session=\(token, privacy: .public)")
                        self.overlay?.close(); self.overlay = nil
                        if action == .scroll {
                            let rect: CGRect?
                            switch selection { case .region(let region): rect = region; case .window(let id): rect = catalog.windows.first { $0.id == id }?.frame }
                            if let rect { self.startScroll(rect, token: token) }
                        } else { self.capture(selection, action: action, token: token, restoreFocus: directCopy ? front : nil) }
                    }
                    self.presentSelection(overlay)
                }
            }
        }
    }
    private func capture(_ selection: CaptureSelection, action: CaptureAction, token: Int, restoreFocus application: NSRunningApplication? = nil) {
        backend.capture(selection) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let image):
                AppLog.logger.info("capture pixels received session=\(token, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)")
                self.openImage(image, token: token, directCopy: action == .copyRegion, restoreFocus: application)
            case .failure(let error):
                AppLog.logger.error("capture backend failed session=\(token, privacy: .public) code=\((error as NSError).code, privacy: .public)")
                self.showError(error)
            }
        }
    }
    private func startScroll(_ rect: CGRect, token: Int) {
        let model = CaptureScrollModel(), stitcher = CaptureScrollStitcher()
        self.scrollModel = model; self.stitcher = stitcher
        let window = NSPanel(contentRect: CGRect(x: rect.maxX + 16, y: 100, width: 330, height: 170), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        window.title = L10n.text("capture.action.scroll"); window.level = .floating; window.isReleasedWhenClosed = false; window.isRestorable = false
        window.contentView = NSHostingView(rootView: CaptureScrollView(model: model)); window.center(); window.orderFrontRegardless(); scrollWindow = window
        model.cancel = { [weak self] in self?.cancel() }
        model.finish = { [weak self] in
            guard let self else { return }; self.backend.stopStream(); self.scrollWindow?.close(); self.scrollWindow = nil
            self.worker.async {
                let result = Result { try stitcher.image() }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    switch result { case .success(let image): self.openImage(image, token: token); case .failure(let error): self.showError(error) }
                    self.stitcher = nil; self.scrollModel = nil
                }
            }
        }
        var processing = false
        backend.startStream(region: rect, frame: { [weak self] image in
            guard let self, self.generation == token, !processing else { return }; processing = true
            self.worker.async {
                let result = Result { try stitcher.consume(image) }, height = stitcher.height, additions = stitcher.appendedFrames
                DispatchQueue.main.async {
                    processing = false; guard self.generation == token else { return }
                    model.height = height; model.additions = additions
                    switch result {
                    case .success(.uncertain): model.status = CaptureFailure.mismatch.localizedDescription
                    case .success(.capacity): model.status = CaptureFailure.capacity.localizedDescription; self.backend.stopStream()
                    case .success(.appended): model.status = L10n.text("capture.scroll.hint")
                    case .failure(let error): model.status = error.localizedDescription
                    default: break
                    }
                }
            }
        }, failure: { error in model.status = error.localizedDescription }, completion: { [weak self] result in
            if case .failure(let error) = result { self?.cancel(); self?.showError(error) }
        })
    }
    private func openImage(_ image: CGImage, token: Int, directCopy: Bool = false, restoreFocus application: NSRunningApplication? = nil) {
        let source = self.source
        worker.async { [weak self] in
            let result = Result { CaptureDocument(original: try CaptureRaster(image: image), sourceBundleID: source.0, sourceName: source.1) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let document):
                    if directCopy {
                        guard self.copyImage(document.original.data) else { self.showErrorMessage(L10n.text("capture.copy.failed")); return }
                        AppLog.logger.info("capture delivered destination=clipboard session=\(token, privacy: .public)")
                        self.restoreFocus(application)
                        self.history.save(document) { success in
                            guard self.generation == token else { return }
                            if !success { self.showErrorMessage(L10n.text("capture.copy.saveError")) }
                        }
                    } else {
                        self.open(document)
                        AppLog.logger.info("capture delivered destination=editor session=\(token, privacy: .public)")
                    }
                case .failure(let error):
                    guard case .capacity? = error as? CaptureFailure else { self.showError(error); return }
                    // Retain the successfully captured pixels while the user
                    // decides how to handle an oversized lossless encoding.
                    let alert = NSAlert(); alert.messageText = L10n.text("capture.error.capacity"); alert.informativeText = L10n.text("capture.reduce.hint")
                    alert.addButton(withTitle: L10n.text(directCopy ? "capture.reduce.copy" : "capture.reduce.edit")); alert.addButton(withTitle: L10n.text("action.cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    self.worker.async {
                        let reduced = Result { try CaptureRenderer.reduced(image) }
                        DispatchQueue.main.async {
                            guard self.generation == token else { return }
                            switch reduced { case .success(let value): self.openImage(value, token: token, directCopy: directCopy, restoreFocus: application); case .failure(let error): self.showError(error) }
                        }
                    }
                }
            }
        }
    }
    func open(_ document: CaptureDocument, saved: Bool = false, recognize: Bool = false) {
        if let onDocument { onDocument(document); return }
        let editor = CaptureEditorController(document: document, saved: saved)
        if let first = editors.first?.window, let next = editor.window { first.addTabbedWindow(next, ordered: .above) }
        editors.append(editor)
        let model = editor.model
        editor.onClose = { [weak self, weak editor] in self?.editors.removeAll { $0 === editor } }
        model.onOpen = { [weak self] in self?.openFile() }
        model.onReselect = { [weak self] in self?.run(.region) }
        model.onCopy = { [weak self, weak model] in if let model { self?.produce(model, output: .copy) } }
        model.onSave = { [weak self, weak editor] in if let editor { self?.saveFile(editor) } }
        model.onPin = { [weak self, weak model] in if let model { self?.produce(model, output: .pin) } }
        model.onOCR = { [weak self, weak model] in if let model { self?.recognize(model) } }
        model.onSticker = { [weak self, weak editor] in if let editor { self?.importSticker(editor) } }
        model.onMaterial = { [weak self, weak model] in if let model { self?.saveMaterial(model) } }
        model.onMaterials = { [weak self, weak model] in if let model { self?.chooseMaterial(model) } }
        editor.present(); if recognize { self.recognize(model) }
    }
    func openFile(recognize: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                self.worker.async {
                    let result = Result { () -> CaptureDocument in
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= CaptureRaster.maximumBytes else { throw CaptureFailure.capacity }
                        var document = CaptureDocument(original: try CaptureRaster(data: Data(contentsOf: url))); document.title = url.lastPathComponent; return document
                    }
                    DispatchQueue.main.async { switch result { case .success(let document): self.open(document, recognize: recognize); case .failure(let error): self.showError(error) } }
                }
            }
        }
    }
    func openClipboardImage(_ image: ClipboardImage, recognize: Bool = false, pin: Bool = false) {
        do {
            let raster = try CaptureRaster(data: image.data)
            if pin { let document = CaptureDocument(original: raster); open(document); if let model = editors.last?.model { produce(model, output: .pin) } }
            else { open(CaptureDocument(original: raster), recognize: recognize) }
        } catch { showError(error) }
    }
    private enum Output { case copy, pin, file(URL, UTType) }
    private func produce(_ model: CaptureEditorModel, output: Output) {
        guard !model.busy else { return }; model.busy = true
        let document = model.document
        worker.async { [weak self, weak model] in
            let result = Result { () -> (CGImage, Data) in
                let image = try CaptureRenderer.image(document), type: UTType
                if case .file(_, let format) = output { type = format } else { type = .png }
                let data = try CaptureRenderer.encode(image, type: type)
                if case .file(let url, _) = output { try data.write(to: url, options: .atomic) }
                return (image, data)
            }
            DispatchQueue.main.async {
                guard let self, let model else { return }; model.busy = false
                switch result {
                case .failure(let error): model.status = error.localizedDescription
                case .success(let result):
                    switch output {
                    case .copy:
                        guard self.copyImage(result.1) else { model.status = CaptureFailure.storage.localizedDescription; return }
                        model.status = L10n.text("capture.editor.copied")
                    case .pin: self.pin(image: result.0, text: nil)
                    case .file: model.status = L10n.text("capture.editor.exported")
                    }
                    self.history.save(document) { success in
                        if success && model.document == document { model.dirty = false }
                        if !success { model.status = self.history.error ?? CaptureFailure.storage.localizedDescription }
                    }
                }
            }
        }
    }
    @discardableResult private func copyImage(_ data: Data) -> Bool {
        let item = NSPasteboardItem(); item.setData(data, forType: .png); item.setData(Data([1]), forType: ClipboardSystemPasteboard.ownCopyType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        clipboard.recordGenerated(ClipboardImage(data: data).map(ClipboardContent.image)); return true
    }
    private func restoreFocus(_ application: NSRunningApplication?) {
        focusRestorer(application)
    }
    private func copyText(_ text: String) {
        let item = NSPasteboardItem(); item.setString(text, forType: .string); item.setData(Data([1]), forType: ClipboardSystemPasteboard.ownCopyType)
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([item]) { clipboard.recordGenerated(.text(text)) }
    }
    private func saveFile(_ editor: CaptureEditorController) {
        guard let window = editor.window else { return }
        let panel = NSSavePanel(), formats = NSPopUpButton()
        formats.addItems(withTitles: ["PNG", "JPEG"])
        let formatControl = CaptureExportFormatControl(panel: panel)
        formats.target = formatControl; formats.action = #selector(CaptureExportFormatControl.choose(_:))
        let title = editor.model.document.title
        let stem = UTType(filenameExtension: (title as NSString).pathExtension)?.conforms(to: .image) == true ? (title as NSString).deletingPathExtension : title
        panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = stem + ".png"
        panel.accessoryView = formats
        if let path = UserDefaults.standard.string(forKey: "captureExportDirectory") { panel.directoryURL = URL(fileURLWithPath: path) }
        panel.beginSheetModal(for: window) { [weak self, weak editor, formatControl] response in
            _ = formatControl
            guard let self, let editor, response == .OK, let url = panel.url else { return }
            let type: UTType = formats.indexOfSelectedItem == 1 ? .jpeg : .png
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "captureExportDirectory")
            self.produce(editor.model, output: .file(url, type))
        }
    }
    private func importSticker(_ editor: CaptureEditorController) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard let window = editor.window else { return }
        panel.beginSheetModal(for: window) { [weak self, weak editor] response in
            guard let self, let editor, response == .OK, let url = panel.url else { return }
            self.worker.async {
                let result = Result { () -> CaptureRaster in
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= CaptureRaster.maximumBytes else { throw CaptureFailure.capacity }
                    return try CaptureRaster(data: Data(contentsOf: url))
                }
                DispatchQueue.main.async { switch result {
                case .success(let image): let id = UUID(); editor.model.change { $0.resources[id] = image }; editor.model.sticker = id; editor.model.tool = .sticker
                case .failure(let error): self.showError(error)
                } }
            }
        }
    }
    private func saveMaterial(_ model: CaptureEditorModel) {
        let alert = NSAlert(); alert.messageText = L10n.text("capture.editor.material"); alert.informativeText = L10n.text("capture.editor.materialHint")
        let field = NSTextField(string: L10n.text("capture.material.default")); field.frame = CGRect(x: 0, y: 0, width: 240, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("capture.editor.material")); alert.addButton(withTitle: L10n.text("action.cancel"))
        if alert.runModal() == .alertFirstButtonReturn, let material = model.material(title: field.stringValue) { history.load(); history.save(material) }
    }
    private func chooseMaterial(_ model: CaptureEditorModel) {
        history.load()
        let menu = NSMenu()
        if history.materials.isEmpty { let item = NSMenuItem(title: L10n.text("capture.material.empty"), action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        for (index, entry) in history.materials.enumerated() { let item = NSMenuItem(title: entry.title, action: #selector(materialChosen(_:)), keyEquivalent: ""); item.target = self; item.tag = index; item.representedObject = model; menu.addItem(item) }
        if let view = editors.first(where: { $0.model === model })?.window?.contentView { menu.popUp(positioning: nil, at: CGPoint(x: 50, y: 50), in: view) }
    }
    @objc private func materialChosen(_ item: NSMenuItem) {
        guard let model = item.representedObject as? CaptureEditorModel, history.materials.indices.contains(item.tag) else { return }
        history.readMaterial(history.materials[item.tag]) { [weak self, weak model] result in
            switch result { case .success(let value): model?.insert(value); case .failure(let error): self?.showError(error) }
        }
    }
    private func recognize(_ model: CaptureEditorModel) {
        guard !model.busy else { return }; model.busy = true; model.status = L10n.text("capture.ocr.running")
        let document = model.document
        worker.async { [weak self, weak model] in
            let result = Result { try CaptureOCR.recognize(CaptureRenderer.image(document)) }
            DispatchQueue.main.async {
                model?.busy = false
                guard let self, let model else { return }
                switch result {
                case .success(let text):
                    model.status = text.isEmpty ? L10n.text("capture.ocr.empty") : ""
                    let controller = CaptureTextController(text: text); controller.onCopy = { [weak self] in self?.copyText($0) }
                    controller.onClose = { [weak self, weak controller] in self?.textWindows.removeAll { $0 === controller } }
                    self.textWindows.append(controller); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
                case .failure(let error): model.status = error.localizedDescription
                }
            }
        }
    }
    private func clipboardImage() -> Data? {
        let types = (NSPasteboard.general.types ?? []).filter { UTType($0.rawValue)?.conforms(to: .image) == true }
        let preferred = types.filter { $0 == .png } + types.filter { $0 != .png && $0 != .tiff } + types.filter { $0 == .tiff }
        for type in preferred.prefix(8) {
            if let data = NSPasteboard.general.data(forType: type), (try? CaptureRaster(data: data)) != nil { return data }
        }
        return nil
    }
    private func pinClipboard() {
        if let data = clipboardImage(), let raster = try? CaptureRaster(data: data) {
            open(CaptureDocument(original: raster)); if let model = editors.last?.model { produce(model, output: .pin) }
        } else if let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 256 * 1024 { pin(image: nil, text: text) }
        else { showErrorMessage(L10n.text("capture.pin.empty")) }
    }
    private func pin(image: CGImage?, text: String?) {
        let pin = CapturePinController(image: image, text: text); pins.append(pin)
        pin.onClose = { [weak self, weak pin] in self?.pins.removeAll { $0 === pin } }
        pin.onCopy = { [weak self] in
            if let image, let data = try? CaptureRenderer.encode(image, type: .png) { _ = self?.copyImage(data) }
            else if let text { self?.copyText(text) }
        }
        pin.showWindow(nil)
    }
    private func showHistory() {
        history.load()
        if historyWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("capture.action.history"); window.isReleasedWhenClosed = false; window.isRestorable = false
            window.contentView = NSHostingView(rootView: CaptureHistoryView(history: history) { [weak self] entry in self?.history.read(entry) { result in
                switch result { case .success(let document): self?.open(document, saved: true); case .failure(let error): self?.showError(error) }
            } }); window.center(); historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showError(_ error: Error) { showErrorMessage(error.localizedDescription) }
    private func showErrorMessage(_ message: String) {
        if let onErrorMessage { onErrorMessage(message); return }
        let alert = NSAlert(); alert.messageText = L10n.text("capture.document.title"); alert.informativeText = message; alert.runModal()
    }
}

private final class CaptureExportFormatControl: NSObject {
    weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }
    @objc func choose(_ sender: NSPopUpButton) {
        let type: UTType = sender.indexOfSelectedItem == 1 ? .jpeg : .png
        panel?.allowedContentTypes = [type]
        if let panel { panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + type.preferredFilenameExtension! }
    }
}
