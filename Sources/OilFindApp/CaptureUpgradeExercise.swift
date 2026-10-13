#if DEBUG
import AppKit

// Only generated documents are written to the caller's validation directory.
// Real history is read for a count and storage check, never printed or copied out.
enum CaptureUpgradeExercise {
    static func handles(_ arguments: [String]) -> Bool { arguments.first == "--capture-upgrade-probe" }
    static func start(_ arguments: [String]) throws {
        guard arguments.count == 3, ["write", "read"].contains(arguments[2]),
              arguments[1].hasPrefix("/"), Bundle.main.object(forInfoDictionaryKey: "OilFindUsesKeyService") as? Bool == true else { throw CaptureFailure.storage }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true), phase = arguments[2]
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let keys = ClipboardKeychain(); _ = try keys.key(createIfMissing: false)
                let oldCount = try ClipboardEncryptedStorage().load().count
                let captures = CaptureArchive(directory: root.appendingPathComponent("captures"), keys: keys, existingMasterArchive: { true })
                let clips = ClipboardEncryptedStorage(io: ClipboardArchiveFile(url: root.appendingPathComponent("clipboard.encrypted")), keys: keys)
                let id = UUID(uuidString: "723F0E53-CC84-4914-83FD-92B7867131D3")!
                if phase == "write" {
                    var document = try CaptureFixtures.document(); document.id = id; document.title = "Synthetic capture upgrade"
                    document.annotations.append(CaptureAnnotation(tool: .redact, rect: CGRect(x: 30, y: 400, width: 180, height: 45)))
                    try captures.save(document, retention: .init(), now: Date())
                    let entry = ClipboardEntry(id: id, text: "Synthetic clipboard upgrade")
                    try clips.save([entry])
                }
                try captures.load()
                guard captures.entries.count == 1, let entry = captures.entries.first else { throw CaptureFailure.storage }
                let document = try captures.document(entry), synthetic = try clips.load()
                guard document.id == id, document.annotations.count == 4, document.annotations.last?.tool == .redact,
                      synthetic.count == 1, synthetic.first?.id == id else { throw CaptureFailure.storage }
                print("PASS fixed-service capture-and-clipboard phase=\(phase) real-clipboard-count=\(oldCount) editable-annotations=\(document.annotations.count)")
                DispatchQueue.main.async { exit(0) }
            } catch {
                fputs("FAIL fixed-service capture upgrade (no key replacement or authorization fallback)\n", stderr)
                DispatchQueue.main.async { exit(1) }
            }
        }
    }
}
#endif
