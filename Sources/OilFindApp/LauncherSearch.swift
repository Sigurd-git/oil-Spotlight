import Foundation
import OilFindCore

enum SearchScope: String, CaseIterable {
    case all, apps, files, settings, clipboard
    var title: String { L10n.text("scope." + rawValue) }
}

enum LauncherRow {
    case file(ResultItem), app(LauncherApp), setting(SystemSetting), clipboard(ClipboardEntry)
    case answer(ToolAnswer), url(URL), web(String, URL), enableClipboard

    var identity: String {
        switch self {
        case .file(let item): return "file:" + item.path
        case .app(let app): return "file:" + app.path
        case .setting(let setting): return "setting:" + setting.id
        case .clipboard(let entry): return "clip:" + entry.id.uuidString
        case .answer(let answer): return "answer:" + answer.expression
        case .url(let url): return "url:" + url.absoluteString
        case .web(let query, _): return "web:" + query
        case .enableClipboard: return "enableClipboard"
        }
    }
    var title: String {
        switch self {
        case .file(let item): return item.name
        case .app(let app): return app.name
        case .setting(let setting): return setting.name
        case .clipboard(let entry): return entry.displayTitle
        case .answer(let answer): return answer.value
        case .url(let url): return url.absoluteString
        case .web(let query, _): return L10n.text("launcher.web", query)
        case .enableClipboard: return L10n.text("clipboard.enable")
        }
    }
    var subtitle: String {
        switch self {
        case .file(let item): return Presentation.abbreviate(path: item.parentPath, home: NSHomeDirectory())
        case .app(let app): return Presentation.abbreviate(path: app.path, home: NSHomeDirectory())
        case .setting(let setting): return setting.subtitle
        case .clipboard(let entry):
            return [entry.locationSummary, entry.sourceName, Presentation.dateText(entry.copiedAt, now: Date(), calendar: .current, chinese: L10n.chinese)].compactMap { $0 }.joined(separator: " · ")
        case .answer(let answer): return answer.expression + " · " + answer.detail
        case .url: return L10n.text("launcher.openURL")
        case .web: return L10n.text("launcher.webHint")
        case .enableClipboard: return L10n.text("clipboard.enableHint")
        }
    }
    var symbol: String {
        switch self {
        case .file: return "doc"
        case .app: return "app"
        case .setting(let setting): return setting.symbol
        case .clipboard(let entry): return entry.filePaths == nil ? "doc.on.clipboard" : "doc.on.doc"
        case .answer: return "equal.square"
        case .url: return "link"
        case .web: return "globe"
        case .enableClipboard: return "clipboard"
        }
    }
}

