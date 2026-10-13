import AppKit
import Darwin
import XCTest
@testable import OilFindApp

final class CapturePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["OILFIND_CAPTURE_PERF"] == "1" else {
            throw XCTSkip("Opt-in synthetic capture benchmark: OILFIND_CAPTURE_PERF=1")
        }
    }
    private func measure(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body(); return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted(), p95 = sorted[max(0, Int(ceil(Double(samples.count) * 0.95)) - 1)]
        print(String(format: "OILFIND_CAPTURE_PERF %@ samples=%d p50_ms=%.3f p95_ms=%.3f", name, samples.count, sorted[samples.count / 2], p95))
    }
    private func memory(_ phase: String) {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { print("OILFIND_CAPTURE_PERF resident_bytes phase=\(phase) bytes=\(info.resident_size) scope=entire_test_process") }
    }
    private func frame(width: Int, height: Int, offset: Int) -> CapturePixels {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let hash = UInt64(y + offset + 1) &* 2654435761 ^ UInt64(x + 1) &* 2246822519, index = (y * width + x) * 4
            bytes[index] = UInt8(truncatingIfNeeded: hash); bytes[index + 1] = UInt8(truncatingIfNeeded: hash >> 8); bytes[index + 2] = UInt8(truncatingIfNeeded: hash >> 16)
        } }
        return CapturePixels(width: width, height: height, bytes: bytes)
    }
    func testCaptureCommandMatchingCost() {
        _ = CaptureAction.search("截图")
        var samples: [Double] = []
        for _ in 0..<500 {
            samples.append(measure { for query in ["readme", "a", "显示器", "screenshot", "截图", "changjietu"] { _ = CaptureAction.search(query) } } / 6)
        }
        report("command_lookup_per_query", samples)
        XCTAssertLessThan(samples.sorted()[474], 5, "Screenshot command matching must fit the 5 ms supplemental-source budget")
    }
    func testEditorRenderingAndResourceUseWithSyntheticImage() throws {
        memory("before_editor")
        var document = CaptureDocument(original: try CaptureRaster(image: frame(width: 2400, height: 1500, offset: 0).image()))
        document.annotations = [
            CaptureAnnotation(tool: .arrow, rect: CGRect(x: 400, y: 200, width: 900, height: 600), points: [CGPoint(x: 400, y: 200), CGPoint(x: 1300, y: 800)]),
            CaptureAnnotation(tool: .redact, rect: CGRect(x: 300, y: 1100, width: 600, height: 200)),
            CaptureAnnotation(tool: .text, rect: CGRect(x: 400, y: 300, width: 1000, height: 150), fontSize: 72, text: "Synthetic 合成截图 🙂")
        ]
        let editor = CaptureEditorController(document: document)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        memory("editor_document_loaded_2400x1500")
        var samples: [Double] = []
        for _ in 0..<20 { try autoreleasepool { samples.append(try measure { _ = try CaptureRenderer.image(document) }) } }
        report("flatten_2400x1500_three_annotations", samples); memory("after_editor_flatten")
        editor.window?.close()
    }
    func testScrollingStitchResourceUseWithSyntheticPages() throws {
        memory("before_scroll")
        let stitcher = CaptureScrollStitcher(), width = 1000, viewport = 700, step = 250
        var samples: [Double] = []
        for page in 0..<6 {
            let frame = frame(width: width, height: viewport, offset: page * step)
            XCTAssertEqual(try stitcher.consume(frame), .waiting)
            var outcome: CaptureScrollStitcher.Outcome?
            samples.append(try measure { outcome = try stitcher.consume(frame) })
            if case .appended = outcome {} else { XCTFail("Unique synthetic rows must append") }
        }
        XCTAssertEqual(stitcher.height, viewport + 5 * step)
        memory("stitched_1000x1950")
        let image = try stitcher.image(); XCTAssertEqual(image.height, 1950)
        report("stable_frame_match_1000x700", samples); memory("after_scroll_output")
    }
}
