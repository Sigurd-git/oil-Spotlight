import AppKit
import SwiftUI
import OilFindCore

final class CaptureSettingsModel: ObservableObject {
    static let defaultKeyCode: UInt32 = 21
    static var defaultModifiers: UInt32 { HotKey.carbonModifiers([.command, .shift]) }
    static var defaultCopyModifiers: UInt32 { HotKey.carbonModifiers([.control, .command, .shift]) }
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var actualShortcut: String?
    @Published var shortcutError: String?
    @Published var copyKeyCode: UInt32
    @Published var copyModifiers: UInt32
    @Published var actualCopyShortcut: String?
    @Published var copyShortcutError: String?
    @Published var recording = false
    @Published var recordingCopy = false
    @Published var granted = false
    @Published var enabled: Bool { didSet { configure() } }
    @Published var days: Int { didSet { if !(1...365).contains(days) { days = min(365, max(1, days)) }; configure() } }
    @Published var count: Int { didSet { if !(1...1000).contains(count) { count = min(1000, max(1, count)) }; configure() } }
    let history: CaptureHistory
    var onRegister: ((UInt32, UInt32) -> Bool)?, onSuspend: (() -> Void)?, onRetry: (() -> Void)?, onHistory: (() -> Void)?
    var onRegisterCopy: ((UInt32, UInt32) -> Bool)?
    var onRetryShortcut: (() -> Void)?
    private let defaults: UserDefaults
    private let snapshot: Bool
    private var monitor: Any?
    init(history: CaptureHistory = CaptureHistory(), defaults: UserDefaults = .standard, snapshot: Bool = false) {
        self.history = history; self.defaults = defaults; self.snapshot = snapshot
        keyCode = snapshot ? Self.defaultKeyCode : UInt32(clamping: (defaults.object(forKey: "captureHotKeyCode") as? Int) ?? Int(Self.defaultKeyCode))
        modifiers = snapshot ? Self.defaultModifiers : UInt32(clamping: (defaults.object(forKey: "captureHotKeyModifiers") as? Int) ?? Int(Self.defaultModifiers))
        copyKeyCode = snapshot ? Self.defaultKeyCode : UInt32(clamping: (defaults.object(forKey: "captureCopyHotKeyCode") as? Int) ?? Int(Self.defaultKeyCode))
        copyModifiers = snapshot ? Self.defaultCopyModifiers : UInt32(clamping: (defaults.object(forKey: "captureCopyHotKeyModifiers") as? Int) ?? Int(Self.defaultCopyModifiers))
        enabled = snapshot ? true : (defaults.object(forKey: "captureHistoryEnabled") as? Bool ?? true)
        days = snapshot ? 7 : min(365, max(1, defaults.object(forKey: "captureHistoryDays") as? Int ?? 7))
        count = snapshot ? 100 : min(1000, max(1, defaults.object(forKey: "captureHistoryCount") as? Int ?? 100))
        granted = !snapshot && CGPreflightScreenCaptureAccess()
        history.enabled = enabled; history.retention = .init(days: days, count: count)
    }
    private func configure() {
        guard !snapshot else { return }
        defaults.set(enabled, forKey: "captureHistoryEnabled"); defaults.set(days, forKey: "captureHistoryDays"); defaults.set(count, forKey: "captureHistoryCount")
        history.configure(enabled: enabled, retention: .init(days: days, count: count))
    }
    func refreshPermission(_ value: Bool) { granted = value }
    func status(bound: Bool, copy: Bool = false) {
        if copy {
            actualCopyShortcut = bound ? Shortcut.symbols(keyCode: copyKeyCode, modifiers: copyModifiers) : nil
            copyShortcutError = bound ? nil : L10n.text("capture.shortcut.conflict")
        } else {
            actualShortcut = bound ? Shortcut.symbols(keyCode: keyCode, modifiers: modifiers) : nil
            shortcutError = bound ? nil : L10n.text("capture.shortcut.conflict")
        }
    }
    func startRecording(copy: Bool = false) {
        guard !recording else { return }; recordingCopy = copy; recording = true; onSuspend?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.cancelRecording(); return nil }
            let modifiers = HotKey.carbonModifiers(event.modifierFlags)
            guard modifiers != 0, ![54,55,56,58,59,60,61,62,63].contains(event.keyCode) else { return nil }
            self.acceptShortcut(code: UInt32(event.keyCode), modifiers: modifiers, copy: copy); return nil
        }
    }
    func acceptShortcut(code: UInt32, modifiers: UInt32, copy: Bool) {
        cancelRecording(retry: false)
        if copy { copyKeyCode = code; copyModifiers = modifiers } else { keyCode = code; self.modifiers = modifiers }
        persistShortcut(copy: copy)
        let register = copy ? onRegisterCopy : onRegister
        status(bound: register?(code, modifiers) == true, copy: copy)
        onRetryShortcut?()
    }
    private func persistShortcut(copy: Bool) {
        guard !snapshot else { return }
        defaults.set(Int(copy ? copyKeyCode : keyCode), forKey: copy ? "captureCopyHotKeyCode" : "captureHotKeyCode")
        defaults.set(Int(copy ? copyModifiers : modifiers), forKey: copy ? "captureCopyHotKeyModifiers" : "captureHotKeyModifiers")
    }
    func cancelRecording(retry: Bool = true) {
        guard recording else { return }; recording = false; recordingCopy = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; if retry { onRetryShortcut?() }
    }
    func restoreDefault(copy: Bool = false) {
        acceptShortcut(code: Self.defaultKeyCode, modifiers: copy ? Self.defaultCopyModifiers : Self.defaultModifiers, copy: copy)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct CaptureSettingsSections: View {
    @ObservedObject var model: CaptureSettingsModel
    @ObservedObject var history: CaptureHistory
    @State private var confirmClear = false
    var body: some View {
        Section(L10n.text("capture.shortcut")) {
            HStack {
                Text(L10n.text("capture.shortcut"))
                Spacer()
                Button(model.recording && !model.recordingCopy ? L10n.text("settings.record") : Shortcut.symbols(keyCode: model.keyCode, modifiers: model.modifiers)) { model.startRecording() }.disabled(model.recording)
                Button(L10n.text("capture.shortcut.reset")) { model.restoreDefault() }.disabled(model.recording)
            }
            Text(L10n.text("settings.shortcutCurrent", model.actualShortcut ?? L10n.text("capture.shortcut.inactive"))).font(.caption)
            if let error = model.shortcutError { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Text(L10n.text("capture.shortcut.copy")); Spacer()
                Button(model.recording && model.recordingCopy ? L10n.text("settings.record") : Shortcut.symbols(keyCode: model.copyKeyCode, modifiers: model.copyModifiers)) { model.startRecording(copy: true) }.disabled(model.recording)
                Button(L10n.text("capture.shortcut.reset")) { model.restoreDefault(copy: true) }.disabled(model.recording)
            }
            Text(L10n.text("settings.shortcutCurrent", model.actualCopyShortcut ?? L10n.text("capture.shortcut.inactive"))).font(.caption)
            Text(L10n.text("capture.shortcut.copyHint")).font(.caption).foregroundStyle(.secondary)
            if let error = model.copyShortcutError { Text(error).foregroundStyle(.orange).font(.caption) }
            Button(L10n.text("capture.shortcut.settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?shortcuts")!) }
            Text(L10n.text("capture.shortcut.steps")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("settings.retryHotKey")) { model.onRetryShortcut?() }.disabled(model.recording)
        }
        Section(L10n.text("capture.permission")) {
            Text(L10n.text(model.granted ? "capture.permission.granted" : "capture.permission.notGranted"))
            Button(L10n.text("capture.permission.settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
            Button(L10n.text("capture.permission.retry")) { model.onRetry?() }
        }
        Section(L10n.text("capture.action.history")) {
            Toggle(L10n.text("capture.history.enabled"), isOn: $model.enabled)
            Stepper(L10n.text("settings.clipboardRetentionDays", String(model.days)), value: $model.days, in: 1...365)
            Stepper(L10n.text("settings.clipboardMaxItems", String(model.count)), value: $model.count, in: 1...1000)
            Text(L10n.text("capture.history.policy")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("capture.history.warning")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("capture.history.count", String(history.entries.count), String(history.materials.count)))
            Text(history.pending > 0 ? L10n.text("capture.history.pending") : history.error ?? L10n.text("capture.history.saved")).font(.caption).foregroundStyle(history.error == nil ? Color.secondary : Color.red)
            if history.error != nil { Button(L10n.text("capture.history.retry")) { history.retry() } }
            Button(L10n.text("capture.action.history")) { model.onHistory?() }
            Button(L10n.text("capture.history.clear")) { confirmClear = true }.disabled(history.entries.isEmpty)
        }
        .confirmationDialog(L10n.text("capture.history.clear"), isPresented: $confirmClear) { Button(L10n.text("capture.history.clear"), role: .destructive) { history.remove(nil) } }
    }
}