// File IDs stay in the engine's compact array. Only a bounded prefix is promoted.
final class SearchSnapshot {
    let raw: String, scope: SearchScope, filePresentation: SearchPresentation?
    var fileResult: SearchResult? { filePresentation?.single }
    let leading: [LauncherRow], trailing: [LauncherRow], removedOffsets: [Int]
    let filesPending: Bool
    var count: Int { leading.count + (filePresentation?.count ?? 0) - removedOffsets.count + trailing.count }
    convenience init(raw: String, scope: SearchScope, fileResult: SearchResult? = nil, leading: [LauncherRow] = [],
         trailing: [LauncherRow] = [], removedOffsets: [Int] = [], filesPending: Bool = false) {
        self.init(raw: raw, scope: scope, filePresentation: fileResult.map(SearchPresentation.init), leading: leading,
                  trailing: trailing, removedOffsets: removedOffsets, filesPending: filesPending)
    }
    init(raw: String, scope: SearchScope, filePresentation: SearchPresentation?, leading: [LauncherRow] = [],
         trailing: [LauncherRow] = [], removedOffsets: [Int] = [], filesPending: Bool = false) {
        self.raw = raw; self.scope = scope; self.filePresentation = filePresentation; self.leading = leading; self.trailing = trailing
        self.removedOffsets = removedOffsets.sorted(); self.filesPending = filesPending
    }
    static func fileItem(_ result: SearchResult, offset: Int) -> ResultItem? {
        fileItem(SearchPresentation(result), offset: offset)
    }
    static func fileItem(_ result: SearchPresentation, offset: Int) -> ResultItem? {
        guard let hit = result.row(offset) else { return nil }
        let store = hit.source.store, id = hit.id
        return store.read {
            guard Int(id) < store.count, store.isLive(id) else { return nil }
            let name = store.name(id), parent = store.parentPath(id)
            return ResultItem(detail: result.detail(at: offset), id: id, source: hit.source, name: name, parentPath: parent, path: parent == "/" ? "/" + name : parent + "/" + name,
                              size: store.size(id), modified: store.modified(id), flags: store.flags[Int(id)], kind: store.kind[Int(id)])
        }
    }
    func row(at position: Int) -> LauncherRow? {
        guard position >= 0, position < count else { return nil }
        if position < leading.count {
            if case .file(let item) = leading[position] { return Self.currentFileItem(item).map(LauncherRow.file) }
            return leading[position]
        }
        let offset = position - leading.count, fileCount = (filePresentation?.count ?? 0) - removedOffsets.count
        if offset < fileCount, let filePresentation {
            var original = offset
            for removed in removedOffsets where removed <= original { original += 1 }
            return Self.fileItem(filePresentation, offset: original).map(LauncherRow.file)
        }
        return trailing[offset - fileCount]
    }
    static func currentFileItem(_ item: ResultItem) -> ResultItem? {
        let store = item.source.store, id = item.id
        return store.read {
            guard Int(id) < store.count, store.isLive(id) else { return nil }
            let name = store.name(id), parent = store.parentPath(id)
            return ResultItem(detail: item.detail, id: id, source: item.source, name: name, parentPath: parent,
                              path: parent == "/" ? "/" + name : parent + "/" + name,
                              size: store.size(id), modified: store.modified(id), flags: store.flags[Int(id)], kind: store.kind[Int(id)])
        }
    }
    func position(of identity: String, fileID: UInt32? = nil, store: IndexStore? = nil, sourceID: String? = nil) -> Int? {
        if let index = leading.firstIndex(where: { $0.identity == identity }) { return index }
        if let filePresentation, identity.hasPrefix("file:") {
            let path = String(identity.dropFirst(5))
            let candidates = sourceID.map { id in filePresentation.sources.filter { $0.id == id } } ?? filePresentation.sources
            for source in candidates {
                let resolvedID: UInt32?
                if store === source.store, let fileID { resolvedID = fileID }
                else { resolvedID = source.store.read { source.store.hashReady ? source.store.resolve(path: path) : nil } }
                guard let resolvedID else { continue }
                if let offset = filePresentation.index(sourceID: source.id, store: store ?? source.store,
                                                       id: resolvedID, path: path), !removedOffsets.contains(offset) {
                    return leading.count + offset - removedOffsets.filter { $0 < offset }.count
                }
            }
        }
        if let index = trailing.firstIndex(where: { $0.identity == identity }) {
            return leading.count + (filePresentation?.count ?? 0) - removedOffsets.count + index
        }
        return nil
    }
}

enum SearchRoute {
    static func effectiveScope(_ raw: String, requested: SearchScope, composing: Bool = false) -> SearchScope {
        guard requested == .all, !composing else { return requested }
        if LauncherTools.url(raw) != nil || LauncherTools.evaluate(raw) != nil || LauncherTools.explicitWebQuery(raw) != nil { return .all }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("file://") { return .files }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        let prefixes = ["kind:", "ext:", "file:", "folder:", "size:", "dm:", "regex:", "path:", "case:"]
        if tokens.contains(where: { token in
            let word = token.hasPrefix("!") ? String(token.dropFirst()) : String(token)
            return prefixes.contains(where: { word.lowercased().hasPrefix($0) }) || word.contains("*") || word.contains("?") || word.contains("/")
        }) { return .files }
        return .all
    }
}

private final class SupplementarySearchBox { var hits: [SupplementaryHit] = [] }

