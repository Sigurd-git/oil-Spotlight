import AppKit
import ApplicationServices
import os

enum PasteOutcome: String { case sent, copiedOnly, permissionRequired, clipboardChanged, cancelled }

struct ClipboardPasteTarget {
    let processIdentifier: pid_t
    let bundleID: String?
    let launchDate: Date?
    let focusedElement: AXUIElement?

    init(processIdentifier: pid_t, bundleID: String? = nil, launchDate: Date? = nil,
         focusedElement: AXUIElement? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleID = bundleID
        self.launchDate = launchDate
        self.focusedElement = focusedElement
    }
}

protocol ClipboardPasteAdapting: AnyObject {
    var hasPermission: Bool { get }
    func captureTarget() -> ClipboardPasteTarget?
    func isRunning(_ target: ClipboardPasteTarget) -> Bool
    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void)
    func hasFocus(_ target: ClipboardPasteTarget) -> Bool
    func paste(to target: ClipboardPasteTarget, isClipboardCurrent: () -> Bool) -> PasteOutcome
}

final class ClipboardSystemPasteAdapter: ClipboardPasteAdapting {
    private enum FocusState { case waiting, restored, changed }
    private lazy var accessibility: AXUIElement = {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        return system
    }()

    // Passive checks only. A user can grant accessibility access in System Settings.
    var hasPermission: Bool { AXIsProcessTrusted() }

    func captureTarget() -> ClipboardPasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, app.activationPolicy == .regular else { return nil }
        let focus = hasPermission ? focusedElement() : nil
        return ClipboardPasteTarget(processIdentifier: app.processIdentifier, bundleID: app.bundleIdentifier,
                                    launchDate: app.launchDate, focusedElement: focus?.pid == app.processIdentifier ? focus?.element : nil)
    }

    func isRunning(_ target: ClipboardPasteTarget) -> Bool {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              !app.isTerminated, app.activationPolicy == .regular else { return false }
        // Launch date also protects against reuse of a PID by the same application.
        return app.bundleIdentifier == target.bundleID && app.launchDate == target.launchDate
    }

    func activate(_ target: ClipboardPasteTarget, completion: @escaping (Bool) -> Void) {
        guard isRunning(target), let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            completion(false); return
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostPID == ProcessInfo.processInfo.processIdentifier {
            guard app.activate(options: []) else { completion(false); return }
        } else if let frontmostPID, frontmostPID != target.processIdentifier {
            completion(false); return
        }
        // A nonactivating panel can still hold keyboard focus after orderOut,
        // even when the destination app is already active.
        let deadline = DispatchTime.now() + .milliseconds(600)
        DispatchQueue.main.async { self.waitForFocus(target, until: deadline, completion: completion) }
    }

    func hasFocus(_ target: ClipboardPasteTarget) -> Bool {
        focusState(target) == .restored
    }

    private func waitForFocus(_ target: ClipboardPasteTarget, until deadline: DispatchTime, completion: @escaping (Bool) -> Void) {
        guard DispatchTime.now() < deadline else { completion(false); return }
        switch focusState(target) {
        case .restored: completion(true)
        case .changed: completion(false)
        case .waiting:
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
                self.waitForFocus(target, until: deadline, completion: completion)
            }
        }
    }

    private func focusState(_ target: ClipboardPasteTarget) -> FocusState {
        guard hasPermission, isRunning(target) else { return .changed }
        guard let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              activePID != ProcessInfo.processInfo.processIdentifier else { return .waiting }
        guard activePID == target.processIdentifier else { return .changed }
        guard let (element, pid) = focusedElement(), pid != ProcessInfo.processInfo.processIdentifier else { return .waiting }
        guard pid == target.processIdentifier else { return .changed }
        if let original = target.focusedElement, !CFEqual(original, element) { return .changed }
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let value = enabled as? Bool, !value { return .changed }
        return .restored
    }

    private func focusedElement() -> (element: AXUIElement, pid: pid_t)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(accessibility, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focused = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else { return nil }
        return (focused, pid)
    }

    func paste(to target: ClipboardPasteTarget, isClipboardCurrent: () -> Bool) -> PasteOutcome {
        if CGPreflightPostEventAccess() {
            return sendCommandV(to: target, isClipboardCurrent: isClipboardCurrent)
        }
        AppLog.logger.info("clipboard paste keyboard event access unavailable")
        guard let item = pasteMenuItem(in: target), hasFocus(target) else { return .copiedOnly }
        var pid: pid_t = 0
        guard AXUIElementGetPid(item, &pid) == .success, pid == target.processIdentifier else { return .copiedOnly }
        guard isClipboardCurrent() else { return .clipboardChanged }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        AppLog.logger.info("clipboard paste menu action status=\(result.rawValue, privacy: .public)")
        // A timed-out action may still have run. Do not dispatch it a second time.
        if result == .success || result == .cannotComplete { return .sent }
        return result == .apiDisabled ? .permissionRequired : .copiedOnly
    }

    private func sendCommandV(to target: ClipboardPasteTarget, isClipboardCurrent: () -> Bool) -> PasteOutcome {
        guard hasFocus(target), let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .copiedOnly }
        guard isClipboardCurrent() else { return .clipboardChanged }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        AppLog.logger.info("clipboard paste sent targeted keyboard event")
        return .sent
    }

    private func pasteMenuItem(in target: ClipboardPasteTarget) -> AXUIElement? {
        let deadline = DispatchTime.now() + .milliseconds(300)
        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard let value = attribute(kAXMenuBarAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let bar = value as! AXUIElement
        var paste: AXUIElement?
        for top in children(of: bar) {
            guard DispatchTime.now() < deadline else { return nil }
            guard let title = attribute(kAXTitleAttribute, of: top) as? String,
                  ["Edit", "编辑", "編輯"].contains(title) else { continue }
            for menu in children(of: top) {
                for item in children(of: menu) {
                    guard DispatchTime.now() < deadline else { return nil }
                    guard let key = attribute(kAXMenuItemCmdCharAttribute, of: item) as? String, key.lowercased() == "v",
                          let modifiers = attribute(kAXMenuItemCmdModifiersAttribute, of: item) as? NSNumber,
                          let title = attribute(kAXTitleAttribute, of: item) as? String,
                          Self.isPasteMenuCommand(title: title, modifiers: modifiers.intValue),
                          attribute(kAXEnabledAttribute, of: item) as? Bool == true else { continue }
                    guard paste == nil else { return nil }
                    paste = item
                }
            }
        }
        return paste
    }

    static func isPasteMenuCommand(title: String, modifiers: Int) -> Bool {
        // AX menu shortcuts include Command unless the no-Command bit is set.
        guard modifiers == 0 else { return false }
        if ["Paste", "Paste Item", "Paste Items"].contains(title) { return true }
        return title.range(of: #"^(?:Paste [0-9]+ Items?|(?:粘贴|粘貼|黏贴|黏貼|貼上)(?:\s*(?:[0-9]+\s*[个個]\s*)?[项項]目)?)$"#,
                           options: .regularExpression) != nil
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 64, &children) == .success
        else { return [] }
        return children as? [AXUIElement] ?? []
    }
}

