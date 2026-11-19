import AppKit

final class CaptureMarkupToolbar: NSVisualEffectView {
    private let tools: NSStackView
    private let actions: NSStackView
    private let rows: NSStackView
    private let palette: NSStackView
    private let content: NSStackView
    private let toolButtons: [CaptureTool: CaptureMarkupButton]
    private let colorButtons: [(CaptureColor, CaptureMarkupButton)]
    private let undoButton: CaptureMarkupButton
    private let redoButton: CaptureMarkupButton

    init(chooseTool: @escaping (CaptureTool) -> Void, chooseColor: @escaping (CaptureColor) -> Void,
         undo: @escaping () -> Void, redo: @escaping () -> Void, reselect: @escaping () -> Void,
         cancel: @escaping () -> Void, finish: @escaping (CaptureMarkupOutput) -> Void) {
        let items: [(CaptureTool, String)] = [
            (.rectangle, "rectangle"), (.ellipse, "circle"), (.arrow, "arrow.up.right"),
            (.pen, "pencil.line"), (.text, "textformat"), (.redact, "eye.slash"),
        ]
        let pairs = items.map { tool, symbol in
            (tool, CaptureMarkupButton(tool.title, symbol: symbol) { chooseTool(tool) })
        }
        toolButtons = Dictionary(uniqueKeysWithValues: pairs)
        tools = Self.stack(pairs.map(\.1), spacing: 3)

        let colors: [(String, CaptureColor)] = [
            ("red", CaptureColor()),
            ("yellow", CaptureColor(red: 1, green: 0.78, blue: 0.14)),
            ("green", CaptureColor(red: 0.24, green: 0.78, blue: 0.42)),
            ("blue", CaptureColor(red: 0.29, green: 0.62, blue: 1)),
            ("white", CaptureColor(red: 1, green: 1, blue: 1)),
            ("black", CaptureColor(red: 0.11, green: 0.11, blue: 0.11)),
        ]
        colorButtons = colors.map { name, color in
            let button = CaptureMarkupButton(L10n.text("capture.color." + name), symbol: "circle.fill", size: 16) { chooseColor(color) }
            button.contentTintColor = color.nsColor
            return (color, button)
        }
        palette = Self.stack(colorButtons.map(\.1), spacing: 2)

        undoButton = CaptureMarkupButton(L10n.text("capture.editor.undo"), symbol: "arrow.uturn.backward", action: undo)
        redoButton = CaptureMarkupButton(L10n.text("capture.editor.redo"), symbol: "arrow.uturn.forward", action: redo)
        let reset = CaptureMarkupButton(L10n.text("capture.editor.reselect"), symbol: "viewfinder", action: reselect)
        let editor = CaptureMarkupButton(L10n.text("capture.overlay.editor"), symbol: "slider.horizontal.3") { finish(.editor) }
        let save = CaptureMarkupButton(L10n.text("capture.editor.save"), symbol: "square.and.arrow.down") { finish(.save) }
        let close = CaptureMarkupButton(L10n.text("action.cancel"), symbol: "xmark", action: cancel)
        let copy = CaptureMarkupButton(L10n.text("capture.overlay.copy"), prominent: true) { finish(.copy) }
        reset.toolTip = L10n.text("capture.editor.reselect") + " (R)"
        save.toolTip = L10n.text("capture.editor.save") + " (⌘S)"
        close.toolTip = L10n.text("action.cancel") + " (Esc)"
        copy.toolTip = L10n.text("capture.overlay.copyHelp")
        actions = Self.stack([undoButton, redoButton, reset, editor, save, close, copy], spacing: 3)

        rows = Self.stack([tools, actions], spacing: 15)
        content = Self.stack([rows, palette], spacing: 4, orientation: .vertical)
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(from markup: CaptureMarkup, availableWidth: CGFloat) -> CGSize {
        for (tool, button) in toolButtons { button.isSelected = tool == markup.tool }
        for (color, button) in colorButtons { button.isSelected = color == markup.color }
        undoButton.isEnabled = markup.canUndo
        redoButton.isEnabled = markup.canRedo
        palette.isHidden = markup.tool == .select || markup.tool == .redact
        let wraps = tools.fittingSize.width + actions.fittingSize.width + 31 > availableWidth
        rows.orientation = wraps ? .vertical : .horizontal
        rows.alignment = wraps ? .leading : .centerY
        rows.spacing = wraps ? 4 : 15
        let size = content.fittingSize
        return CGSize(width: size.width + 16, height: size.height + 14)
    }

    private static func stack(_ views: [NSView], spacing: CGFloat, orientation: NSUserInterfaceLayoutOrientation = .horizontal) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = orientation == .horizontal ? .centerY : .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }
}

private final class CaptureMarkupButton: NSButton {
    private let prominent: Bool
    private let callback: () -> Void
    var isSelected = false { didSet { updateBackground() } }

    init(_ label: String, symbol: String? = nil, size: CGFloat = 14, prominent: Bool = false, action: @escaping () -> Void) {
        self.prominent = prominent
        callback = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(performAction)
        isBordered = false
        refusesFirstResponder = true
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
            imagePosition = .imageOnly
        } else {
            title = label
            font = .systemFont(ofSize: 13, weight: .semibold)
        }
        contentTintColor = .white
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        widthAnchor.constraint(equalToConstant: prominent ? 68 : 29).isActive = true
        heightAnchor.constraint(equalToConstant: 29).isActive = true
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateBackground()
    }

    private func updateBackground() {
        if prominent {
            layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.37, blue: 0.78, alpha: isHighlighted ? 0.76 : 1).cgColor
        } else {
            layer?.backgroundColor = NSColor(white: 1, alpha: isHighlighted || isSelected ? 0.19 : 0).cgColor
        }
    }

    @objc private func performAction() { callback() }
}
