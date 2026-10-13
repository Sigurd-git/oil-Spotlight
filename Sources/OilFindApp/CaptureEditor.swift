import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

final class CaptureEditorModel: ObservableObject {
    @Published var document: CaptureDocument
    @Published var tool = CaptureTool.select
    @Published var color = CaptureColor()
    @Published var lineWidth = 3.0
    @Published var fontSize = 24.0
    @Published var zoom = 1.0
    @Published var text = ""
    @Published var selected: Set<UUID> = []
    @Published var status = ""
    @Published var busy = false
    @Published var dirty = true
    @Published var preview: CGImage?
    @Published private(set) var resourcePreviews: [UUID: CGImage] = [:]
    private var loadingResources: Set<UUID> = []
    var sticker: UUID?
    private var undoStack: [CaptureDocument] = [], redoStack: [CaptureDocument] = []
    var onCopy: (() -> Void)?, onSave: (() -> Void)?, onPin: (() -> Void)?, onOCR: (() -> Void)?
    var onSticker: (() -> Void)?, onMaterial: (() -> Void)?, onMaterials: (() -> Void)?, onOpen: (() -> Void)?
    init(document: CaptureDocument, saved: Bool = false) { self.document = document; dirty = !saved }
    func loadPreview() {
        refreshResourcePreviews()
        guard preview == nil else { return }
        let original = document.original
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = try? original.image(maximumDimension: 1800)
            DispatchQueue.main.async { self?.preview = image }
        }
    }
    func refreshResourcePreviews() {
        let resources = document.resources
        if resourcePreviews.keys.contains(where: { resources[$0] == nil }) {
            resourcePreviews = resourcePreviews.filter { resources[$0.key] != nil }
        }
        for (id, raster) in resources where resourcePreviews[id] == nil && !loadingResources.contains(id) {
            loadingResources.insert(id)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = try? raster.image(maximumDimension: 1800)
                DispatchQueue.main.async {
                    guard let self else { return }; self.loadingResources.remove(id)
                    if self.document.resources[id] == raster, let image { self.resourcePreviews[id] = image }
                }
            }
        }
    }
    func commit(_ before: CaptureDocument) {
        guard document != before else { return }
        guard document.valid else { document = before; status = CaptureFailure.capacity.localizedDescription; return }
        undoStack.append(before); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack = []
        document.updatedAt = Date(); dirty = true
    }
    func change(_ edit: (inout CaptureDocument) -> Void) { let before = document; edit(&document); commit(before) }
    func setColor(_ value: CaptureColor) {
        guard value.valid else { return }; color = value
        change { for index in $0.annotations.indices where selected.contains($0.annotations[index].id) { $0.annotations[index].color = value } }
    }
    func setWidth(_ value: Double) {
        guard value.isFinite else { return }; lineWidth = min(128, max(1, value))
        change { for index in $0.annotations.indices where selected.contains($0.annotations[index].id) { $0.annotations[index].lineWidth = lineWidth } }
    }
    func setFont(_ value: Double) {
        guard value.isFinite else { return }; fontSize = min(512, max(6, value))
        change { for index in $0.annotations.indices where selected.contains($0.annotations[index].id) { $0.annotations[index].fontSize = fontSize } }
    }
    func setText(_ value: String) {
        text = value
        change { for index in $0.annotations.indices where selected.contains($0.annotations[index].id) && [.text, .emoji, .step].contains($0.annotations[index].tool) { $0.annotations[index].text = value } }
    }
    func undo() { guard let next = undoStack.popLast() else { return }; redoStack.append(document); document = next; dirty = true; selected = [] }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(document); document = next; dirty = true; selected = [] }
    func deleteSelection() { change { $0.annotations.removeAll { selected.contains($0.id) } }; selected = [] }
    func duplicateSelection() {
        let copies = document.annotations.filter { selected.contains($0.id) }.map { value -> CaptureAnnotation in
            var value = value; value.id = UUID(); value.rect = value.rect.offsetBy(dx: 16, dy: 16); value.points = value.points.map { CGPoint(x: $0.x + 16, y: $0.y + 16) }; return value
        }
        change { $0.annotations += copies }; selected = Set(copies.map(\.id))
    }
    func material(title: String) -> CaptureMaterial? {
        let objects = document.annotations.filter { selected.contains($0.id) }
        guard !objects.isEmpty else { return nil }
        let ids = Set(objects.compactMap(\.resourceID))
        return CaptureMaterial(title: title, annotations: objects, resources: document.resources.filter { ids.contains($0.key) })
    }
    func insert(_ material: CaptureMaterial) {
        guard material.valid else { return }
        let resourceMap = Dictionary(uniqueKeysWithValues: material.resources.keys.map { ($0, UUID()) })
        var objects = material.annotations.map { annotation -> CaptureAnnotation in
            var item = annotation; item.id = UUID(); item.resourceID = item.resourceID.flatMap { resourceMap[$0] }; return item
        }
        let group = objects.reduce(CGRect.null) { $0.union($1.rect) }
        let dx = document.crop.minX + 20 - group.minX, dy = document.crop.minY + 20 - group.minY
        for index in objects.indices { objects[index].rect = objects[index].rect.offsetBy(dx: dx, dy: dy); objects[index].points = objects[index].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        change { document in
            for (old, resource) in material.resources { document.resources[resourceMap[old]!] = resource }
            document.annotations += objects
        }
        selected = Set(objects.map(\.id))
    }
}

