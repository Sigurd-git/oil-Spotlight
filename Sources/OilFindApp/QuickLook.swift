import AppKit
import Quartz

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var selectedURL: (() -> URL?)?
    var onKey: ((NSEvent) -> Bool)?
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func toggle() {
        if isVisible { close() }
        else if selectedURL?() != nil { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    }
    func close() { if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) } }
    func begin(_ panel: QLPreviewPanel) { panel.dataSource = self; panel.delegate = self }
    func end(_ panel: QLPreviewPanel) { panel.dataSource = nil; panel.delegate = nil }
    func refresh() { if isVisible { QLPreviewPanel.shared().reloadData() } }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURL?() as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 { return onKey?(event) ?? false }
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "y") {
            close(); return true
        }
        if [125, 126, 116, 121, 115, 119].contains(event.keyCode) {
            let handled = onKey?(event) ?? false; refresh(); return handled
        }
        return false
    }
}
