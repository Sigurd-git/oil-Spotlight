import AppKit
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class LauncherInputTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func key(_ code: UInt16 = 51, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    func testCommandBackspaceClearsWholeQueryWithoutDeletingClipboardSelection() throws {
        let controller = SearchViewController(snapshot: true)
        let entry = ClipboardEntry(text: "Synthetic note")
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "multi word query", scope: .clipboard,
                                                              leading: [.clipboard(entry)]), clipboardEntries: [entry])
        XCTAssertTrue(controller.handleKey(try key()))
        XCTAssertEqual(controller.searchField.text, "")
        XCTAssertEqual(controller.clipboard.entries, [entry])
        XCTAssertEqual(controller.scopes.scope, .clipboard)
    }

    func testCommandBackspaceClearsFieldEditorAtStartMiddleAndPartialSelection() throws {
        let controller = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller; window.delegate = controller
        defer { window.close() }
        let text = "alpha 中文 🐱 omega"
        for range in [NSRange(location: 0, length: 0), NSRange(location: 5, length: 0),
                      NSRange(location: 2, length: 4), NSRange(location: text.utf16.count, length: 0)] {
            controller.searchField.text = text; controller.searchField.focus()
            let editor = try XCTUnwrap(controller.searchField.input.currentEditor() as? SearchEditor)
            editor.setSelectedRange(range)
            editor.keyDown(with: try key())
            XCTAssertEqual(controller.searchField.text, "", "Selection: \(range)")
            XCTAssertEqual(editor.string, "", "Field editor must clear along with the control")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        }
    }

    func testClearEmitsQueryChangeAndExitsResultBrowsingEvenWithoutAnEditor() throws {
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.searchField.text = "two words"
        controller.results.onPointerSelection?()
        XCTAssertTrue(controller.browsingResults)
        var changedQueries: [String] = []
        let original = controller.searchField.onChange
        controller.searchField.onChange = {
            changedQueries.append(controller.searchField.text); original?()
        }
        XCTAssertTrue(controller.handleKey(try key()))
        XCTAssertEqual(changedQueries, [""])
        XCTAssertFalse(controller.browsingResults)
        XCTAssertNil(controller.searchField.input.currentEditor())
    }

    func testClearDoesNotReplaceActiveIMECompositionOrConsumeOrdinaryBackspace() throws {
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.searchField.text = "keep"
        controller.searchField.editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(controller.searchField.editor.hasMarkedText())
        XCTAssertFalse(controller.handleKey(try key()))
        XCTAssertEqual(controller.searchField.text, "keep")
        controller.searchField.editor.unmarkText()
        XCTAssertFalse(controller.handleKey(try key(flags: [])))
        XCTAssertFalse(controller.handleKey(try key(flags: [.command, .option])))
        XCTAssertEqual(controller.searchField.text, "keep")
    }

    func testCurrencyRowsKeepIdentityWhileLoadingAndLocalizeTheirActions() throws {
        let query = try XCTUnwrap(CurrencyQuery.parse("100 usd in to rmb"))
        let pending = LauncherRow.currency(query, .loading)
        let ready = LauncherRow.currency(query, .ready(CurrencyQuote(value: "700.00 CNY", date: "2026-01-01",
                                                                    isCached: true, isStale: true)))
        XCTAssertEqual(pending.identity, ready.identity)
        XCTAssertEqual(ready.title, "700.00 CNY")
        XCTAssertTrue(ready.subtitle.contains("2026-01-01"))
        XCTAssertTrue(ready.subtitle.contains(L10n.text("currency.stale")))
        let controller = SearchViewController(snapshot: true)
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: query.expression, scope: .all, leading: [pending]))
        let menu = try XCTUnwrap(controller.results.onContextMenu?(0))
        XCTAssertEqual(menu.items.count, 0, "Loading must not offer copying placeholder text")
    }

    func testQueryExpiresAfterHiddenIntervalAndResetsOnEachReopen() throws {
        let name = "OilFind.QueryExpiryTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = SearchViewController(snapshot: true, preferences: defaults, clock: { now })
        _ = controller.view
        controller.searchField.text = "keep briefly"
        now = now.addingTimeInterval(3600)
        controller.panelWillShow()
        XCTAssertEqual(controller.searchField.text, "keep briefly", "Visible time must not expire a query")
        controller.panelDidHide()
        now = now.addingTimeInterval(59)
        controller.panelWillShow()
        XCTAssertEqual(controller.searchField.text, "keep briefly")
        controller.panelDidHide()
        now = now.addingTimeInterval(60)
        controller.panelWillShow()
        XCTAssertEqual(controller.searchField.text, "")
        XCTAssertFalse(controller.browsingResults)
        XCTAssertEqual(controller.scopes.scope, .all)
    }

    func testQueryExpiryReadsChangedPreferenceAndKeepsClipboardScope() throws {
        let name = "OilFind.QueryExpiryTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = SearchViewController(snapshot: true, preferences: defaults, clock: { now })
        let entry = ClipboardEntry(text: "Synthetic note")
        try controller.prepareLauncherSnapshot(SearchSnapshot(raw: "old query", scope: .clipboard,
                                                             leading: [.clipboard(entry)]), clipboardEntries: [entry])
        defaults.set(SearchQueryRetention.never.rawValue, forKey: "searchQueryRetention")
        controller.panelDidHide()
        now = now.addingTimeInterval(10_000)
        controller.panelWillShow()
        XCTAssertEqual(controller.searchField.text, "old query")
        controller.panelDidHide()
        defaults.set(SearchQueryRetention.immediately.rawValue, forKey: "searchQueryRetention")
        controller.panelWillShow()
        XCTAssertEqual(controller.searchField.text, "")
        XCTAssertEqual(controller.scopes.scope, .clipboard)
        XCTAssertEqual(controller.clipboard.entries, [entry])
    }

    func testQueryRetentionSettingsAndInvalidValuesUseSafeDefaults() throws {
        let name = "OilFind.QueryExpiryTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SearchQueryRetention.read(from: defaults), .minute)
        defaults.set(12, forKey: "searchQueryRetention")
        XCTAssertEqual(SearchQueryRetention.read(from: defaults), .minute)
        for value in SearchQueryRetention.allCases {
            let hidden = Date(timeIntervalSince1970: 1_000)
            XCTAssertFalse(value.expired(hiddenAt: hidden, now: hidden.addingTimeInterval(-1)))
            XCTAssertEqual(value.expired(hiddenAt: hidden, now: hidden.addingTimeInterval(900)), value != .never)
            let model = SettingsModel(preferences: defaults, clipboard: ClipboardHistory(snapshot: true))
            model.setSearchQueryRetention(value)
            XCTAssertEqual(SearchQueryRetention.read(from: defaults), value)
            let snapshot = SettingsModel(snapshot: true, preferences: defaults)
            snapshot.setSearchQueryRetention(.never)
            XCTAssertEqual(SearchQueryRetention.read(from: defaults), value)
        }
    }

    func testCurrencySettingsUseSuppliedPreferencesWithoutChangingSnapshotDefaults() throws {
        let name = "OilFind.CurrencySettingsTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "currencyEnabled")
        let model = SettingsModel(preferences: defaults, clipboard: ClipboardHistory(snapshot: true))
        XCTAssertFalse(model.currencyEnabled)
        model.setCurrency(true)
        XCTAssertTrue(defaults.bool(forKey: "currencyEnabled"))
        let snapshot = SettingsModel(snapshot: true, preferences: defaults)
        snapshot.setCurrency(false)
        XCTAssertTrue(defaults.bool(forKey: "currencyEnabled"))
    }

    func testCurrencyResultsRefreshIndependentlyOfCompactFiles() throws {
        let query = try XCTUnwrap(CurrencyQuery.parse("100 usd in to rmb"))
        let store = IndexStore(rootPath: "/generated/currency", count: 1, namesLen: 0, altCount: 0,
                               altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        store.nameOff[0] = 0; store.nameOff[1] = 0; store.parent[0] = 0
        store.sizeC[0] = 0; store.mtime[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 0; store.kind[0] = 1; store.altOff[0] = 0
        store.write {
            store.buildHash()
            Array("100 usd in to rmb.txt".utf8).withUnsafeBufferPointer {
                _ = store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 0))
            }
        }
        let coordinator = SearchCoordinator()
        let files = expectation(description: "Files publish while rates are still loading")
        let pending = expectation(description: "Pending currency is a ranked result")
        var fileDelivered = false, pendingDelivered = false
        coordinator.onUpdate = { found, _ in
            if found.filePresentation != nil && !fileDelivered {
                fileDelivered = true
                XCTAssertEqual(found.filePresentation?.count, 1)
                files.fulfill()
            }
            if case .currency(_, .loading)? = found.row(at: 0), !pendingDelivered {
                pendingDelivered = true; pending.fulfill()
            }
        }
        coordinator.search(raw: query.expression, scope: .all, options: .init(), store: store,
                           editingRange: nil, composing: false, apps: [], clipboard: [], clipboardEnabled: false,
                           calculator: true, web: false, engine: .duckDuckGo, currency: .currency(query, .loading))
        wait(for: [files, pending], timeout: 3)
        let ready = expectation(description: "Rates refresh without replacing the file source")
        coordinator.onUpdate = { found, _ in
            guard case .currency(_, .ready(let quote))? = found.row(at: 0) else { return }
            XCTAssertEqual(quote.value, "700.00 CNY")
            XCTAssertEqual(found.filePresentation?.count, 1)
            ready.fulfill()
        }
        coordinator.refreshSources(apps: [], clipboard: [], clipboardEnabled: false, calculator: true,
                                   web: false, engine: .duckDuckGo,
                                   currency: .currency(query, .ready(CurrencyQuote(value: "700.00 CNY", date: "2026-01-01",
                                                                                isCached: false, isStale: false))))
        wait(for: [ready], timeout: 3)
    }

    func testDisabledCurrencyCannotRetryStaleDisplayedFailure() throws {
        let name = "OilFind.CurrencyDisabledTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "currencyEnabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = expectation(description: "Disabled currency must not start a request")
        request.isInverted = true
        let provider = CurrencyRateProvider(transport: { _, _ in request.fulfill(); return {} },
                                            cacheURL: directory.appendingPathComponent("rates.json"))
        defer { provider.stop() }
        let controller = SearchViewController(snapshot: false, preferences: defaults,
                                               clipboard: ClipboardHistory(snapshot: true), currencyRates: provider)
        _ = controller.view
        let query = try XCTUnwrap(CurrencyQuery.parse("100 usd in to rmb"))
        controller.searchField.text = query.expression
        controller.results.show(SearchSnapshot(raw: query.expression, scope: .all, leading: [.currency(query, .unavailable)]))
        controller.setState(nil)
        XCTAssertTrue(controller.handleKey(try key(36)))
        XCTAssertEqual(controller.results.onContextMenu?(0)?.items.count, 0)
        wait(for: [request], timeout: 0.2)
    }
}
