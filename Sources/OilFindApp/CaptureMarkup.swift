import AppKit

enum CaptureMarkupOutput { case copy, save, editor }

struct CaptureMarkupSubmission {
    let selection: CaptureSelection
    let size: CGSize
    let annotations: [CaptureAnnotation]
    let output: CaptureMarkupOutput

    func annotations(in pixelSize: CGSize) -> [CaptureAnnotation] {
        let sx = pixelSize.width / size.width
        let sy = pixelSize.height / size.height
        let scale = min(sx, sy)
        let transform = CGAffineTransform(scaleX: sx, y: sy)
        return annotations.map { annotation in
            var item = annotation
            item.rect = annotation.rect.applying(transform)
            item.points = annotation.points.map { $0.applying(transform) }
            item.lineWidth = max(1, annotation.lineWidth * scale)
            item.fontSize = max(6, annotation.fontSize * scale)
            return item
        }
    }
}

struct CaptureMarkup {
    static let textSize: CGFloat = 19
    private(set) var annotations: [CaptureAnnotation] = []
    private var undone: [CaptureAnnotation] = []
    private(set) var stroke: CaptureAnnotation?
    var tool = CaptureTool.select
    var color = CaptureColor()
    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    // Points are relative to the top-left corner of the selection, in screen points.
    mutating func beginStroke(at point: CGPoint) {
        stroke = CaptureAnnotation(tool: tool, rect: CGRect(origin: point, size: .zero), points: [point], color: color)
    }

    mutating func updateStroke(to point: CGPoint) {
        guard var item = stroke, let start = item.points.first else { return }
        if item.tool == .pen {
            guard item.points.last != point, item.points.count < 4_096 else { return }
            item.points.append(point)
            item.rect = item.rect.union(CGRect(origin: point, size: .zero))
        } else {
            item.rect = CGRect.between(start, point)
            item.points = [start, point]
        }
        stroke = item
    }

    mutating func endStroke(at point: CGPoint) {
        updateStroke(to: point)
        guard let item = stroke else { return }
        stroke = nil
        switch item.tool {
        case .arrow, .pen:
            guard hypot(item.rect.width, item.rect.height) >= 2 else { return }
        default:
            guard item.rect.width >= 2, item.rect.height >= 2 else { return }
        }
        append(item)
    }
    mutating func cancelStroke() { stroke = nil }

    mutating func addText(_ text: String, in rect: CGRect) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(CaptureAnnotation(tool: .text, rect: rect, color: color, fontSize: Self.textSize, text: text))
    }

    private mutating func append(_ item: CaptureAnnotation) {
        guard item.valid, annotations.count < 10_000 else { return }
        annotations.append(item)
        undone.removeAll()
    }

    mutating func undo() {
        if let item = annotations.popLast() { undone.append(item) }
    }

    mutating func redo() {
        if let item = undone.popLast() { annotations.append(item) }
    }
}
