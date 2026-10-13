import Foundation
import CryptoKit
import Combine

struct CaptureRetention: Equatable {
    var days = 7, count = 100, bytes = 256 * 1024 * 1024
    init(days: Int = 7, count: Int = 100, bytes: Int = 256 * 1024 * 1024) {
        self.days = min(365, max(1, days)); self.count = min(1000, max(1, count)); self.bytes = max(1, bytes)
    }
}

struct CaptureArchiveEntry: Identifiable, Codable, Equatable {
    let id: UUID, blob: UUID
    let title: String, updatedAt: Date, width: Int, height: Int, bytes: Int
}

// All methods are confined to the history queue. The encrypted manifest commits
// new immutable blobs before removing any previous version.
final class CaptureArchive {
    static var defaultDirectory: URL { ClipboardArchiveFile.defaultURL.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true) }
    let directory: URL
    private let keys: ClipboardKeyProviding, purpose: String
    private let existingMasterArchive: () -> Bool
    var beforeIndexCommit: (() throws -> Void)?
    private var protected = false
    private(set) var entries: [CaptureArchiveEntry] = []
    private var loaded = false
    init(directory: URL = CaptureArchive.defaultDirectory, keys: ClipboardKeyProviding = ClipboardKeychain(), purpose: String = "history",
         existingMasterArchive: @escaping () -> Bool = { FileManager.default.fileExists(atPath: ClipboardArchiveFile.defaultURL.path) }) {
        self.directory = directory; self.keys = keys; self.purpose = purpose; self.existingMasterArchive = existingMasterArchive
    }
    private var index: URL { directory.appendingPathComponent("index.encrypted") }
    private func key() throws -> SymmetricKey {
        let blobs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let exists = FileManager.default.fileExists(atPath: index.path) || blobs.contains { $0.pathExtension == "encrypted" }
        let master = try keys.key(createIfMissing: !exists && !existingMasterArchive())
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("OilFindCapture.v1".utf8), info: Data(purpose.utf8), outputByteCount: 32)
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return try encoder.encode(value) }
    private func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        guard let data = try AES.GCM.seal(plain, using: key, authenticating: Data(("OilFindCapture.v1:" + purpose).utf8)).combined else { throw CaptureFailure.storage }
        return data
    }
    private func open(_ url: URL, limit: Int, key: SymmetricKey) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= limit else { throw CaptureFailure.capacity }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(("OilFindCapture.v1:" + purpose).utf8))
    }
    private func write(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".temporary")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
    @discardableResult func load() throws -> [CaptureArchiveEntry] {
        guard !protected else { throw CaptureFailure.protectedArchive }
        do {
            try prepare()
            if FileManager.default.fileExists(atPath: index.path) {
                entries = try PropertyListDecoder().decode([CaptureArchiveEntry].self, from: open(index, limit: 2 * 1024 * 1024, key: key()))
                guard entries.count <= 1000, Set(entries.map(\.id)).count == entries.count,
                      entries.allSatisfy({ $0.bytes > 0 && $0.bytes <= 96 * 1024 * 1024 && CaptureRaster.accepts(width: $0.width, height: $0.height) }) else { throw CaptureFailure.invalidImage }
            } else {
                guard (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)).allSatisfy({ $0.pathExtension != "encrypted" }) else { throw CaptureFailure.protectedArchive }
                entries = []
            }
            loaded = true; return entries
        } catch { protected = true; throw error }
    }
    func document(_ entry: CaptureArchiveEntry) throws -> CaptureDocument {
        do {
            let value = try PropertyListDecoder().decode(CaptureDocument.self, from: open(blob(entry.blob), limit: 96 * 1024 * 1024, key: key()))
            guard value.valid, value.id == entry.id else { throw CaptureFailure.invalidImage }; return value
        } catch { protected = true; throw error }
    }
    func material(_ entry: CaptureArchiveEntry) throws -> CaptureMaterial {
        do {
            let value = try PropertyListDecoder().decode(CaptureMaterial.self, from: open(blob(entry.blob), limit: 96 * 1024 * 1024, key: key()))
            guard value.valid, value.id == entry.id else { throw CaptureFailure.invalidImage }; return value
        } catch { protected = true; throw error }
    }
    func thumbnail(_ entry: CaptureArchiveEntry) throws -> CaptureRaster {
        do { return try CaptureRaster(data: open(blob(entry.blob, thumbnail: true), limit: 2 * 1024 * 1024, key: key())) }
        catch { protected = true; throw error }
    }
    private func blob(_ id: UUID, thumbnail: Bool = false) -> URL { directory.appendingPathComponent(id.uuidString + (thumbnail ? ".thumbnail" : "") + ".encrypted") }
    func save(_ document: CaptureDocument, retention: CaptureRetention, now: Date) throws {
        guard document.valid else { throw CaptureFailure.invalidImage }
        let thumb = try CaptureRenderer.encode(CaptureRenderer.image(document, maximumDimension: 240), type: .png)
        try save(id: document.id, title: document.title, date: now, width: Int(document.crop.width), height: Int(document.crop.height), data: encode(document), thumbnail: thumb, retention: retention, now: now)
    }
    func save(_ material: CaptureMaterial, now: Date) throws {
        guard material.valid else { throw CaptureFailure.invalidImage }
        // A material stores annotation objects and selected resources, never a base image.
        try save(id: material.id, title: material.title, date: now, width: 1, height: 1, data: encode(material), thumbnail: Data(), retention: .init(days: 365, count: 1000), now: now)
    }
    private func save(id: UUID, title: String, date: Date, width: Int, height: Int, data: Data, thumbnail: Data, retention: CaptureRetention, now: Date) throws {
        guard !protected else { throw CaptureFailure.protectedArchive }
        if !loaded { try load() }
        let key = try key(), blobID = UUID(), sealed = try seal(data, key: key), sealedThumbnail = try seal(thumbnail, key: key)
        let size = sealed.count + sealedThumbnail.count
        guard size <= retention.bytes else { throw CaptureFailure.capacity }
        do {
            try write(sealed, to: blob(blobID)); try write(sealedThumbnail, to: blob(blobID, thumbnail: true))
            var next = entries.filter { $0.id != id }
            next.insert(.init(id: id, blob: blobID, title: title, updatedAt: date, width: width, height: height, bytes: size), at: 0)
            try commit(pruned(next, retention: retention, now: now), key: key)
        } catch {
            // Never touch old versions when the index transaction fails.
            if !entries.contains(where: { $0.blob == blobID }) { try? FileManager.default.removeItem(at: blob(blobID)); try? FileManager.default.removeItem(at: blob(blobID, thumbnail: true)) }
            throw error
        }
    }
    private func pruned(_ source: [CaptureArchiveEntry], retention: CaptureRetention, now: Date) -> [CaptureArchiveEntry] {
        var bytes = 0
        return Array(source.sorted { $0.updatedAt > $1.updatedAt }.filter { entry in
            guard (purpose == "materials" || entry.updatedAt > now.addingTimeInterval(-Double(retention.days) * 86400)), bytes + entry.bytes <= retention.bytes else { return false }
            bytes += entry.bytes; return true
        }.prefix(retention.count))
    }
    func prune(retention: CaptureRetention, now: Date) throws {
        guard !protected else { throw CaptureFailure.protectedArchive }; if !loaded { try load() }
        let next = pruned(entries, retention: retention, now: now)
        if next != entries { try commit(next, key: key()) }
    }
    func remove(_ id: UUID?) throws {
        guard !protected else { throw CaptureFailure.protectedArchive }; if !loaded { try load() }
        try commit(id.map { id in entries.filter { $0.id != id } } ?? [], key: key())
    }
    private func commit(_ next: [CaptureArchiveEntry], key: SymmetricKey) throws {
        try beforeIndexCommit?()
        try write(seal(encode(next), key: key), to: index)
        let previous = entries; entries = next
        for old in previous where !next.contains(where: { $0.blob == old.blob }) {
            try? FileManager.default.removeItem(at: blob(old.blob)); try? FileManager.default.removeItem(at: blob(old.blob, thumbnail: true))
        }
    }
    func retryLoad() throws { protected = false; loaded = false; try load() }
}

