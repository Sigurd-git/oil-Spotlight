import AppKit
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class LauncherRebaseTests: XCTestCase {
    private func store(_ root: String, names: [String]) -> IndexStore {
        let store = IndexStore(rootPath: root, count: 1, namesLen: 0, altCount: 0, altLen: 0,
                               fingerprint: 0, homeIndex: .max, finishedAt: 0)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.parent[0] = 0
        store.sizeC[0] = 0; store.mtime[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 3; store.kind[0] = 1; store.altOff[0] = 0
        store.write {
            store.buildHash()
            for name in names {
                Array(name.utf8).withUnsafeBufferPointer {
                    _ = store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0))
                }
            }
        }
        return store
    }

    private func result(_ sources: [SearchSource]) throws -> SearchPresentation {
        SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("report"), options: .init(sort: .name, ascending: true), in: sources)))
    }

    func testUnifiedMultiSourcePromotionDoesNotDeduplicateEqualIDsFromDifferentStores() throws {
        let a = store("/generated/a", names: ["report-a.txt"])
        let b = store("/generated/b", names: ["report-b.txt"])
        let presentation = try result([.init(id: "a", displayName: "A", isOnline: true, store: a),
                                       .init(id: "b", displayName: "B", isOnline: false, store: b)])
        let snapshot = SearchCoordinator.compose(raw: "report", scope: .all, filePresentation: presentation, extras: [])
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.removedOffsets, [0, 1])
        let items = (0..<snapshot.count).compactMap { position -> ResultItem? in
            if case .file(let item)? = snapshot.row(at: position) { return item }; return nil
        }
        XCTAssertEqual(items.map(\.source.id), ["a", "b"])
        XCTAssertEqual(items.map(\.id), [1, 1])
        XCTAssertEqual(Set(items.map(\.path)).count, 2)
    }

    func testUnifiedSelectionSurvivesSourceReorderAndStoreReplacement() throws {
        _ = NSApplication.shared
        let a = store("/generated/a", names: ["report-a.txt"])
        let b = store("/generated/b", names: ["report-b.txt"])
        let sources = [SearchSource(id: "a", displayName: "A", isOnline: true, store: a),
                       SearchSource(id: "b", displayName: "B", isOnline: true, store: b)]
        let view = ResultsView(frame: .zero)
        view.show(SearchSnapshot(raw: "report", scope: .files, filePresentation: try result(sources)), selection: 1)
        let replacement = store("/generated/b", names: ["unrelated.txt", "report-b.txt"])
        let next = [SearchSource(id: "b", displayName: "B", isOnline: false, store: replacement), sources[0]]
        view.refresh(SearchSnapshot(raw: "report", scope: .files, filePresentation: try result(next)))
        XCTAssertEqual(view.selectedItem?.source.id, "b")
        XCTAssertTrue(view.selectedItem?.source.store === replacement)
        XCTAssertEqual(view.selectedID, 2)
        XCTAssertFalse(try XCTUnwrap(view.selectedItem).source.isOnline)
    }

    func testUnifiedRowsRejectDragWhenTheSourceGoesOfflineOrIsReplaced() throws {
        _ = NSApplication.shared
        let index = store("/generated/archive", names: ["report.txt"])
        let original = SearchSource(id: "archive", displayName: "Archive", isOnline: true, store: index)
        let view = ResultsView(frame: .zero)
        view.show(SearchCoordinator.compose(raw: "report", scope: .all, filePresentation: try result([original]), extras: []))
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertNotNil(view.tableView(table, pasteboardWriterForRow: 0))
        view.currentSource = { _ in SearchSource(id: "archive", displayName: "Archive", isOnline: false, store: index) }
        XCTAssertFalse(try XCTUnwrap(view.selectedItem).source.isOnline)
        XCTAssertNil(view.tableView(table, pasteboardWriterForRow: 0))
        let replacement = store("/generated/archive", names: ["report.txt"])
        view.currentSource = { _ in SearchSource(id: "archive", displayName: "Archive", isOnline: true, store: replacement) }
        XCTAssertNil(view.tableView(table, pasteboardWriterForRow: 0))
        view.currentSource = { _ in nil }
        XCTAssertNil(view.selectedItem)
    }

    func testCoordinatorCanSearchAnAdditionalSourceBeforeStartupIndexLoads() {
        let index = store("/generated/archive", names: ["report.txt"])
        let coordinator = SearchCoordinator(), done = expectation(description: "External source published")
        var delivered = false
        coordinator.onUpdate = { snapshot, _ in
            guard snapshot.filePresentation != nil, !delivered else { return }
            delivered = true
            XCTAssertNil(snapshot.fileResult)
            XCTAssertEqual(snapshot.count, 1)
            XCTAssertEqual(snapshot.filePresentation?.sources.first?.id, "archive")
            done.fulfill()
        }
        coordinator.search(raw: "report", scope: .files, options: .init(), store: nil, editingRange: nil, composing: false,
                           apps: [], clipboard: [], clipboardEnabled: false, calculator: false, web: false, engine: .duckDuckGo,
                           sources: [.init(id: "archive", displayName: "Archive", isOnline: false, store: index)])
        wait(for: [done], timeout: 3)
    }

    func testSupplementDecorationIsRemovedWhenCellBecomesLauncherRow() throws {
        _ = NSApplication.shared
        let index = store("/generated/archive", names: ["report.txt"])
        let presentation = try result([.init(id: "archive", displayName: "Archive", isOnline: true, store: index)])
            .supplement([.init(sourceID: "archive", entryID: 1, detail: "Synthetic detail")], options: .init())
        let cell = ResultCell(frame: .zero), icons = IconProvider()
        cell.configure(try XCTUnwrap(SearchSnapshot.fileItem(presentation, offset: 0)), query: .parse("report"), icons: icons)
        let detail = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Synthetic detail · " })
        XCTAssertFalse(detail.isHidden)
        cell.configure(.answer(.init(expression: "1+1", value: "2", detail: "")), icons: icons)
        XCTAssertTrue(detail.isHidden)
        XCTAssertEqual(detail.stringValue, "")
    }

    func testPromotedFilesReadLiveMetadataAndRejectDeletedEntries() throws {
        _ = NSApplication.shared
        let index = store("/generated/archive", names: ["report.txt"])
        let source = SearchSource(id: "archive", displayName: "Archive", isOnline: true, store: index)
        let snapshot = SearchCoordinator.compose(raw: "report", scope: .all, filePresentation: try result([source]), extras: [])
        let view = ResultsView(frame: .zero)
        view.show(snapshot)
        XCTAssertEqual(snapshot.leading.count, 1)
        index.write {
            Array("report.txt".utf8).withUnsafeBufferPointer {
                _ = index.update(1, name: $0, attrs: EntryAttrs(type: 0, size: 4096, mtime: 123456))
            }
        }
        XCTAssertEqual(view.selectedItem?.size, 4096)
        XCTAssertEqual(view.selectedItem?.modified, Date(timeIntervalSince1970: 123456))
        index.write { _ = index.remove(1) }
        XCTAssertNil(snapshot.row(at: 0))
        XCTAssertNil(view.selectedItem)
        let table = NSTableView()
        XCTAssertNil(view.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertNil(view.tableView(table, viewFor: nil, row: 0))
    }

    func testDeadCompactEntriesNeverReturnUnconfiguredReusableCells() throws {
        _ = NSApplication.shared
        let index = store("/generated/archive", names: ["report.txt"])
        let presentation = try result([.init(id: "archive", displayName: "Archive", isOnline: true, store: index)])
        let view = ResultsView(frame: .zero)
        view.show(SearchSnapshot(raw: "report", scope: .files, filePresentation: presentation))
        let table = NSTableView()
        XCTAssertNotNil(view.tableView(table, viewFor: nil, row: 0))
        index.write { _ = index.remove(1) }
        XCTAssertNil(view.tableView(table, viewFor: nil, row: 0))
    }

    func testSourceWithdrawalPreservesAllScopeAndApplicationRows() throws {
        _ = NSApplication.shared
        let a = store("/generated/a", names: ["report-a.txt"])
        let b = store("/generated/b", names: ["report-b.txt"])
        let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: a),
                       SearchSource(id: "archive", displayName: "Archive", isOnline: true, store: b)]
        let controller = SearchViewController(snapshot: true)
        let app = LauncherApp(name: "Report", path: "/generated/Report.app")
        try controller.prepareLauncherSnapshot(SearchCoordinator.compose(raw: "report", scope: .all,
                                                filePresentation: try result(sources), extras: [.app(app)]))
        controller.additionalSources = { [sources[0]] }
        controller.sourcesChanged()
        XCTAssertEqual(controller.scopes.scope, .all)
        XCTAssertTrue(controller.results.snapshot?.leading.contains { $0.identity == "file:" + app.path } == true)
        XCTAssertFalse(controller.results.result?.sources.contains { $0.id == "archive" } == true)
    }

    private final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        var blocked = false
        let started = XCTestExpectation(description: "Supplement waiting")
        let gate = DispatchSemaphore(value: 0)
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            let wait = blocked, enabled = isEnabled
            return { [self] in
                if wait { started.fulfill(); gate.wait() }
                guard enabled, !isCancelled() else { return [] }
                return [.init(sourceID: "startup", entryID: 3, detail: "Synthetic supplementary match")]
            }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { }
        func userActivity(visible: Bool, typing: Bool) { }
    }

    func testDisablingSupplementsPreservesAllScope() throws {
        _ = NSApplication.shared
        let index = store("/generated/a", names: ["report.txt", "unrelated.txt", "other.png"])
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("report"), in: index)))
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        let combined = base.supplement([.init(sourceID: "startup", entryID: 3, detail: "Synthetic match")], options: .init())
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "report", scope: .all, filePresentation: combined))
        controller.additionalSources = { [.init(id: "startup", displayName: "", isOnline: true, store: index)] }
        controller.supplementaryProvider = provider
        provider.isEnabled = false
        controller.sourcesChanged()
        XCTAssertEqual(controller.scopes.scope, .all)
        XCTAssertFalse(controller.results.result?.hasSupplements == true)
    }

    func testIndexRefreshKeepsSelectedSupplementUntilLateWorkCompletes() throws {
        _ = NSApplication.shared
        let index = store("/generated/a", names: ["report.txt", "unrelated.txt", "other.png"])
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("report"), in: index)))
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        let initialPublished = expectation(description: "Initial supplementary results applied")
        let refreshPublished = expectation(description: "Refreshed supplementary results applied")
        var initialComplete = false, refreshComplete = false, checkingRefresh = false
        var observedSelections: [UInt32?] = []
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { checkingRefresh = false; provider.gate.signal(); window.close() }
        window.orderFront(nil)
        let combined = base.supplement([.init(sourceID: "startup", entryID: 3, detail: "Synthetic match")], options: .init())
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "report", scope: .files, filePresentation: combined))
        controller.additionalSources = { [.init(id: "startup", displayName: "", isOnline: true, store: index)] }
        controller.supplementaryProvider = provider
        let applySnapshot = controller.results.onSnapshotApplied
        controller.results.onSnapshotApplied = { found in
            applySnapshot?(found)
            guard !found.filesPending, found.filePresentation?.hasSupplements == true else { return }
            if !initialComplete {
                initialComplete = true; initialPublished.fulfill()
            } else if checkingRefresh && !refreshComplete {
                refreshComplete = true; refreshPublished.fulfill()
            }
        }
        let selectionChanged = controller.results.onSelection
        controller.results.onSelection = {
            selectionChanged?()
            if checkingRefresh { observedSelections.append(controller.results.selectedID) }
        }
        defer {
            controller.results.onSnapshotApplied = applySnapshot
            controller.results.onSelection = selectionChanged
        }
        // Navigate only after the initial query, then observe every refresh selection.
        controller.startSearch()
        wait(for: [initialPublished], timeout: 3)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        XCTAssertTrue(controller.handleKey(down))
        XCTAssertEqual(controller.results.selectedID, 3)
        checkingRefresh = true; provider.blocked = true
        controller.indexChanged()
        wait(for: [provider.started], timeout: 3)
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.gate.signal()
        wait(for: [refreshPublished], timeout: 3)
        XCTAssertFalse(observedSelections.isEmpty)
        XCTAssertTrue(observedSelections.allSatisfy { $0 == 3 })
        XCTAssertEqual(controller.results.selectedID, 3)
    }

    func testForkBuildDoesNotEnableOfficialUpdatesOrChangeTheirSavedPreference() {
        let defaults = UserDefaults(suiteName: "LauncherForkUpdates-" + UUID().uuidString)!
        let preferences = UpdatePreferences(defaults: defaults)
        preferences.automatic = true
        let model = UpdateManager(snapshot: false, preferences: preferences, supportsAppUpdates: false)
        XCTAssertFalse(model.supportsAppUpdates)
        XCTAssertFalse(model.automatic)
        XCTAssertFalse(model.canCheck)
        model.start(); model.check(); model.install(); model.automatic = true; model.stop()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(preferences.automatic)
    }
}
