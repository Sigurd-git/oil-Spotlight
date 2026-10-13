import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OilFindApp

final class ClipboardImageTests: XCTestCase {
    private func image(_ type: UTType = .png, frames: Int = 1, red: CGFloat = 0.25, orientation: Int = 1) throws -> ClipboardImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type.identifier as CFString, frames, nil))
        for index in 0..<frames {
            context.setFillColor(CGColor(red: red, green: CGFloat(index + 1) / CGFloat(frames + 1), blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 2, y: 3, width: 11, height: 19))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try XCTUnwrap(ClipboardImage(data: bytes as Data))
    }

    private func board() -> NSPasteboard {
        let result = NSPasteboard(name: .init("test.oilfind.clipboard-image.\(UUID().uuidString)"))
        addTeardownBlock { result.releaseGlobally() }
        return result
    }

    private func write(_ data: Data, type: NSPasteboard.PasteboardType = .png, to board: NSPasteboard,
                       additional: [(NSPasteboard.PasteboardType, Data)] = []) {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(data, forType: type))
        for (type, data) in additional { XCTAssertTrue(item.setData(data, forType: type)) }
        board.clearContents(); XCTAssertTrue(board.writeObjects([item]))
    }

    private func defaults() -> UserDefaults {
        let name = "test.oilfind.clipboard-image.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testPNGJPEGGIFTIFFAndBMPDecodeAndPreserveBytes() throws {
        for type in [UTType.png, .jpeg, .gif, .tiff, .bmp] {
            let original = try image(type)
            XCTAssertEqual(original.typeIdentifier, type.identifier)
            XCTAssertEqual(original.width, 48); XCTAssertEqual(original.height, 32)
            XCTAssertEqual(try PropertyListDecoder().decode(ClipboardImage.self, from: PropertyListEncoder().encode(original)), original)
            let thumbnail = try XCTUnwrap(original.thumbnail(maximumSize: 12))
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 12)
            let png = try XCTUnwrap(try original.compatiblePNG())
            XCTAssertEqual(ClipboardImage(data: png)?.typeIdentifier, UTType.png.identifier)
        }
    }

    func testHEICImageDecodeAndPNGCompatibility() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true
        else { throw XCTSkip("ImageIO on this OS does not provide an HEIC encoder") }
        let original = try image(.heic)
        XCTAssertEqual(original.typeIdentifier, UTType.heic.identifier)
        XCTAssertEqual(ClipboardImage(data: try XCTUnwrap(try original.compatiblePNG()))?.width, 48)
    }

    func testLosslessWebPDecodesPreservesOriginalAndOffersPNG() throws {
        // A synthetic 48 × 32 solid-color WebP, not a downloaded/private image.
        let bytes = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvL8AHAAfQr46Utv+BiOh/AAA="))
        let original = try XCTUnwrap(ClipboardImage(data: bytes))
        XCTAssertEqual(original.typeIdentifier, "org.webmproject.webp")
        XCTAssertEqual(original.width, 48); XCTAssertEqual(original.height, 32)
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        write(bytes, type: .init(original.typeIdentifier), to: board)
        XCTAssertEqual(adapter.readContent(), .image(original))
        XCTAssertEqual(ClipboardImage(data: try XCTUnwrap(try original.compatiblePNG()))?.height, 32)
    }

    func testScreenshotPNGPreferredOverTIFFButAnimatedGIFKeepsOriginal() throws {
        let png = try image(), tiff = try image(.tiff), gif = try image(.gif, frames: 2)
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        write(tiff.data, type: .tiff, to: board, additional: [(.png, png.data)])
        XCTAssertEqual(adapter.readContent(), .image(png))
        write(png.data, to: board, additional: [(.init(UTType.gif.identifier), gif.data)])
        XCTAssertEqual(adapter.readContent(), .image(gif))
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithData(gif.data as CFData, nil))), 2)
    }

    func testCorruptPreferredRepresentationFallsBackToValidTIFFWithoutURLCapture() throws {
        let tiff = try image(.tiff), board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        write(Data([1, 2, 3]), to: board, additional: [(.tiff, tiff.data), (.string, Data("https://example.test/image".utf8))])
        XCTAssertEqual(adapter.readContent(), .image(tiff))
        var result: ClipboardContent?, completed = false
        adapter.readContent { result = $0; completed = true }; waitFor { completed }
        XCTAssertEqual(result, .image(tiff))
    }

    func testPNGCompatibilityAppliesAllEXIFRotationAndMirrorOrientations() throws {
        func pixels(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
        for orientation in 1...8 {
            let original = try image(.tiff, orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(original.data as CFData, nil))
            XCTAssertEqual((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int, orientation)
            let fallback = try XCTUnwrap(ClipboardImage(data: XCTUnwrap(try original.compatiblePNG())))
            XCTAssertEqual(fallback.width, orientation >= 5 ? 32 : 48)
            XCTAssertEqual(fallback.height, orientation >= 5 ? 48 : 32)
            XCTAssertEqual(try pixels(XCTUnwrap(fallback.thumbnail(maximumSize: 64))),
                           try pixels(XCTUnwrap(original.thumbnail(maximumSize: 64))), "orientation \(orientation)")
        }
    }

    func testSensitiveTransientAutogeneratedAndOwnImagesAreIgnored() throws {
        let picture = try image(), board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                       ClipboardSystemPasteboard.ownCopyType.rawValue] {
            write(picture.data, to: board, additional: [(.init(marker), Data([1]))])
            XCTAssertNil(adapter.readContent(), marker)
        }
    }

    func testFinderImageFileStaysAReferenceWithoutReadingFileBody() throws {
        let picture = try image(), board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        let path = "/nonexistent/synthetic-screenshot.png"
        write(picture.data, to: board, additional: [(.fileURL, Data(URL(fileURLWithPath: path).absoluteString.utf8))])
        XCTAssertEqual(adapter.readContent(), .files([path]))
    }

    func testCorruptOversizeAndMislabelledMetadataNeverFallBackToBrowserURL() throws {
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        for data in [Data([1, 2, 3]), Data(repeating: 0, count: ClipboardImage.maximumBytes + 1)] {
            XCTAssertNil(ClipboardImage(data: data))
            write(data, to: board, additional: [(.string, Data("https://example.test/private-image".utf8))])
            XCTAssertNil(adapter.readContent())
        }
        let encoded = try PropertyListEncoder().encode(image())
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        plist["width"] = 999_999
        let forged = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertThrowsError(try PropertyListDecoder().decode(ClipboardImage.self, from: forged))
    }

    func testImageSearchAndDedupKeepStableIDAndLatestSource() throws {
        let picture = try image(), now = Date()
        var store = ClipboardHistoryStore(now: now)
        let first = ClipboardEntry(content: .image(picture), copiedAt: now.addingTimeInterval(-10), sourceName: "Screenshot")
        XCTAssertTrue(store.record(first, now: now))
        XCTAssertTrue(store.record(ClipboardEntry(content: .image(picture), copiedAt: now, sourceName: "Preview"), now: now))
        XCTAssertEqual(store.entries.count, 1); XCTAssertEqual(store.entries[0].id, first.id)
        XCTAssertEqual(store.entries[0].sourceName, "Preview")
        for query in ["截图", "image", "PNG", "48", "Preview"] { XCTAssertEqual(store.search(query).count, 1, query) }
        XCTAssertTrue(store.search("missing content").isEmpty)
    }

    func testImageHistoryPrunesByTotalBytesAgeCountAndExcludedSource() throws {
        let now = Date()
        var entries: [ClipboardEntry] = []
        for index in 0..<3 {
            var bytes = try image(red: CGFloat(index + 1) / 5).data
            bytes.append(Data(repeating: 0, count: 12 * 1024 * 1024 - bytes.count))
            entries.append(ClipboardEntry(content: .image(try XCTUnwrap(ClipboardImage(data: bytes))),
                                          copiedAt: now.addingTimeInterval(-Double(index))))
        }
        var store = ClipboardHistoryStore(entries: entries, now: now)
        XCTAssertEqual(store.entries.map(\.id), Array(entries.prefix(2)).map(\.id))
        XCTAssertLessThanOrEqual(store.entries.reduce(0) { $0 + $1.storageBytes }, ClipboardHistoryStore.maximumTotalBytes)
        store.configure(days: 7, items: 1, exclusions: [], now: now)
        XCTAssertEqual(store.entries.first?.id, entries[0].id); XCTAssertEqual(store.entries.count, 1)
        let picture = try image()
        XCTAssertFalse(store.record(ClipboardEntry(content: .image(picture), copiedAt: now.addingTimeInterval(-8 * 86_400)), now: now))
        store.configure(days: 7, items: 500, exclusions: ["test.excluded"], now: now)
        XCTAssertFalse(store.record(ClipboardEntry(content: .image(picture), copiedAt: now, sourceBundleID: "test.excluded.helper"), now: now))
    }

    func testMixedEncryptedArchiveRestoresImagesAndOldTextWithoutPlaintextPixels() throws {
        let picture = try image(), io = ImageTestArchive(), keys = ImageTestKeys()
        let text = ClipboardEntry(text: "synthetic legacy text"), files = ClipboardEntry(content: .files(["/synthetic/image.png"]))
        let values = [ClipboardEntry(content: .image(picture)), text, files]
        let storage = ClipboardEncryptedStorage(io: io, keys: keys)
        try storage.save(values)
        let bytes = try XCTUnwrap(io.data)
        XCTAssertNil(bytes.range(of: picture.data)); XCTAssertNil(bytes.range(of: Data(text.text.utf8)))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keys.value,
                                       authenticating: Data("OilFindClipboard.v1".utf8))
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: plaintext, format: nil) as? [String: Any])
        XCTAssertEqual(archive["version"] as? Int, 2)
        XCTAssertEqual(try ClipboardEncryptedStorage(io: io, keys: keys).load(), values)
        io.data![bytes.count / 2] ^= 1
        let broken = ClipboardEncryptedStorage(io: io, keys: keys)
        XCTAssertThrowsError(try broken.load()); let preserved = io.data
        XCTAssertThrowsError(try broken.save([])); XCTAssertEqual(io.data, preserved)
    }

    func testAsyncCaptureRejectsOldClipboardAndClearPauseStopOrExclusion() throws {
        let picture = try image()
        for action in ["clear", "pause", "stop", "exclude", "revision"] {
            let board = ImageTestDelayedPasteboard(), history = ClipboardHistory(defaults: defaults(), storage: ImageTestStorage(),
                                                                                pasteboard: board, source: { ("test.source", "Synthetic") })
            history.start(); history.enabled = true
            board.changeCount += 1; history.pollOnce()
            let callback = try XCTUnwrap(board.callbacks.last)
            switch action {
            case "clear": history.clear()
            case "pause": history.paused = true
            case "stop": history.stop(); history.start()
            case "exclude": history.excludedAppIDs = ["test.source"]
            default: board.changeCount += 1
            }
            callback(.image(picture))
            XCTAssertTrue(history.entries.isEmpty, action)
            history.stop()
        }
    }

    func testAsyncImageLatestCopyWinsAndNoReadsBeforeOptIn() throws {
        let board = ImageTestDelayedPasteboard(), history = ClipboardHistory(defaults: defaults(), storage: ImageTestStorage(), pasteboard: board)
        history.start(); history.pollOnce(); XCTAssertTrue(board.callbacks.isEmpty)
        history.enabled = true
        board.changeCount += 1; history.pollOnce(); let first = try XCTUnwrap(board.callbacks.last)
        board.changeCount += 1; history.pollOnce(); let last = try XCTUnwrap(board.callbacks.last)
        let newer = try image(red: 0.8)
        last(.image(newer)); first(.image(try image()))
        XCTAssertEqual(history.entries.map(\.image), [newer])
        history.stop()
    }

    func testImageRestoreCopiesOriginalAndPNGForNativePasteWithoutFeedback() throws {
        let picture = try image(.gif, frames: 2), board = board()
        let adapter = ClipboardSystemPasteboard(pasteboard: board)
        let history = ClipboardHistory(defaults: defaults(), storage: ImageTestStorage(), pasteboard: adapter)
        let entry = ClipboardEntry(content: .image(picture)); var outcome: ClipboardCopyOutcome?
        history.copy(entry) { outcome = $0 }; waitFor { outcome != nil }
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(board.data(forType: .init(UTType.gif.identifier)), picture.data)
        XCTAssertNotNil(board.data(forType: .png)); XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertNil(adapter.readContent())
        XCTAssertTrue(history.isClipboardCurrent(try XCTUnwrap(history.latestCopyToken)))
    }

    func testImageCopyRechecksSelectionAndKeepsExistingClipboardOnCancellation() throws {
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        XCTAssertTrue(adapter.writeText("synthetic untouched")); let revision = board.changeCount
        let history = ClipboardHistory(defaults: defaults(), storage: ImageTestStorage(), pasteboard: adapter)
        var current = true, outcome: ClipboardCopyOutcome?
        history.copy(ClipboardEntry(content: .image(try image(.jpeg))), isCurrent: { current }) { outcome = $0 }
        current = false; waitFor { outcome != nil }
        XCTAssertEqual(outcome, .cancelled); XCTAssertEqual(board.changeCount, revision)
        XCTAssertEqual(board.string(forType: .string), "synthetic untouched")
    }

    func testClipboardChangeDuringImagePreparationPreservesNewerUserCopy() throws {
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        let history = ClipboardHistory(defaults: defaults(), storage: ImageTestStorage(), pasteboard: adapter)
        var outcome: ClipboardCopyOutcome?
        history.copy(ClipboardEntry(content: .image(try image(.jpeg)))) { outcome = $0 }
        XCTAssertTrue(adapter.writeText("synthetic newer user copy"))
        let revision = board.changeCount
        waitFor { outcome != nil }
        XCTAssertEqual(outcome, .cancelled); XCTAssertEqual(board.changeCount, revision)
        XCTAssertEqual(board.string(forType: .string), "synthetic newer user copy")
    }

    func testNewestPendingSystemImageIsCapturedAndEarlierPendingIsCancelled() throws {
        let board = board(), adapter = ClipboardSystemPasteboard(pasteboard: board)
        let images = try [image(red: 0.1), image(red: 0.5), image(red: 0.9)]
        var completions: [Int: ClipboardContent?] = [:]
        for index in images.indices {
            write(images[index].data, to: board)
            adapter.readContent { completions[index] = .some($0) }
        }
        waitFor { completions.count == 3 }
        XCTAssertEqual(completions[0]!, .image(images[0]))
        XCTAssertNil(completions[1]!)
        XCTAssertEqual(completions[2]!, .image(images[2]))
    }

    func testSnapshotImagesAreSyntheticAndThumbnailCallbacksRunOnMain() throws {
        let fixture = try Snapshot.launcherFixture(state: "clipboard-images")
        let picture = try XCTUnwrap(fixture.clipboard.first?.image)
        XCTAssertEqual(picture.width, 640); XCTAssertEqual(picture.height, 360)
        XCTAssertEqual(fixture.snapshot.scope, .clipboard)
        let icons = IconProvider(); var calls = 0
        for _ in 0..<2 {
            icons.clipboardImage(picture) { rendered in
                XCTAssertTrue(Thread.isMainThread); XCTAssertLessThanOrEqual(rendered.size.width, 64); calls += 1
            }
        }
        waitFor { calls == 2 && icons.isIdle }
    }
}

private final class ImageTestArchive: ClipboardArchiveIO {
    var data: Data?
    func read() throws -> Data? { data }
    func writeAtomically(_ data: Data) throws { self.data = data }
}
private final class ImageTestKeys: ClipboardKeyProviding {
    let value = SymmetricKey(data: Data(repeating: 7, count: 32))
    func key(createIfMissing: Bool) throws -> SymmetricKey { value }
}
private final class ImageTestStorage: ClipboardHistoryPersisting {
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {}
}
private final class ImageTestDelayedPasteboard: ClipboardPasteboardReading {
    var changeCount = 0
    let canReadWithoutPrompt = true
    var callbacks: [(ClipboardContent?) -> Void] = []
    func readText() -> String? { nil }
    func writeText(_ text: String) -> Bool { changeCount += 1; return true }
    func readContent(completion: @escaping (ClipboardContent?) -> Void) { callbacks.append(completion) }
}