final class CaptureHistory: ObservableObject {
    @Published private(set) var entries: [CaptureArchiveEntry] = []
    @Published private(set) var materials: [CaptureArchiveEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var pending = 0
    private let queue = DispatchQueue(label: "com.oiloil.find.capture-storage", qos: .utility)
    private let archive: CaptureArchive, materialArchive: CaptureArchive
    private var loaded = false
    private var snapshotThumbnail: CaptureRaster?
    var enabled = true
    var retention = CaptureRetention()
    init(archive: CaptureArchive = CaptureArchive(), materialArchive: CaptureArchive = CaptureArchive(directory: CaptureArchive.defaultDirectory.deletingLastPathComponent().appendingPathComponent("capture-materials"), purpose: "materials")) {
        self.archive = archive; self.materialArchive = materialArchive
    }
    func load() {
        guard !loaded else { return }; loaded = true
        let retention = self.retention
        perform { [self] in try archive.load(); try materialArchive.load(); try archive.prune(retention: retention, now: Date()) }
    }
    private func perform(_ work: @escaping () throws -> Void, completion: ((Bool) -> Void)? = nil) {
        pending += 1
        queue.async { [self] in
            let failure: Error?; do { try work(); failure = nil } catch { failure = error }
            let entries = archive.entries, materials = materialArchive.entries
            DispatchQueue.main.async { [self] in
                pending -= 1; self.entries = entries; self.materials = materials
                error = failure.map { $0.localizedDescription }; completion?(failure == nil)
            }
        }
    }
    func save(_ document: CaptureDocument, completion: @escaping (Bool) -> Void) {
        guard enabled else { completion(true); return }
        let retention = self.retention
        perform({ [archive] in try archive.save(document, retention: retention, now: Date()) }, completion: completion)
    }
    func save(_ material: CaptureMaterial) { perform { [materialArchive] in try materialArchive.save(material, now: Date()) } }
    func configure(enabled: Bool, retention: CaptureRetention) {
        self.enabled = enabled; self.retention = retention
        if loaded { perform { [archive] in try archive.prune(retention: retention, now: Date()) } }
    }
    func remove(_ id: UUID?) { perform { [archive] in try archive.remove(id) } }
    func retry() { perform { [archive, materialArchive] in try archive.retryLoad(); try materialArchive.retryLoad() } }
    func read(_ entry: CaptureArchiveEntry, completion: @escaping (Result<CaptureDocument, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try archive.document(entry) }
            DispatchQueue.main.async { if case .failure(let error) = result { self.error = error.localizedDescription }; completion(result) }
        }
    }
    func readMaterial(_ entry: CaptureArchiveEntry, completion: @escaping (Result<CaptureMaterial, Error>) -> Void) {
        queue.async { [self] in let result = Result { try materialArchive.material(entry) }; DispatchQueue.main.async { if case .failure(let error) = result { self.error = error.localizedDescription }; completion(result) } }
    }
    func thumbnail(_ entry: CaptureArchiveEntry, completion: @escaping (CaptureRaster?) -> Void) {
        if let snapshotThumbnail { completion(snapshotThumbnail); return }
        queue.async { [self] in
            let result = Result { try archive.thumbnail(entry) }
            DispatchQueue.main.async { switch result { case .success(let image): completion(image); case .failure(let error): self.error = error.localizedDescription; completion(nil) } }
        }
    }
    #if DEBUG
    func prepareSnapshot(_ entries: [CaptureArchiveEntry], thumbnail: CaptureRaster) {
        loaded = true; self.entries = entries; snapshotThumbnail = thumbnail
    }
    #endif
    func flush() { queue.sync {} }
}