final class SearchCoordinator {
    private let fileQueue: DispatchQueue, sourceQueue: DispatchQueue
    private let supplementQueue = DispatchQueue(label: "com.oiloil.find.supplement", qos: .userInteractive)
    private let lock = NSLock(), cache = SearchCache()
    private var generation = 0, fileRequest = 0, sourceRequest = 0
    private var raw = "", scope = SearchScope.all, options = SearchOptions()
    private var sources: [SearchSource] = [], supplementaryProvider: SupplementarySearchProvider?
    private var sourceCaches: [String: SearchCache] = [:], cacheStores: [String: ObjectIdentifier] = [:]
    private var editingRange: NSRange?, composing = false
    private var fileResult: SearchPresentation?, previousFile: SearchPresentation?, extras: [LauncherRow] = [], tail: [LauncherRow] = []
    private var filesPending = false, delivered = false
    var onUpdate: ((SearchSnapshot, Bool) -> Void)?
    init(fileQueue: DispatchQueue = DispatchQueue(label: "com.oiloil.find.search", qos: .userInteractive),
         sourceQueue: DispatchQueue = DispatchQueue(label: "com.oiloil.find.sources", qos: .userInitiated)) {
        self.fileQueue = fileQueue; self.sourceQueue = sourceQueue
    }
    private func isCurrent(_ token: Int, request: Int, file: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token && (file ? fileRequest : sourceRequest) == request
    }
    func cancelFiles() { lock.lock(); fileRequest += 1; lock.unlock() }
    func search(raw: String, scope: SearchScope, options: SearchOptions, store: IndexStore?, editingRange: NSRange?, composing: Bool,
                apps: [LauncherApp], clipboard: [ClipboardEntry], clipboardEnabled: Bool,
                calculator: Bool, web: Bool, engine: WebSearchEngine, sources: [SearchSource]? = nil, supplementaryProvider: SupplementarySearchProvider? = nil) {
        lock.lock(); generation += 1; lock.unlock()
        self.raw = raw; self.scope = scope; self.options = options; self.sources = sources ?? Self.primarySource(store); self.supplementaryProvider = supplementaryProvider; self.editingRange = editingRange; self.composing = composing
        previousFile = fileResult ?? previousFile; fileResult = nil; extras = []; tail = []; delivered = false
        filesPending = (scope == .files || scope == .all) && !self.sources.isEmpty
        refreshFiles(sources: self.sources)
        refreshSources(apps: apps, clipboard: clipboard, clipboardEnabled: clipboardEnabled, calculator: calculator, web: web, engine: engine)
    }
    private static func primarySource(_ store: IndexStore?) -> [SearchSource] {
        store.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0)] } ?? []
    }
    func refreshFiles(store: IndexStore?) { refreshFiles(sources: Self.primarySource(store)) }
    func refreshFiles(sources: [SearchSource]) {
        guard scope == .all || scope == .files else { return }
        self.sources = sources
        lock.lock(); fileRequest += 1; let request = fileRequest, token = generation; lock.unlock()
        guard let store = sources.first?.store else {
            fileResult = nil; previousFile = nil; filesPending = false; publish(); return
        }
        let raw = self.raw, options = self.options, range = editingRange, composing = self.composing
        let previous = fileResult ?? previousFile
        let query = Query.parse(raw, store: store, editingRange: range, isComposing: composing, pathExists: { path in
            if sources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            return FileManager.default.fileExists(atPath: path)
        })
        let cancelled = { [weak self] in self?.isCurrent(token, request: request, file: true) != true }
        let supplementary = supplementaryProvider?.isEnabled == true
            ? supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: cancelled) : nil
        let group = DispatchGroup(), box = SupplementarySearchBox()
        if let supplementary {
            group.enter()
            supplementQueue.async { box.hits = supplementary(); group.leave() }
        }
        filesPending = true
        fileQueue.async { [weak self] in
            guard let self, !cancelled() else { return }
            let found: SearchPresentation
            if sources.count == 1 && sources[0].id == "startup" {
                if previous?.single?.store !== store { self.cache.removeAll() }
                guard let result = self.cache.lookup(query: query, options: options, store: store)
                    ?? Searcher.search(query, options: options, in: store, previous: previous?.single, isCancelled: cancelled), !cancelled() else { return }
                self.cache.insert(result); found = SearchPresentation(result)
            } else {
                self.sourceCaches = self.sourceCaches.filter { key, _ in sources.contains { $0.id == key } }
                self.cacheStores = self.cacheStores.filter { key, _ in sources.contains { $0.id == key } }
                for source in sources {
                    let identity = ObjectIdentifier(source.store)
                    if self.cacheStores[source.id] != identity {
                        self.sourceCaches[source.id] = SearchCache(); self.cacheStores[source.id] = identity
                    }
                }
                guard let result = MultiSearcher.search(query, options: options, in: sources, previous: previous?.multiple,
                                                       caches: self.sourceCaches, isCancelled: cancelled), !cancelled() else { return }
                found = SearchPresentation(result)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !cancelled(), found.isCurrent(self.sources) else { return }
                self.fileResult = found; self.previousFile = found
                self.filesPending = supplementary != nil; self.publish()
            }
            if supplementary != nil {
                group.notify(queue: self.fileQueue) { [weak self] in
                    guard let self, !cancelled() else { return }
                    let combined = box.hits.isEmpty ? found : found.supplement(box.hits, options: options)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !cancelled(), combined.isCurrent(self.sources) else { return }
                        self.fileResult = combined; self.previousFile = combined; self.filesPending = false; self.publish()
                    }
                }
            }
        }
    }
    func refreshSources(apps: [LauncherApp], clipboard: [ClipboardEntry], clipboardEnabled: Bool, calculator: Bool, web: Bool, engine: WebSearchEngine) {
        lock.lock(); sourceRequest += 1; let request = sourceRequest, token = generation; lock.unlock()
        let raw = self.raw, scope = self.scope, composing = self.composing
        sourceQueue.async { [weak self] in
            guard let self, self.isCurrent(token, request: request, file: false) else { return }
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var extra: [LauncherRow] = [], tail: [LauncherRow] = []
            if scope == .clipboard {
                if clipboardEnabled {
                    let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    extra = clipboard.filter { $0.matches(words: words) }.map(LauncherRow.clipboard)
                } else { extra = [.enableClipboard] }
            } else if scope != .files {
                if scope == .all || scope == .apps {
                    let found = apps.compactMap { app -> (LauncherApp, Int)? in
                        guard let rank = query.isEmpty ? 0 : LauncherMatch.rank(query, in: [app.name] + app.aliases) else { return nil }
                        return (app, rank)
                    }.sorted {
                        if $0.1 != $1.1 { return $0.1 < $1.1 }
                        if $0.0.lastLaunched != $1.0.lastLaunched { return ($0.0.lastLaunched ?? .distantPast) > ($1.0.lastLaunched ?? .distantPast) }
                        return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
                    }
                    extra += (scope == .all && query.isEmpty ? Array(found.prefix(8)) : found).map { .app($0.0) }
                }
                if scope == .settings || scope == .all && !query.isEmpty { extra += SystemSettingsCatalog.search(query).map(LauncherRow.setting) }
                if scope == .all && !composing {
                    if calculator, let answer = LauncherTools.evaluate(query) { extra.insert(.answer(answer), at: 0) }
                    if let url = LauncherTools.url(query) { extra.insert(.url(url), at: 0) }
                    if web && !query.isEmpty {
                        let search = LauncherTools.explicitWebQuery(query) ?? query
                        if LauncherTools.explicitWebQuery(query) != nil { extra = [.web(search, engine.url(for: search))] }
                        else { tail = [.web(search, engine.url(for: search))] }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token, request: request, file: false) else { return }
                self.extras = extra; self.tail = tail; self.publish()
            }
        }
    }
    private func publish() {
        let snapshot = Self.compose(raw: raw, scope: scope, filePresentation: fileResult, extras: extras, trailing: tail, filesPending: filesPending)
        onUpdate?(snapshot, delivered); delivered = true
    }
    static func compose(raw: String, scope: SearchScope, fileResult: SearchResult?, extras: [LauncherRow], trailing: [LauncherRow] = [], filesPending: Bool = false) -> SearchSnapshot {
        compose(raw: raw, scope: scope, filePresentation: fileResult.map(SearchPresentation.init), extras: extras, trailing: trailing, filesPending: filesPending)
    }
    static func compose(raw: String, scope: SearchScope, filePresentation: SearchPresentation?, extras: [LauncherRow], trailing: [LauncherRow] = [], filesPending: Bool = false) -> SearchSnapshot {
        guard scope == .all else { return SearchSnapshot(raw: raw, scope: scope, filePresentation: scope == .files ? filePresentation : nil, leading: extras, filesPending: filesPending) }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SearchSnapshot(raw: raw, scope: scope, filePresentation: filePresentation, leading: extras,
                                  removedOffsets: duplicateOffsets(filePresentation, leading: extras), filesPending: filesPending)
        }
        var candidates: [(LauncherRow, Int, Int, Int?)] = []
        for row in extras {
            let rank: Int, source: Int
            switch row {
            case .answer, .url, .web: rank = -1; source = -1
            case .app(let app): rank = LauncherMatch.rank(raw, in: [app.name] + app.aliases) ?? 3; source = 0
            case .setting(let setting): rank = LauncherMatch.rank(raw, in: [setting.name] + setting.aliases) ?? 3; source = 1
            default: continue
            }
            candidates.append((row, rank, source, nil))
        }
        if let filePresentation {
            for offset in 0..<min(20, filePresentation.count) {
                guard let item = SearchSnapshot.fileItem(filePresentation, offset: offset), let rank = LauncherMatch.rank(raw, in: [item.name]) else { continue }
                candidates.append((.file(item), rank, 2, offset))
            }
        }
        candidates = candidates.enumerated().sorted {
            if $0.element.1 != $1.element.1 { return $0.element.1 < $1.element.1 }
            if $0.element.2 != $1.element.2 { return $0.element.2 < $1.element.2 }
            return $0.offset < $1.offset
        }.map(\.element)
        var identities: Set<String> = [], leading: [LauncherRow] = [], removed: [Int] = []
        for candidate in candidates where leading.count < 5 {
            guard identities.insert(candidate.0.identity).inserted else { continue }
            leading.append(candidate.0)
        }
        removed = duplicateOffsets(filePresentation, leading: leading)
        return SearchSnapshot(raw: raw, scope: scope, filePresentation: filePresentation, leading: leading, trailing: trailing, removedOffsets: removed, filesPending: filesPending)
    }
    private static func duplicateOffsets(_ filePresentation: SearchPresentation?, leading: [LauncherRow]) -> [Int] {
        guard let filePresentation else { return [] }
        if let single = filePresentation.single, !filePresentation.hasSupplements {
            let ids: [UInt32] = single.store.read {
                leading.compactMap { row in
                    switch row {
                    case .file(let item) where item.source.store === single.store: return item.id
                    case .app(let app): return single.store.hashReady ? single.store.resolve(path: app.path) : nil
                    default: return nil
                    }
                }
            }
            return compactPositions(of: Array(Set(ids)), in: single.items)
        }
        var offsets: Set<Int> = []
        for row in leading {
            switch row {
            case .file(let item):
                if let offset = filePresentation.index(sourceID: item.source.id, store: item.source.store, id: item.id, path: item.path) { offsets.insert(offset) }
            case .app(let app):
                for source in filePresentation.sources {
                    let id = source.store.read { source.store.hashReady ? source.store.resolve(path: app.path) : nil }
                    if let id, let offset = filePresentation.index(sourceID: source.id, store: source.store, id: id, path: app.path) { offsets.insert(offset) }
                }
            default: break
            }
        }
        return offsets.sorted()
    }
    private static func compactPositions(of ids: [UInt32], in items: [UInt32]) -> [Int] {
        guard !ids.isEmpty else { return [] }
        if items.count < 256 { return ids.compactMap { items.firstIndex(of: $0) }.sorted() }
        // Compare all promoted IDs in one vectorized pass over the compact array.
        // Only matching blocks inspect individual lanes; no per-file allocations.
        let targets = ids.map { SIMD16<UInt32>(repeating: $0) }
        var positions = [Int?](repeating: nil, count: ids.count), remaining = ids.count
        items.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset + 16 <= buffer.count && remaining > 0 {
                let block = UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: SIMD16<UInt32>.self)
                var matches = block .== targets[0]
                for index in 1..<targets.count { matches .|= block .== targets[index] }
                if any(matches) {
                    for lane in 0..<16 where matches[lane] {
                        if let target = ids.firstIndex(of: block[lane]), positions[target] == nil {
                            positions[target] = offset + lane; remaining -= 1
                        }
                    }
                }
                offset += 16
            }
            while offset < buffer.count && remaining > 0 {
                if let target = ids.firstIndex(of: base[offset]), positions[target] == nil {
                    positions[target] = offset; remaining -= 1
                }
                offset += 1
            }
        }
        return positions.compactMap { $0 }.sorted()
    }
}