final class CaptureCanvas: NSView {
    let model: CaptureEditorModel
    private var start: CGPoint?, before: CaptureDocument?, drawing: CaptureAnnotation?, resizing = false
    private var cropDraft: CGRect?
    init(model: CaptureEditorModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), crop = model.document.crop
        return CGPoint(x: point.x / model.zoom + crop.minX, y: point.y / model.zoom + crop.minY)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let document = model.document
        context.saveGState(); context.scaleBy(x: model.zoom, y: model.zoom); context.translateBy(x: -document.crop.minX, y: -document.crop.minY)
        if let preview = model.preview {
            context.saveGState(); context.translateBy(x: 0, y: CGFloat(document.original.height)); context.scaleBy(x: 1, y: -1)
            context.draw(preview, in: document.original.bounds); context.restoreGState()
        }
        for annotation in document.annotations { CaptureRenderer.draw(annotation, resources: document.resources, resourceImages: model.resourcePreviews, original: model.preview, originalSize: document.original.bounds.size, in: context) }
        if let drawing { CaptureRenderer.draw(drawing, resources: document.resources, resourceImages: model.resourcePreviews, original: model.preview, originalSize: document.original.bounds.size, in: context) }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / model.zoom)
        for item in document.annotations where model.selected.contains(item.id) {
            context.stroke(item.rect.insetBy(dx: -3, dy: -3))
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fill(CGRect(x: item.rect.maxX - 4 / model.zoom, y: item.rect.maxY - 4 / model.zoom, width: 8 / model.zoom, height: 8 / model.zoom))
        }
        if let cropDraft { context.setStrokeColor(NSColor.systemGreen.cgColor); context.setLineWidth(2 / model.zoom); context.stroke(cropDraft) }
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let position = point(event); start = position; before = model.document; resizing = false
        if model.tool == .select {
            let hit = model.document.annotations.reversed().first { $0.rect.insetBy(dx: -8 / model.zoom, dy: -8 / model.zoom).contains(position) }
            if let hit {
                if event.modifierFlags.contains(.shift) { if model.selected.contains(hit.id) { model.selected.remove(hit.id) } else { model.selected.insert(hit.id) } }
                else if !model.selected.contains(hit.id) { model.selected = [hit.id] }
                resizing = model.selected.count == 1 && hypot(position.x - hit.rect.maxX, position.y - hit.rect.maxY) < 14 / model.zoom
                model.text = hit.text; model.color = hit.color; model.lineWidth = hit.lineWidth; model.fontSize = hit.fontSize
            } else { model.selected = [] }
        } else if model.tool != .crop {
            let size = model.tool == .step ? 44.0 : model.fontSize * 1.8
            var item = CaptureAnnotation(tool: model.tool, rect: CGRect(x: position.x, y: position.y, width: size, height: size),
                                         points: [position], color: model.color, lineWidth: model.lineWidth, fontSize: model.fontSize, text: model.text)
            if model.tool == .step { item.text = String(model.document.annotations.filter { $0.tool == .step }.count + 1) }
            if model.tool == .text { item.rect.size = CGSize(width: max(120, Double(model.text.count) * model.fontSize), height: model.fontSize * 2.4) }
            if model.tool == .emoji { item.text = model.text.isEmpty ? "🙂" : model.text; item.rect.size = CGSize(width: model.fontSize * 2, height: model.fontSize * 2) }
            if model.tool == .sticker {
                guard let id = model.sticker, let resource = model.document.resources[id] else { model.onSticker?(); start = nil; return }
                item.resourceID = id; item.rect.size = CGSize(width: 160, height: 160 * Double(resource.height) / Double(resource.width))
            }
            drawing = item; model.selected = []
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let before else { return }; let end = point(event)
        if model.tool == .select {
            var next = before
            for index in next.annotations.indices where model.selected.contains(next.annotations[index].id) {
                let old = before.annotations[index]
                if resizing {
                    let sx = max(8, end.x - old.rect.minX) / max(1, old.rect.width), sy = max(8, end.y - old.rect.minY) / max(1, old.rect.height)
                    next.annotations[index].rect.size = CGSize(width: max(8, end.x - old.rect.minX), height: max(8, end.y - old.rect.minY))
                    next.annotations[index].points = old.points.map { CGPoint(x: old.rect.minX + ($0.x - old.rect.minX) * sx, y: old.rect.minY + ($0.y - old.rect.minY) * sy) }
                } else {
                    next.annotations[index].rect = old.rect.offsetBy(dx: end.x - start.x, dy: end.y - start.y)
                    next.annotations[index].points = old.points.map { CGPoint(x: $0.x + end.x - start.x, y: $0.y + end.y - start.y) }
                }
            }
            model.document = next
        } else if model.tool == .crop { cropDraft = CGRect.between(start, end).intersection(model.document.crop) }
        else if var item = drawing {
            item.rect = CGRect.between(start, end)
            if model.tool == .pen { item.points.append(end); item.rect = item.points.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1)) } }
            else { item.points = [start, end] }
            drawing = item
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let before else { return }
        if let cropDraft, cropDraft.width >= 1, cropDraft.height >= 1 { model.document.crop = cropDraft.integral.intersection(model.document.original.bounds) }
        if let item = drawing, item.valid { model.document.annotations.append(item); model.selected = [item.id] }
        model.commit(before); self.before = nil; start = nil; drawing = nil; cropDraft = nil; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelection(); needsDisplay = true }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }; return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct CaptureCanvasHost: NSViewRepresentable {
    @ObservedObject var model: CaptureEditorModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.documentView = CaptureCanvas(model: model); scroll.drawsBackground = true; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        model.refreshResourcePreviews()
        let view = scroll.documentView!
        view.setFrameSize(NSSize(width: model.document.crop.width * model.zoom, height: model.document.crop.height * model.zoom)); view.needsDisplay = true
    }
}

struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.tool) { ForEach(CaptureTool.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 155)
                ColorPicker(L10n.text("capture.editor.color"), selection: Binding(get: { Color(model.color.nsColor) }, set: { model.setColor(CaptureColor(NSColor($0))) })).labelsHidden().frame(width: 30)
                Text(L10n.text("capture.editor.width")); TextField("", value: Binding(get: { model.lineWidth }, set: model.setWidth), format: .number).frame(width: 36)
                Text(L10n.text("capture.editor.font")); TextField("", value: Binding(get: { model.fontSize }, set: model.setFont), format: .number).frame(width: 36)
                TextField(L10n.text("capture.editor.text"), text: Binding(get: { model.text }, set: model.setText)).frame(minWidth: 90)
                Button("↶") { model.undo() }.help(L10n.text("capture.editor.undo")).keyboardShortcut("z", modifiers: .command)
                Button("↷") { model.redo() }.help(L10n.text("capture.editor.redo")).keyboardShortcut("z", modifiers: [.command, .shift])
                Menu("•••") {
                    Button(L10n.text("capture.editor.open")) { model.onOpen?() }
                    Button(L10n.text("capture.editor.sticker")) { model.onSticker?() }
                    Button(L10n.text("capture.editor.duplicate")) { model.duplicateSelection() }.disabled(model.selected.isEmpty)
                    Button(L10n.text("capture.editor.delete")) { model.deleteSelection() }.disabled(model.selected.isEmpty)
                    Button(L10n.text("capture.editor.material")) { model.onMaterial?() }.disabled(model.selected.isEmpty)
                    Button(L10n.text("capture.editor.materials")) { model.onMaterials?() }
                }
            }.padding(10)
            Divider()
            CaptureCanvasHost(model: model)
            Divider()
            HStack {
                Text(L10n.text("capture.editor.zoom")); Slider(value: $model.zoom, in: 0.05...3).frame(width: 100)
                Text("\(Int(model.zoom * 100))%").monospacedDigit()
                Text(model.status.isEmpty ? L10n.text(model.dirty ? "capture.editor.dirty" : "capture.history.saved") : model.status).font(.caption).lineLimit(2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.text("capture.action.ocr")) { model.onOCR?() }
                Button(L10n.text("capture.editor.pin")) { model.onPin?() }
                Button(L10n.text("capture.editor.save")) { model.onSave?() }.keyboardShortcut("s", modifiers: .command)
                Button(L10n.text("capture.editor.copy")) { model.onCopy?() }.buttonStyle(.borderedProminent)
            }.padding(10).disabled(model.busy)
        }.frame(minWidth: 800, minHeight: 460).background(Color(nsColor: .windowBackgroundColor))
    }
}

