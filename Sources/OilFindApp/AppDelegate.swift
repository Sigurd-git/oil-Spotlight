import AppKit
import Carbon
import ServiceManagement
import os
import OilFindCore

enum AppLog {
    static let logger = Logger(subsystem: "com.oiloil.find", category: "app")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let externalDrives: ExternalDriveCatalog
    private let appExtension: ApplicationExtension?
    init(appExtension: ApplicationExtension? = nil, externalDrives: ExternalDriveCatalog = ExternalDriveCatalog()) {
        self.externalDrives = externalDrives
        self.appExtension = appExtension
        super.init()
    }
    private let panel = SearchPanel()
    private let topics = AITopicManager()
    private lazy var topicSearch = AITopicSearchProvider(manager: topics)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsItem: NSMenuItem?, extensionItem: NSMenuItem?
    private var localizedMenuItems: [(String, NSMenuItem)] = []
    private var languageObserver: NSObjectProtocol?
    private var hotKey: HotKey?
    private var captureHotKey: HotKey?
    private var captureCopyHotKey: HotKey?
    private lazy var capture = CaptureCoordinator(clipboard: panel.searchController.clipboard)
    private var actualKeyCode: UInt32?, actualModifiers: UInt32?
    private var shortcutRetryObserver: NSObjectProtocol?
    private var manager: IndexManager?
    private var settingsController: SettingsWindowController?
    private var updateItem: NSMenuItem?, checkUpdateItem: NSMenuItem?, quitItem: NSMenuItem?
    private var secondaryInstance = false
    private var openItem: NSMenuItem?, hotKeyFailureItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var welcomeController: WelcomeWindowController?
    private var welcomeState: WelcomeState?
    private var indexStateStartedAt = ProcessInfo.processInfo.systemUptime
    private var limited = false
    private var countItem: NSMenuItem?, limitedItem: NSMenuItem?, loginItem: NSMenuItem?, rescanItem: NSMenuItem?
    static let dbURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oil Find/index.oilfind")
    private static let showRequest = Notification.Name("com.oiloil.find.show")
    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyAuthorizationCleanup.run()
        DispatchQueue.global(qos: .utility).async { _ = Pinyin.shared }
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            secondaryInstance = true
            DistributedNotificationCenter.default().postNotificationName(Self.showRequest, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        UpdateManager.shared.start()
        UpdateManager.shared.onChange = { [weak self] in self?.refreshUpdateMenu() }
        NSApp.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenRequested(_:)), name: Self.showRequest, object: nil)
        let defaults = UserDefaults.standard
        let key = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        let modifiers = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        _ = registerHotKey(keyCode: key, modifiers: modifiers)
        buildMenu(keyCode: key, modifiers: modifiers)
        capture.hideSearch = { [weak self] in self?.panel.hide(source: .interaction) }
        capture.showSettings = { [weak self] in self?.presentSettings(section: .capture) }
        capture.settings.onSuspend = { [weak self] in
            self?.captureHotKey?.unregister(); self?.captureHotKey = nil; self?.capture.settings.actualShortcut = nil
            self?.captureCopyHotKey?.unregister(); self?.captureCopyHotKey = nil; self?.capture.settings.actualCopyShortcut = nil
        }
        capture.settings.onRegister = { [weak self] in self?.registerCaptureHotKey(code: $0, modifiers: $1) ?? false }
        capture.settings.onRegisterCopy = { [weak self] in self?.registerCaptureCopyHotKey(code: $0, modifiers: $1) ?? false }
        capture.settings.onRetryShortcut = { [weak self] in self?.retryCaptureHotKey() }
        retryCaptureHotKey()
        panel.searchController.onCaptureAction = { [weak self] in self?.capture.run($0) }
        panel.searchController.onEditClipboardImage = { [weak self] image, action in
            self?.panel.hide(source: .interaction); self?.capture.openClipboardImage(image, recognize: action == .ocr, pin: action == .pin)
        }
        panel.searchController.supplementaryProvider = appExtension?.supplementarySearchProvider
        panel.searchController.additionalSearchProvider = topicSearch
        topics.start()
        panel.searchController.additionalSources = { [weak self] in (self?.externalDrives.searchSources() ?? []) + (self?.appExtension?.searchSources() ?? []) }
        let sourcesChanged: () -> Void = { [weak self] in
            self?.panel.searchController.sourcesChanged()
            self?.settingsController?.model.refresh()
        }
        externalDrives.onSourcesChange = sourcesChanged
        appExtension?.onSearchSourcesChange = sourcesChanged
        appExtension?.attachExternalDrives(externalDrives)
        externalDrives.start()
        appExtension?.start(chinese: L10n.chinese, showSettings: { [weak self] in self?.presentSettings(section: .index) })
        updateShortcutStatus()
        shortcutRetryObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settingsController?.model.recording != true else { return }
            let wanted = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
            let mask = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
            if self.actualKeyCode != wanted || self.actualModifiers != mask { self.retryHotKey() }
            if !self.capture.settings.recording && (self.captureHotKey == nil || self.captureCopyHotKey == nil) { self.retryCaptureHotKey() }
            self.capture.settings.refreshPermission(self.capture.backend.hasPermission)
        }
        panel.searchController.onSettings = { [weak self] in self?.showSettings() }
        panel.searchController.startSources()
        let fullDiskAccess = Permissions.hasFullDiskAccess()
        var state = WelcomeState(didFinishOnboarding: defaults.bool(forKey: "didFinishOnboarding"), skippedFullDiskAccess: defaults.bool(forKey: "skippedFullDiskAccess"), granted: fullDiskAccess)
        let indexRequest = state.launch()
        welcomeState = state
        AppLog.logger.info("launch hotkeyRegistered=\(self.hotKey != nil, privacy: .public) granted=\(fullDiskAccess, privacy: .public) welcome=\(state.isShowing, privacy: .public)")
        if state.isShowing {
            let controller = WelcomeWindowController(granted: fullDiskAccess)
            welcomeController = controller
            updateShortcutStatus()
            controller.model.onStart = { [weak self] in self?.finishWelcome() }
            controller.model.onSettings = { [weak self] in self?.showSettings() }
            controller.present()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let granted = Permissions.hasFullDiskAccess()
                self.welcomeController?.model.granted = granted
                if granted { self.welcomeController?.model.waiting = false }
                if let limited = self.welcomeState?.permissionDetected(granted) { self.startIndex(limited: limited) }
            }
        }
        if let limited = indexRequest { startIndex(limited: limited) }
        if let failure = SystemUpdateFiles().cleanupAfterLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current) {
            UpdateManager.shared.reportLaunchFailure(failure)
        }
    }
    private func finishWelcome(source: PanelSource = .welcome) {
        guard welcomeState?.isShowing == true else { return }
        let detected = welcomeState?.permissionDetected(Permissions.hasFullDiskAccess())
        let finished = welcomeState?.finish()
        let request = detected ?? finished
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "didFinishOnboarding")
        defaults.set(welcomeState?.skippedFullDiskAccess == true, forKey: "skippedFullDiskAccess")
        permissionTimer?.invalidate(); permissionTimer = nil
        welcomeController?.finish(); welcomeController = nil
        if let limited = request { startIndex(limited: limited) }
        panel.show(source: source)
    }
    private func handleHotKey() {
        if welcomeState?.isShowing == true { finishWelcome(source: .hotkey) }
        else { panel.toggle(source: .hotkey) }
    }

    private func startIndex(limited: Bool) {
        guard manager == nil else { return }
        self.limited = limited
        let manager = IndexManager(config: SettingsPreferences.indexConfig(limited: limited), dbURL: Self.dbURL)
        self.manager = manager; panel.searchController.manager = manager
        settingsController?.model.manager = manager
        panel.searchController.searchField.focus()
        indexStateStartedAt = ProcessInfo.processInfo.systemUptime
        manager.onStateChange = { [weak self, weak manager] state in
            guard let self, let manager else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let count = manager.store.map { store in store.read { store.liveCount } } ?? manager.scannedCount
            let name = String(describing: state)
            AppLog.logger.info("index state=\(name, privacy: .public) entries=\(count, privacy: .public) elapsed=\(now - self.indexStateStartedAt, privacy: .public)s")
            self.indexStateStartedAt = now
            self.panel.searchController.managerStateChanged(state)
        }
        manager.onIndexChange = { [weak self] in self?.panel.searchController.indexChanged() }
        manager.start()
    }
    private func buildMenu(keyCode: UInt32, modifiers: UInt32) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Theme.symbol("magnifyingglass", size: 16, weight: .regular); image.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.menu = makeMenu(keyCode: keyCode, modifiers: modifiers, hotKeyAvailable: hotKey != nil)
    }
    func makeMenu(keyCode: UInt32 = Shortcut.defaultKeyCode, modifiers: UInt32 = Shortcut.defaultModifiers, hotKeyAvailable: Bool = true) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        statusMenu = menu
        localizedMenuItems.removeAll()
        extensionItem = nil
        func item(_ key: String, _ action: Selector?, _ equivalent: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: equivalent)
            value.target = self; value.isEnabled = action != nil; menu.addItem(value)
            localizedMenuItems.append((key, value)); return value
        }
        hotKeyFailureItem = item("menu.hotkeyFailed", nil)
        hotKeyFailureItem?.isHidden = hotKeyAvailable
        openItem = item("menu.open", #selector(showSearch), Shortcut.keyEquivalent(keyCode))
        openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(modifiers)
        menu.addItem(.separator())
        for (index, action) in CaptureAction.allCases.enumerated() {
            let entry = item("capture.action." + action.rawValue, #selector(captureAction(_:))); entry.tag = index
        }
        menu.addItem(.separator())
        countItem = item("menu.indexing", nil)
        limitedItem = item("menu.limited", #selector(openPermissions))
        rescanItem = item("menu.rescan", #selector(rescan))
        menu.addItem(.separator())
        loginItem = item("menu.loginItem", #selector(toggleLogin))
        settingsItem = item("menu.settings", #selector(showSettings), ",")
        refreshExtensionMenu()
        checkUpdateItem = item("update.check", #selector(checkUpdates))
        updateItem = item("update.check", #selector(presentUpdate))
        refreshUpdateMenu()
        menu.addItem(.separator()); quitItem = item("menu.quit", #selector(quit), "q")
        appExtension?.onSettingsMenuItemChange = { [weak self] in self?.refreshExtensionMenu() }
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
                self?.appExtension?.languageDidChange(chinese: L10n.chinese)
                self?.localizeMenu()
            }
        }
        return menu
    }
    private func localizeMenu() {
        for (key, item) in localizedMenuItems { item.title = L10n.text(key) }
        if let menu = statusMenu { menuWillOpen(menu) }
        refreshUpdateMenu()
    }
    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        hotKey?.unregister()
        hotKey = nil; actualKeyCode = nil; actualModifiers = nil
        if !SpotlightShortcut.isReserved(keyCode: keyCode, modifiers: modifiers),
            captureHotKey?.uses(keyCode: keyCode, modifiers: modifiers) != true, captureCopyHotKey?.uses(keyCode: keyCode, modifiers: modifiers) != true {
            hotKey = HotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in self?.handleHotKey() }
        }
        let requestedRegistered = hotKey != nil
        if requestedRegistered { actualKeyCode = keyCode; actualModifiers = modifiers }
        else if keyCode == Shortcut.defaultKeyCode && modifiers == Shortcut.defaultModifiers,
                !SpotlightShortcut.isReserved(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers),
                captureHotKey?.uses(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers) != true,
                captureCopyHotKey?.uses(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers) != true {
            hotKey = HotKey(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers) { [weak self] in self?.handleHotKey() }
            if hotKey != nil { actualKeyCode = Shortcut.fallbackKeyCode; actualModifiers = Shortcut.fallbackModifiers }
        }
        updateShortcutStatus(clearErrorWhenBound: requestedRegistered)
        return requestedRegistered
    }
    @objc private func captureAction(_ sender: NSMenuItem) {
        guard CaptureAction.allCases.indices.contains(sender.tag) else { return }; capture.run(CaptureAction.allCases[sender.tag])
    }
    private func registerCaptureHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        captureHotKey?.unregister(); captureHotKey = nil
        if !SpotlightShortcut.isReserved(keyCode: code, modifiers: modifiers), hotKey?.uses(keyCode: code, modifiers: modifiers) != true,
            captureCopyHotKey?.uses(keyCode: code, modifiers: modifiers) != true {
            captureHotKey = HotKey(keyCode: code, modifiers: modifiers, identifier: .capture) { [weak self] in self?.capture.run(.region) }
        }
        capture.settings.status(bound: captureHotKey != nil); return captureHotKey != nil
    }
    private func registerCaptureCopyHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        captureCopyHotKey?.unregister(); captureCopyHotKey = nil
        if !SpotlightShortcut.isReserved(keyCode: code, modifiers: modifiers), hotKey?.uses(keyCode: code, modifiers: modifiers) != true,
            captureHotKey?.uses(keyCode: code, modifiers: modifiers) != true {
            captureCopyHotKey = HotKey(keyCode: code, modifiers: modifiers, identifier: .captureCopy) { [weak self] in self?.capture.run(.copyRegion) }
        }
        capture.settings.status(bound: captureCopyHotKey != nil, copy: true); return captureCopyHotKey != nil
    }
    private func retryCaptureHotKey() {
        _ = registerCaptureHotKey(code: capture.settings.keyCode, modifiers: capture.settings.modifiers)
        _ = registerCaptureCopyHotKey(code: capture.settings.copyKeyCode, modifiers: capture.settings.copyModifiers)
    }
    private func updateShortcutStatus(clearErrorWhenBound: Bool = false) {
        let defaults = UserDefaults.standard
        let desired = UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        let modifiers = UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        hotKeyFailureItem?.isHidden = actualKeyCode == desired && actualModifiers == modifiers
        if hotKey != nil {
            openItem?.keyEquivalent = Shortcut.keyEquivalent(actualKeyCode!)
            openItem?.keyEquivalentModifierMask = HotKey.modifierFlags(actualModifiers!)
            welcomeController?.model.updateShortcut(actualKeyCode!, actualModifiers!)
        } else { openItem?.keyEquivalent = "" }
        settingsController?.model.updateShortcutStatus(keyCode: actualKeyCode, modifiers: actualModifiers,
                                                      clearErrorWhenBound: clearErrorWhenBound)
    }
    private func retryHotKey() {
        let defaults = UserDefaults.standard
        _ = registerHotKey(keyCode: UInt32(clamping: defaults.integer(forKey: "hotKeyCode")), modifiers: UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers")))
    }
    @objc func showSettings() { presentSettings() }
    private func presentSettings(section: SettingsSection? = nil) {
        panel.hide(source: .settings)
        NSApp.activate(ignoringOtherApps: true)
        if settingsController == nil {
            let model = SettingsModel(clipboard: panel.searchController.clipboard, capture: capture.settings); model.manager = manager
            model.suspendHotKey = { [weak self] in
                self?.hotKey?.unregister(); self?.hotKey = nil
                self?.actualKeyCode = nil; self?.actualModifiers = nil; self?.updateShortcutStatus()
            }
            model.registerHotKey = { [weak self] code, mask in
                let registered = self?.registerHotKey(keyCode: code, modifiers: mask) ?? false
                DispatchQueue.main.async { [weak self] in self?.updateShortcutStatus() }
                return registered
            }
            model.onConfigChange = { [weak self] in
                guard let self else { return }
                self.manager?.updateConfig(SettingsPreferences.indexConfig(limited: self.limited))
                self.panel.searchController.applications.refresh(excludedPaths: UserDefaults.standard.stringArray(forKey: "userExcludedPaths") ?? [])
            }
            model.onPinyinChange = { [weak self] in self?.panel.searchController.startSearch(preserveSelection: true) }
            model.onRetryHotKey = { [weak self] in self?.retryHotKey() }
            settingsController = SettingsWindowController(model: model, appExtension: appExtension, externalDrives: externalDrives)
        }
        if let section { settingsController?.model.section = section }
        settingsController?.present()
        updateShortcutStatus()
    }
    func menuWillOpen(_ menu: NSMenu) {
        refreshExtensionMenu()
        refreshUpdateMenu()
        if let store = manager?.store { countItem?.title = L10n.text("menu.indexed", Presentation.countText(store.read { store.liveCount })) }
        else { countItem?.title = L10n.text("menu.indexing") }
        limitedItem?.isHidden = !limited
        rescanItem?.isEnabled = manager?.state == .ready && manager?.isRescanning == false
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    private func refreshExtensionMenu() {
        guard let menu = statusMenu, let settingsItem else { return }
        guard let supplied = appExtension?.settingsMenuItem else {
            if let extensionItem { menu.removeItem(extensionItem) }
            extensionItem = nil
            return
        }
        if extensionItem == nil {
            let item = NSMenuItem(title: supplied.title, action: #selector(performExtensionMenuAction), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: menu.index(of: settingsItem) + 1)
            extensionItem = item
        }
        extensionItem?.title = supplied.title
        extensionItem?.isHidden = !supplied.isVisible
    }
    @objc private func performExtensionMenuAction() { appExtension?.settingsMenuItem?.action() }
    private func refreshUpdateMenu() {
        let update = UpdateManager.shared
        checkUpdateItem?.isHidden = !update.supportsAppUpdates
        checkUpdateItem?.isEnabled = update.supportsAppUpdates && update.canCheck
        updateItem?.isHidden = !update.supportsAppUpdates || update.manifest == nil
        updateItem?.title = update.menuTitle
        updateItem?.isEnabled = update.supportsAppUpdates && !update.state.busy
        quitItem?.isEnabled = !update.preventsTermination
    }
    @objc private func checkUpdates() { UpdateManager.shared.check() }
    @objc private func presentUpdate() { UpdateManager.shared.present() }
    @objc private func showSearch() {
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .menu) }
    }
    @objc private func reopenRequested(_ notification: Notification) {
        AppLog.logger.info("reopen requested")
        if welcomeState?.isShowing == true { welcomeController?.present() }
        else { panel.show(source: .reopen) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenRequested(Notification(name: Self.showRequest)); return true
    }
    @objc private func openPermissions() { Permissions.openSettings() }
    @objc private func rescan() { manager?.rescan() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UpdateManager.shared.preventsTermination { return .terminateCancel }
        return capture.prepareToQuit() ? .terminateNow : .terminateCancel
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { appExtension?.handle(url) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if !secondaryInstance {
            panel.searchController.stopSources()
            capture.stop()
            appExtension?.stop()
            externalDrives.stop()
            UpdateManager.shared.stop()
        }
        settingsController?.model.stopRefreshing()
        permissionTimer?.invalidate()
        hotKey?.unregister()
        captureHotKey?.unregister()
        captureCopyHotKey?.unregister()
        manager?.stop()
    }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let shortcutRetryObserver { NSWorkspace.shared.notificationCenter.removeObserver(shortcutRetryObserver) }
    }
}
