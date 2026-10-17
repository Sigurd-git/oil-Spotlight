import AppKit
import Quartz
import Combine
import Darwin
import OilFindCore

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let scopes = ScopeBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let footer = FooterBar(frame: .zero)
    let quickLook = QuickLook()
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let empty = StateView(.empty), indexing = StateView(.indexing)
    let syntax = SyntaxReference(frame: .zero)
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private let snapshot: Bool
    private let preferences: UserDefaults
    private let clock: () -> Date
    private var hiddenAt: Date?
    let applications: ApplicationCatalog
    let clipboard: ClipboardHistory
    let pasteController: ClipboardPasteController
    let currencyRates: CurrencyRateProvider
    var openApplication: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private let coordinator = SearchCoordinator()
    private var subscriptions: Set<AnyCancellable> = []
    private var userNavigated = false, preserveFirstSelection = false
    private var requestedScope = SearchScope.all
    private var clipboardPreview: NSPanel?
    private let clipboardImageIcons = IconProvider()
    private var clipboardActionGeneration = 0
    private var pendingClipboardID: UUID?
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var trashing: Set<URL> = []
    private(set) var browsingResults = false
    var previewWithSpace: Bool { preferences.object(forKey: "previewWithSpace") as? Bool ?? true }
    private func setBrowsing(_ browsing: Bool) {
        browsingResults = browsing
        updateActionHints()
    }
    var manager: IndexManager?
    var supplementaryProvider: SupplementarySearchProvider?
    var additionalSearchProvider: AdditionalSearchProvider? {
        didSet {
            oldValue?.onChange = nil; oldValue?.visibilityChanged(false)
            additionalSearchProvider?.onChange = { [weak self] in self?.additionalChanged() }
            if isViewLoaded { additionalChanged() }
        }
    }
    private var additionalSearchFailed: Bool { coordinator.additionalSearchFailed }
    private func refreshAdditionalFilter() {
        guard isViewLoaded else { return }
        filters.additionalTitle = additionalSearchProvider?.isEnabled == true ? additionalSearchProvider?.title : nil
        searchField.placeholder = scopes.scope == .files && filters.additionalSelected ? additionalSearchProvider?.placeholder : nil
    }
    private func additionalChanged() {
        refreshAdditionalFilter()
        results.cancelPendingRefresh(); results.cancelPress()
        if let provider = additionalSearchProvider {
            coordinator.pruneAdditional(using: provider)
            if let filtered = results.result?.removingUnavailableAdditionalItems(using: provider, options: filters.options) {
                replaceFilePresentation(filtered, applyingAvailabilityImmediately: true)
            }
        }
        if view.window?.isVisible == true { startSearch(preserveSelection: true) }
    }
    var additionalSources: (() -> [SearchSource])?
    private var searchSources: [SearchSource] {
        let primary = manager?.store.map { SearchSource(id: "startup", displayName: "", isOnline: true, store: $0) }
        return primary.map { [$0] + (additionalSources?() ?? []) } ?? (additionalSources?() ?? [])
    }
    func sourcesChanged() {
        refreshAdditionalFilter()
        refreshProgress()
        supplementaryProvider?.sourcesDidChange(searchSources)
        coordinator.cancelFiles(); results.cancelPendingRefresh(); results.cancelPress()
        if supplementaryProvider?.isEnabled != true, let result = results.result, result.hasSupplements {
            let base = result.withoutSupplements()
            replaceFilePresentation(base)
        }
        // Invalidate displayed actions immediately, including while the panel is hidden.
        if results.selectedItem?.source.isOnline != true { quickLook.close() }
        if let presented = results.result, let multi = presented.multiple {
            let current = Set(searchSources.map(\.id))
            if multi.sources.contains(where: { !current.contains($0.id) }) && current.isEmpty {
                replaceFilePresentation(nil)
            }
        }
        results.localize()
        startSearch(preserveSelection: true)
    }
    private func replaceFilePresentation(_ file: SearchPresentation?, applyingAvailabilityImmediately: Bool = false) {
        if let old = results.snapshot {
            let extras = old.leading.filter { row in if case .file = row { return false }; return true }
            let found = SearchCoordinator.compose(raw: old.raw, scope: old.scope, filePresentation: file,
                                                   extras: extras, trailing: old.trailing)
            results.refresh(found, preserveSelection: true, applyingAvailabilityImmediately: applyingAvailabilityImmediately)
        } else if let file {
            let row = results.selectedItem.flatMap { file.index(sourceID: $0.source.id, store: $0.source.store, id: $0.id, path: $0.path) } ?? 0
            present(file, selection: row, resetScroll: false)
        } else {
            results.clear(preservingViewport: true); setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
        }
    }
    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCaptureAction: ((CaptureAction) -> Void)?
    var onEditClipboardImage: ((ClipboardImage, CaptureAction) -> Void)?
    init(snapshot: Bool, preferences: UserDefaults = .standard, clipboard: ClipboardHistory? = nil,
         currencyRates: CurrencyRateProvider? = nil, clock: @escaping () -> Date = Date.init) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.clock = clock
        applications = ApplicationCatalog(snapshot: snapshot)
        self.clipboard = clipboard ?? ClipboardHistory(snapshot: snapshot)
        pasteController = ClipboardPasteController(snapshot: snapshot)
        self.currencyRates = currencyRates ?? CurrencyRateProvider(snapshot: snapshot)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        currencyRates.onChange = { [weak self] in self?.refreshSources() }
        [searchField, topLine, scopes, filters, results, empty, indexing, bottomLine, footer, syntax].forEach(view.addSubview)
        filters.isHidden = true
        scopes.onChange = { [weak self] scope in self?.selectScope(scope) }
        coordinator.onUpdate = { [weak self] found, refresh in
            guard let self else { return }
            if self.additionalSearchFailed { self.footer.warning = true; self.footer.text = L10n.text("search.failed") }
            self.diagnostics = found.filePresentation?.query.diagnostics ?? []
            if self.preserveFirstSelection || refresh && self.userNavigated, let selected = self.results.selectedItem,
               self.results.result?.query.raw == found.raw,
               found.filesPending && found.position(of: "file:" + selected.path, fileID: selected.id,
                                                    store: selected.source.store, sourceID: selected.source.id) == nil { return }
            if self.preserveFirstSelection && self.results.snapshot == nil, let selected = self.results.selectedItem {
                let position = found.position(of: "file:" + selected.path, fileID: selected.id,
                                              store: selected.source.store, sourceID: selected.source.id) ?? 0
                self.results.show(found, selection: position, resetScroll: false); self.snapshotDidChange(found)
            } else if refresh || self.preserveFirstSelection && self.results.snapshot != nil {
                self.results.refresh(found, preserveSelection: self.userNavigated || self.preserveFirstSelection)
            } else {
                self.results.show(found); self.snapshotDidChange(found)
            }
        }
        results.onSnapshotApplied = { [weak self] found in self?.snapshotDidChange(found) }
        applications.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshSources() }.store(in: &subscriptions)
        clipboard.$entries.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.scopes.scope == .clipboard { self?.refreshSources() }
        }.store(in: &subscriptions)
        clipboard.$enabled.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.scopes.scope == .clipboard { self?.refreshSources() }
        }.store(in: &subscriptions)
        clipboard.$error.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshClipboardStatus() }.store(in: &subscriptions)
        clipboard.$needsAccess.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshClipboardStatus() }.store(in: &subscriptions)
        syntax.isHidden = true
        syntax.onExample = { [weak self] example in
            guard let self else { return }; self.setBrowsing(false); self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        searchField.onSelectionChange = { [weak self] in self?.refreshDiagnostics() }
        searchField.onChange = { [weak self] in self?.setBrowsing(false); self?.startSearch() }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        filters.onChange = { [weak self] in self?.requestedScope = .files; self?.scopes.scope = .files; self?.refreshAdditionalFilter(); self?.view.needsLayout = true; self?.searchField.focus(); self?.startSearch() }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            UserDefaults.standard.set(FilterBar.sortName(self.filters.options.sort), forKey: "sortKey")
            UserDefaults.standard.set(self.filters.options.ascending, forKey: "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.menuTracking = tracking
            if !tracking { self?.hideIfInactive() }
        }
        if !snapshot { results.currentSource = { [weak self] id in self?.searchSources.first { $0.id == id } } }
        results.onPointerSelection = { [weak self] in self?.setBrowsing(true) }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.canPerformFileActions = { [weak self] in self?.resultIsCurrent == true && self?.stateView == nil }
        results.onUserNavigation = { [weak self] in self?.userNavigated = true }
        results.onSelection = { [weak self] in
            if let self, let pending = self.pendingClipboardID,
               self.results.selectedLauncherRow?.identity != "clip:" + pending.uuidString { self.invalidateClipboardCopy() }
            self?.quickLook.refresh()
            self?.updateActionHints()
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        quickLook.selectedURL = { [weak self] in
            guard let self, self.results.selectedItem?.source.isOnline == true else { return nil }
            return self.selectedURL
        }
        quickLook.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        footer.onSettings = { [weak self] in self?.onSettings?() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        setState(.empty)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
        refreshAdditionalFilter()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func localize() {
        footer.spacePreview = browsingResults && previewWithSpace && canPreviewSelection
        scopes.localize(); filters.localize(); footer.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        searchField.localize()
        refreshAdditionalFilter()
        if let found = results.snapshot { snapshotDidChange(found) }
        else if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        refreshProgress()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        topLine.frame = NSRect(x: 0, y: 64, width: w, height: px)
        scopes.frame = NSRect(x: 0, y: 64 + px, width: w, height: 40)
        filters.isHidden = scopes.scope != .files
        filters.frame = NSRect(x: 0, y: 104 + px, width: w, height: 40)
        let top: CGFloat = (filters.isHidden ? 104 : 144) + px
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - 34 - px))
        [results, empty, indexing, syntax].forEach { $0.frame = region }
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - 34, width: w, height: 34)
    }
    func setState(_ state: StateView.State?) {
        _ = view
        let previous: NSView = stateView ?? (results as NSView)
        stateView = state == .empty ? empty : state == .indexing ? indexing : nil
        let target: NSView = stateView ?? (results as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && results.rowCount > 0
        guard previous !== target else { return }
        let animate = !snapshot && view.window?.isVisible == true && previous !== target
        for item in [results, empty, indexing] as [NSView] {
            let visible = item === target
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? (self.results as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
    }
    func panelWillShow() {
        if let hiddenAt, SearchQueryRetention.read(from: preferences).expired(hiddenAt: hiddenAt, now: clock()) {
            searchField.editor.unmarkText()
            searchField.text = ""
        }
        hiddenAt = nil
        setBrowsing(false)
        additionalSearchProvider?.visibilityChanged(true)
        supplementaryProvider?.userActivity(visible: true, typing: false)
        if scopes.scope == .clipboard { _ = clipboard.search("") }
        if !snapshot { startSearch(preserveSelection: true); return }
        let currentQuery = Query.parse(searchField.text, store: manager?.store)
        let sources = searchSources
        if additionalSearchProvider?.isEnabled != true, let result = results.result, result.isCurrent(sources),
           (result.single != nil || result.multiple != nil || sources.isEmpty),
           result.query.raw == currentQuery.raw, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }
    func indexChanged() {
        refreshProgress()
        supplementaryProvider?.sourcesDidChange(searchSources)
        if view.window?.isVisible == true { coordinator.refreshFiles(sources: searchSources) }
    }
    func managerStateChanged(_ state: IndexManager.State) {
        refreshProgress()
        if state == .ready { coordinator.refreshFiles(sources: searchSources) }
    }
    private func refreshProgress() {
        if (results.snapshot == nil || scopes.scope == .files), let result = results.result, result.query.isEmpty { updateFooter(result) }
        guard let manager else { return }
        supplementaryProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        additionalSearchProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        searchField.indexing = manager.state == .scanning || manager.isRescanning
        if manager.store == nil && scopes.scope == .files && !filters.additionalSelected && (results.result?.count ?? 0) == 0 {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        invalidateClipboardCopy()
        _ = view
        preserveFirstSelection = preserveSelection; userNavigated = false; results.cancelPendingRefresh()
        footer.actionable = false
        supplementaryProvider?.userActivity(visible: view.window?.isVisible == true, typing: !preserveSelection)
        let composing = searchField.editor.hasMarkedText()
        let effective = SearchRoute.effectiveScope(searchField.text, requested: requestedScope, composing: composing)
        if effective != scopes.scope { scopes.scope = effective; view.needsLayout = true }
        var options = filters.options
        if scopes.scope == .all { options.kind = nil }
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let defaults = UserDefaults.standard
        coordinator.search(raw: searchField.text, scope: scopes.scope, options: options, store: manager?.store,
                           editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), composing: composing,
                           apps: applications.apps, clipboard: clipboard.entries, clipboardEnabled: clipboard.enabled,
                           calculator: snapshot || defaults.bool(forKey: "calculatorEnabled"), web: snapshot || defaults.bool(forKey: "webSearchEnabled"),
                           engine: WebSearchEngine(rawValue: defaults.string(forKey: "webSearchEngine") ?? "duckDuckGo") ?? .duckDuckGo,
                           sources: searchSources, supplementaryProvider: supplementaryProvider, currency: currencyRow,
                           additionalProvider: additionalSearchProvider, additionalOnly: scopes.scope == .files && filters.additionalSelected)
    }
    func startSources() {
        guard !snapshot else { return }
        applications.start(excludedPaths: UserDefaults.standard.stringArray(forKey: "userExcludedPaths") ?? [])
        clipboard.start()
    }
    func stopSources() { applications.stop(); clipboard.stop(); currencyRates.stop() }
    func selectScope(_ scope: SearchScope) {
        if scope == .clipboard { _ = clipboard.search("") }
        requestedScope = scope
        scopes.scope = scope; quickLook.close(); clipboardPreview?.close(); view.needsLayout = true
        refreshAdditionalFilter()
        searchField.focus(); startSearch()
    }
    private func refreshSources() {
        guard isViewLoaded, !snapshot else { return }
        let defaults = UserDefaults.standard
        coordinator.refreshSources(apps: applications.apps, clipboard: clipboard.entries, clipboardEnabled: clipboard.enabled,
                                   calculator: snapshot || defaults.bool(forKey: "calculatorEnabled"), web: snapshot || defaults.bool(forKey: "webSearchEnabled"),
                                   engine: WebSearchEngine(rawValue: defaults.string(forKey: "webSearchEngine") ?? "duckDuckGo") ?? .duckDuckGo,
                                   currency: currencyRow)
    }
    private var currentCurrencyQuery: CurrencyQuery? {
        guard scopes.scope == .all, !searchField.editor.hasMarkedText(),
              snapshot || (preferences.object(forKey: "currencyEnabled") as? Bool ?? true) else { return nil }
        return CurrencyQuery.parse(searchField.text)
    }
    private var currencyRow: LauncherRow? {
        guard let query = currentCurrencyQuery else { return nil }
        return .currency(query, currencyRates.lookup(query))
    }
    private func snapshotDidChange(_ found: SearchSnapshot) {
        if let file = found.filePresentation { configureEmpty(file) }
        else { empty.configure(diagnostic: nil, hasNoAccess: false) }
        setState(found.count == 0 ? (found.filesPending ? .indexing : .empty) : nil)
        footer.warning = !diagnostics.isEmpty
        if found.scope == .files, let file = found.filePresentation { updateFooter(file) }
        else if found.scope == .clipboard {
            footer.text = clipboard.error ?? (clipboard.needsAccess ? L10n.text("clipboard.accessHint") : L10n.text("clipboard.count", String(found.count)))
        } else { footer.text = L10n.text("launcher.count", String(found.count)) }
        if additionalSearchFailed { footer.warning = true; footer.text = L10n.text("search.failed") }
        updateActionHints(); refreshProgress()
    }
    private func refreshClipboardStatus() {
        guard scopes.scope == .clipboard, let found = results.snapshot else { return }
        snapshotDidChange(found)
    }
    private var canPreviewSelection: Bool {
        if results.snapshot == nil { return results.selectedItem != nil }
        switch results.selectedLauncherRow {
        case .file?, .clipboard?: return true
        default: return false
        }
    }
    private func updateActionHints() {
        footer.spacePreview = browsingResults && previewWithSpace && canPreviewSelection
        footer.setRow(results.selectedLauncherRow ?? results.selectedAdditional.map(LauncherRow.additional))
    }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
    }
    private func editingQuery(store: IndexStore?) -> Query {
        Query.parse(searchField.text, store: store, editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText(), pathExists: { [self] path in
            if searchSources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            var info = stat(); return path.withCString { stat($0, &info) == 0 }
        })
    }
    private func refreshDiagnostics() {
        guard results.snapshot == nil || scopes.scope == .files else { return }
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result)
    }
    private func configureEmpty(_ result: SearchPresentation) {
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || result.sources.contains { source in source.store.read { source.store.coverage[.noAccess].count > 0 } })
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        footer.actionable = !visible && stateView == nil && results.rowCount > 0
        syntax.isHidden = false
        Theme.Motion.opacity(syntax, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntax.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntax.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntax.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchPresentation) {
        configureEmpty(result)
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
    }
    private func updateFooter(_ result: SearchPresentation) {
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if additionalSearchFailed { footer.warning = true; footer.text = L10n.text("search.failed"); return }
        if filters.additionalSelected {
            footer.text = L10n.text("footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
            if let status = additionalSearchProvider?.status { footer.text = status }
        } else if result.query.isEmpty {
            let count = Presentation.countText(result.sources.reduce(0) { count, source in count + source.store.read { source.store.liveCount } })
            footer.text = L10n.text("footer.recent", count)
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = [], additionalOnly: Bool = false) throws {
        _ = view
        requestedScope = .files; scopes.scope = .files; view.needsLayout = true
        searchField.text = state == "recent" ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        if additionalOnly || additionalSearchProvider?.isEnabled == true {
            if additionalOnly { filters.select(FilterBar.names.count, notify: false); refreshAdditionalFilter() }
            let query = Query.parse(searchField.text, store: store)
            let sources = additionalOnly ? [] : store.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0)] + additionalSources } ?? additionalSources
            let files: SearchPresentation
            if sources.isEmpty { files = SearchPresentation(query: query) }
            else if let result = MultiSearcher.search(query, options: options, in: sources) {
                let hits = supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: { false })() ?? []
                files = hits.isEmpty ? SearchPresentation(result) : SearchPresentation(result).supplement(hits, options: options)
            } else { throw SnapshotError.failed("Cannot search snapshot index") }
            let began = CFAbsoluteTimeGetCurrent()
            let items = additionalOnly || options.kind == nil ? try additionalSearchProvider?.prepareSearch(query, isCancelled: { false })() ?? [] : []
            diagnostics = query.diagnostics
            present(files.including(items, options: options, elapsedMs: (CFAbsoluteTimeGetCurrent() - began) * 1000), selection: selection)
            return
        }
        guard let store else { throw SnapshotError.failed("Cannot search snapshot index") }
        let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources
        let query = Query.parse(searchField.text, store: store)
        let found: SearchPresentation
        if let supplementaryProvider {
            let hits = supplementaryProvider.prepareSearch(query, options: options, sources: sources, isCancelled: { false })()
            guard let result = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            found = SearchPresentation(result).supplement(hits, options: options)
        } else if !additionalSources.isEmpty {
            guard let result = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            found = SearchPresentation(result)
        } else {
            guard let result = Searcher.search(query, options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
            found = SearchPresentation(result)
        }
        diagnostics = query.diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    func prepareLauncherSnapshot(_ found: SearchSnapshot, clipboardEntries: [ClipboardEntry] = [], selection: Int = 0) throws {
        guard snapshot else { throw SnapshotError.failed("Launcher fixtures require snapshot mode") }
        _ = view
        clipboard.prepareSnapshot(clipboardEntries)
        requestedScope = found.scope; scopes.scope = found.scope; searchField.text = found.raw; view.needsLayout = true
        results.show(found, selection: selection)
        diagnostics = found.filePresentation?.query.diagnostics ?? []
        snapshotDidChange(found)
    }
    private var selectedURL: URL? {
        guard stateView == nil, resultIsCurrent else { return nil }
        return results.selectedItem.map { URL(fileURLWithPath: $0.path) }
    }
    private var resultIsCurrent: Bool {
        guard let found = results.snapshot else { return true }
        return found.raw == searchField.text && found.scope == scopes.scope
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), option = flags.contains(.option)
        if searchField.editor.hasMarkedText() { return false }
        if event.keyCode == 51 && flags.intersection([.command, .control, .option, .shift]) == .command {
            searchField.clearText(); return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = searchField.input.currentEditor() {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: invalidateClipboardCopy(); editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        if command && event.keyCode == 44 { toggleSyntax(); return true }
        if syntaxVisible && event.keyCode == 53 { toggleSyntax(false); return true }
        if syntaxVisible { return false }
        if [126, 125, 116, 121, 115, 119].contains(event.keyCode) { setBrowsing(true) }
        if event.keyCode == 49 && flags.intersection([.command, .control, .option, .shift]).isEmpty && browsingResults && previewWithSpace && canPreviewSelection {
            previewSelected(); return true
        }
        switch event.keyCode {
        case 115: userNavigated = true; results.select(0, repeatKey: event.isARepeat); return true
        case 119: userNavigated = true; results.select(results.rowCount - 1, repeatKey: event.isARepeat); return true
        case 126: userNavigated = true; if command { results.select(0, repeatKey: event.isARepeat) } else { results.move(-1, repeatKey: event.isARepeat) }; return true
        case 125: userNavigated = true; if command { results.select(results.rowCount - 1, repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
        case 116: userNavigated = true; results.page(-1, repeatKey: event.isARepeat); return true
        case 121: userNavigated = true; results.page(1, repeatKey: event.isARepeat); return true
        case 36, 76: if command { revealSelected() } else { openSelected() }; return true
        case 48:
            if scopes.scope == .files { filters.cycle(flags.contains(.shift) ? -1 : 1) }
            else { let index = SearchScope.allCases.firstIndex(of: scopes.scope)!; selectScope(SearchScope.allCases[(index + (flags.contains(.shift) ? 4 : 1)) % 5]) }
            return true
        case 53: if quickLook.isVisible { quickLook.close() } else if clipboardPreview?.isVisible == true { clipboardPreview?.close() } else { hidePanel?() }; return true
        default: break
        }
        guard command else { return false }
        switch key {
        case "y": previewSelected(); return true
        case "c":
            if option { copyName(); return true }
            if searchField.input.currentEditor()?.selectedRange.length ?? 0 > 0 { return false }
            copyPath(); return true
        case "w": hidePanel?(); return true
        case ",": onSettings?(); return true
        case "0"..."9":
            let number = Int(key) ?? 0
            if option && number > 0 { requestedScope = .files; scopes.scope = .files; view.needsLayout = true; filters.select(number - 1) }
            else if !option && number < 5 { selectScope(SearchScope.allCases[number]) }
            return true
        default: return false
        }
    }
    private func openSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if let item = results.selectedAdditional { performAdditional(item, kind: .open); return }
        if let row = results.selectedLauncherRow {
            switch row {
            case .app(let app):
                guard applications.apps.contains(where: { $0.path == app.path }),
                      FileManager.default.fileExists(atPath: app.path), openApplication(URL(fileURLWithPath: app.path)) else { NSSound.beep(); return }
                applications.recordLaunch(app); hidePanel?(); return
            case .setting(let setting):
                if SystemSettingsCatalog.open(setting) { hidePanel?() } else { NSSound.beep() }; return
            case .clipboard(let entry):
                copyClipboardEntry(entry) { [weak self] in
                    guard let self, let token = self.clipboard.latestCopyToken else { return }
                    self.pasteController.pasteCurrentClipboard(isClipboardCurrent: { [weak self] in
                        self?.clipboard.isClipboardCurrent(token) == true
                    }, hidePanel: { [weak self] completion in
                        guard let panel = self?.view.window as? SearchPanel else { self?.hidePanel?(); completion(); return }
                        panel.hide(source: .interaction, completion: completion)
                    }, completion: { [weak self] outcome in
                        guard outcome != .sent, let self else { return }
                        (self.view.window as? SearchPanel)?.show(source: .interaction)
                        self.footer.showMessage(L10n.text(outcome == .clipboardChanged ? "clipboard.changed" : "clipboard.copiedOnly"))
                    })
                }; return
            case .answer(let answer): copyText(answer.value); return
            case .currency(let query, let lookup):
                guard currentCurrencyQuery == query else { return }
                switch lookup {
                case .ready(let quote): copyText(quote.value)
                case .unavailable: currencyRates.retry(query); refreshSources()
                case .loading: break
                }
                return
            case .url(let url), .web(_, let url):
                if NSWorkspace.shared.open(url) { hidePanel?() } else { NSSound.beep() }; return
            case .enableClipboard: clipboard.setEnabled(true); startSearch(); return
            case .action(let action): onCaptureAction?(action); return
            case .file, .additional: break
            }
        }
        guard stateView == nil, (view.window as? SearchPanel)?.hiding != true, let url = selectedURL else { return }
        guard allowOnlineAction() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        results.pressOpen { [weak self] in
            guard self?.allowOnlineAction() == true else { return }
            guard NSWorkspace.shared.open(url) else { NSSound.beep(); return }
            self?.hidePanel?()
        }
    }
    private func revealSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if case .clipboard(let entry)? = results.selectedLauncherRow, entry.filePaths != nil {
            NSWorkspace.shared.activateFileViewerSelecting(entry.fileURLs); hidePanel?(); return
        }
        guard let url = selectedURL, allowOnlineAction() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?()
    }
    @discardableResult
    private func allowOnlineAction() -> Bool {
        guard let item = results.selectedItem else { return false }
        let current = searchSources.first { $0.id == item.source.id }
        guard item.source.isOnline && (snapshot || current?.isOnline == true) else {
            footer.warning = true; footer.actionable = false
            footer.text = L10n.text("source.unavailable", item.source.displayName)
            return false
        }
        return snapshot || current?.store === item.source.store
    }
    private func copyPath() {
        guard stateView == nil, resultIsCurrent else { return }
        if let item = results.selectedAdditional { performAdditional(item, kind: .copy); return }
        if let row = results.selectedLauncherRow {
            switch row {
            case .clipboard(let entry):
                copyClipboardEntry(entry) { [weak self] in self?.footer.showMessage(L10n.text("clipboard.copied")) }; return
            case .answer(let answer): copyText(answer.value); return
            case .currency(let query, let lookup):
                guard currentCurrencyQuery == query else { return }
                if case .ready(let quote) = lookup { copyText(quote.value) }; return
            case .setting(let setting): copyText(setting.name); return
            case .app(let app): copyText(app.path); return
            case .url(let url), .web(_, let url): copyText(url.absoluteString); return
            case .enableClipboard, .action: return
            case .file, .additional: break
            }
        }
        guard stateView == nil, let url = selectedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]); NSPasteboard.general.setString(url.path, forType: .string)
        footer.showToast(.copiedPath, value: url.path)
    }
    private func copyName() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .copyName); return }
        guard stateView == nil, resultIsCurrent, let item = results.selectedItem else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.name, forType: .string)
        footer.showToast(.copiedName, value: item.name)
    }
    private func trashSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        if case .clipboard(let entry)? = results.selectedLauncherRow { clipboard.remove(entry.id); return }
        guard stateView == nil, let url = selectedURL, let item = results.selectedItem else { return }
        guard allowOnlineAction(), FileManager.default.fileExists(atPath: url.path), trashing.insert(url).inserted else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.trashing.remove(url)
                if error != nil { NSSound.beep() }
                else { self?.footer.showToast(.trashed, value: item.name) }
            }
        }
    }
    private func performAdditional(_ item: AdditionalSearchItem, kind: AdditionalSearchAction.Kind) {
        guard resultIsCurrent, stateView == nil, additionalSearchProvider?.isEnabled == true,
              additionalSearchProvider?.availableItems(from: [item]).contains(where: { $0.id == item.id }) == true,
              let action = item.actions.first(where: { $0.kind == kind }) else { return }
        let perform = { [weak self] in
            guard let self, self.results.selectedAdditional?.id == item.id, self.additionalSearchProvider?.isEnabled == true,
                  self.additionalSearchProvider?.availableItems(from: [item]).contains(where: { $0.id == item.id }) == true else { return }
            self.runAdditional(action)
        }
        if kind == .open { results.pressOpen(perform) } else { perform() }
    }
    private func runAdditional(_ action: AdditionalSearchAction) {
        guard additionalSearchProvider?.isEnabled == true, resultIsCurrent else { return }
        action.perform { [weak self] success in
            guard let self else { return }
            if success { if action.kind == .open { self.hidePanel?() } }
            else { self.footer.warning = true; self.footer.text = L10n.text("search.actionFailed") }
        }
    }
    private struct AdditionalMenuSelection {
        let itemID: String
        let kind: AdditionalSearchAction.Kind
    }
    @objc private func additionalContextAction(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AdditionalMenuSelection,
              let selected = results.selectedAdditional, selected.id == choice.itemID else { return }
        performAdditional(selected, kind: choice.kind)
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        if let selected = results.selectedAdditional {
            guard resultIsCurrent, additionalSearchProvider?.availableItems(from: [selected]).contains(where: { $0.id == selected.id }) == true else { return menu }
            for action in selected.actions {
                let item = NSMenuItem(title: action.title, action: #selector(additionalContextAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = AdditionalMenuSelection(itemID: selected.id, kind: action.kind); menu.addItem(item)
            }
            return menu
        }
        if let row = results.selectedLauncherRow, results.selectedItem == nil {
            var actions: [(String, Int)] = [("hint.open", 0), ("launcher.copy", 4)]
            if case .clipboard(let entry) = row {
                actions = [("clipboard.paste", 0), ("launcher.copy", 4), ("hint.preview", 2)]
                if entry.filePaths != nil { actions += [("hint.reveal", 1), ("clipboard.copyPaths", 8)] }
                if entry.image != nil { actions += [("capture.action.edit", 9), ("capture.action.ocr", 10), ("capture.action.pin", 11)] }
                actions.append(("clipboard.delete", 7))
            }
            if case .enableClipboard = row { actions = [("clipboard.enable", 0)] }
            if case .action(let action) = row { actions = [("capture.action." + action.rawValue, 0)] }
            if case .currency(let query, let lookup) = row {
                guard resultIsCurrent, currentCurrencyQuery == query else { return menu }
                switch lookup {
                case .ready: actions = [("launcher.copy", 4)]
                case .unavailable: actions = [("currency.retry", 0)]
                case .loading: actions = []
                }
            }
            for (key, tag) in actions {
                let item = NSMenuItem(title: L10n.text(key), action: #selector(contextAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; menu.addItem(item)
            }
            return menu
        }
        for (i, key) in ["open", "reveal", "preview", "-", "copyPath", "copyName", "-", "trash"].enumerated() {
            if key == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: L10n.text("ctx." + key), action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            if i == 7 { item.isEnabled = results.selectedItem?.source.isOnline == true }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func contextAction(_ item: NSMenuItem) {
        switch item.tag {
        case 0: openSelected(); case 1: revealSelected(); case 2: previewSelected(); case 4: copyPath()
        case 5: copyName(); case 7: trashSelected()
        case 8:
            guard resultIsCurrent, case .clipboard(let entry)? = results.selectedLauncherRow else { return }
            copyText(entry.text)
        case 9, 10, 11:
            guard resultIsCurrent, case .clipboard(let entry)? = results.selectedLauncherRow, let image = entry.image else { return }
            onEditClipboardImage?(image, item.tag == 10 ? .ocr : item.tag == 11 ? .pin : .edit)
        default: break
        }
    }
    private func invalidateClipboardCopy() {
        clipboardActionGeneration += 1
        pendingClipboardID = nil
        clipboard.cancelCopy()
    }
    private func copyClipboardEntry(_ entry: ClipboardEntry, completion: @escaping () -> Void) {
        invalidateClipboardCopy()
        let generation = clipboardActionGeneration
        let query = searchField.text, scope = scopes.scope
        pendingClipboardID = entry.id
        if entry.filePaths != nil { footer.showMessage(L10n.text("clipboard.checkingFiles")) }
        else if entry.image != nil { footer.showMessage(L10n.text("clipboard.preparingImage")) }
        clipboard.copy(entry, isCurrent: { [weak self] in
            guard let self, self.clipboardActionGeneration == generation, self.stateView == nil,
                  self.searchField.text == query, self.scopes.scope == scope, self.resultIsCurrent,
                  case .clipboard(let selected)? = self.results.selectedLauncherRow,
                  selected.id == entry.id, selected.content == entry.content else { return false }
            if let window = self.view.window {
                return window.isVisible && window.isKeyWindow && (window as? SearchPanel)?.hiding != true
            }
            return true
        }, completion: { [weak self] outcome in
            guard let self, self.clipboardActionGeneration == generation else { return }
            self.pendingClipboardID = nil
            switch outcome {
            case .copied: completion()
            case .failed: self.footer.showMessage(self.clipboard.error ?? L10n.text("clipboard.failure.copyFailed")); NSSound.beep()
            case .cancelled: self.refreshClipboardStatus()
            }
        })
    }
    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        footer.showMessage(L10n.text("clipboard.copied"))
    }
    private func previewSelected() {
        guard stateView == nil, resultIsCurrent else { return }
        guard case .clipboard(let entry)? = results.selectedLauncherRow else {
            if allowOnlineAction() { quickLook.toggle() }; return
        }
        if clipboardPreview?.isVisible == true { clipboardPreview?.close(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = entry.filePaths == nil && entry.image == nil ? L10n.text("scope.clipboard") : entry.displayTitle
        panel.isReleasedWhenClosed = false; panel.level = .floating
        if let image = entry.image {
            let preview = NSImageView(frame: panel.contentView!.bounds.insetBy(dx: 16, dy: 16))
            preview.autoresizingMask = [.width, .height]; preview.imageScaling = .scaleProportionallyUpOrDown
            preview.setAccessibilityLabel(entry.displayTitle)
            panel.contentView!.addSubview(preview)
            clipboardImageIcons.clipboardImage(image, maximumSize: 1600) { [weak preview] rendered in preview?.image = rendered }
            panel.center(); panel.orderFrontRegardless(); clipboardPreview = panel; return
        }
        let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.string = entry.text; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 16, height: 16); text.autoresizingMask = [.width]; scroll.documentView = text
        panel.contentView = scroll; panel.center(); panel.orderFrontRegardless(); clipboardPreview = panel
    }
    func panelDidHide() {
        hiddenAt = clock()
        additionalSearchProvider?.visibilityChanged(false)
        supplementaryProvider?.userActivity(visible: false, typing: false)
        invalidateClipboardCopy(); quickLook.close(); clipboardPreview?.close()
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; hideIfInactive() }
    private func hideIfInactive() {
        if view.window?.isKeyWindow == false && !quickLook.isVisible && clipboardPreview?.isVisible != true && !menuTracking && !dragging { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        DispatchQueue.main.async { [weak self] in self?.hideIfInactive() }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selectedURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