// Main-thread integration: capture immediately before showing the panel. The
// caller copies the selected entry first; this controller never reads clipboard data.
final class ClipboardPasteController {
    typealias FailureDeadline = (@escaping () -> Void) -> (() -> Void)
    private let adapter: ClipboardPasteAdapting
    private let snapshot: Bool
    private let scheduleFailureDeadline: FailureDeadline
    private var target: ClipboardPasteTarget?
    private var finishPendingPaste: ((PasteOutcome) -> Void)?

    init(snapshot: Bool = false, adapter: ClipboardPasteAdapting? = nil,
         scheduleFailureDeadline: @escaping FailureDeadline = { failure in
             // A failure deadline, never a delay or authorization to send keys.
             let timer = Timer(timeInterval: 1.75, repeats: false) { _ in failure() }
             RunLoop.main.add(timer, forMode: .common)
             return { timer.invalidate() }
         }) {
        self.snapshot = snapshot
        self.adapter = adapter ?? ClipboardSystemPasteAdapter()
        self.scheduleFailureDeadline = scheduleFailureDeadline
    }

    func captureTarget() {
        guard !snapshot else { return }
        finishPendingPaste?(.cancelled)
        target = adapter.captureTarget()
    }

    func pasteCurrentClipboard(isClipboardCurrent: @escaping () -> Bool = { true },
                               hidePanel: (@escaping () -> Void) -> Void,
                               completion: @escaping (PasteOutcome) -> Void) {
        guard finishPendingPaste == nil else { completion(.cancelled); return }
        let captured = target
        target = nil
        var finished = false, hidden = false, activated = false
        var cancelDeadline: (() -> Void)?
        let finish: (PasteOutcome) -> Void = { [weak self] outcome in
            guard !finished else { return }
            finished = true
            cancelDeadline?()
            cancelDeadline = nil
            self?.finishPendingPaste = nil
            if self?.snapshot == false {
                AppLog.logger.info("clipboard paste result=\(outcome.rawValue, privacy: .public)")
            }
            completion(outcome)
        }
        finishPendingPaste = finish
        cancelDeadline = scheduleFailureDeadline { [weak self] in
            guard self?.snapshot == false else { finish(.copiedOnly); return }
            finish(isClipboardCurrent() ? .copiedOnly : .clipboardChanged)
        }
        // Also tolerate an injected scheduler firing synchronously.
        guard !finished else { cancelDeadline?(); cancelDeadline = nil; return }
        guard snapshot || isClipboardCurrent() else { finish(.clipboardChanged); return }
        hidePanel { [weak self] in
            guard !finished, !hidden else { return }
            hidden = true
            guard let self, !self.snapshot, let captured else { finish(.copiedOnly); return }
            guard isClipboardCurrent() else { finish(.clipboardChanged); return }
            guard self.adapter.hasPermission else { finish(.permissionRequired); return }
            guard self.adapter.isRunning(captured) else { finish(.copiedOnly); return }
            self.adapter.activate(captured) { [weak self] success in
                guard !finished, !activated else { return }
                activated = true
                guard let self else { finish(.copiedOnly); return }
                guard isClipboardCurrent() else { finish(.clipboardChanged); return }
                guard self.adapter.hasPermission else { finish(.permissionRequired); return }
                guard success, self.adapter.isRunning(captured), self.adapter.hasFocus(captured) else { finish(.copiedOnly); return }
                guard isClipboardCurrent() else { finish(.clipboardChanged); return }
                finish(self.adapter.paste(to: captured, isClipboardCurrent: isClipboardCurrent))
            }
        }
    }
}