final class CaptureEditorController: NSWindowController, NSWindowDelegate {
    let model: CaptureEditorModel
    var onClose: (() -> Void)?
    init(document: CaptureDocument, saved: Bool = false) {
        model = CaptureEditorModel(document: document, saved: saved)
        model.zoom = min(1, min(950 / document.crop.width, 620 / document.crop.height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = document.title; window.isReleasedWhenClosed = false; window.tabbingMode = .preferred
        window.contentView = NSHostingView(rootView: CaptureEditorView(model: model))
        super.init(window: window); window.delegate = self; window.center(); model.loadPreview()
    }
    required init?(coder: NSCoder) { fatalError() }
    func present() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = L10n.text("capture.editor.close"); alert.informativeText = L10n.text("capture.editor.closeHint")
        alert.addButton(withTitle: L10n.text("capture.editor.keep")); alert.addButton(withTitle: L10n.text("capture.editor.discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

enum CaptureOCR {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3; request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = true; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

final class CaptureTextController: NSWindowController, NSWindowDelegate {
    let textView = NSTextView()
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?
    init(text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("capture.action.ocr"); window.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = textView
        textView.string = text; textView.isRichText = false; textView.font = .systemFont(ofSize: 16); textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let button = NSButton(title: L10n.text("capture.ocr.copy"), target: nil, action: nil)
        let stack = NSStackView(views: [scroll, button]); stack.orientation = .vertical; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.alignment = .leading; window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -64).isActive = true
        super.init(window: window); window.delegate = self; button.target = self; button.action = #selector(copyText)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copyText() { onCopy?(textView.string) }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
