import Foundation
import OilFindCore

enum CaptureAction: String, CaseIterable, Codable {
    case region, window, display, scroll, history, edit, pin, ocr, copyRegion
    var title: String { L10n.text("capture.action." + rawValue) }
    var symbol: String {
        switch self {
        case .region: return "viewfinder"
        case .copyRegion: return "doc.on.clipboard"
        case .window: return "macwindow"
        case .display: return "display"
        case .scroll: return "arrow.down.to.line.compact"
        case .history: return "clock.arrow.circlepath"
        case .edit: return "pencil.tip.crop.circle"
        case .pin: return "pin"
        case .ocr: return "text.viewfinder"
        }
    }
    var aliases: [String] { Self.indexedAliases[self] ?? [] }
    private var matchingAliases: [String] {
        let values: [String]
        switch self {
        case .region: values = ["截图", "截屏", "区域截图", "screenshot", "screen capture"]
        case .copyRegion: values = ["直接截图", "截图到剪贴板", "直接复制截图", "quick screenshot", "copy screenshot"]
        case .window: values = ["窗口截图", "窗口截屏", "window screenshot"]
        case .display: values = ["全屏截图", "全屏截屏", "full screen screenshot"]
        case .scroll: values = ["长截图", "滚动截图", "scrolling screenshot"]
        case .history: values = ["截图历史", "最近截图", "screenshot history"]
        case .edit: values = ["标注图片", "编辑截图", "annotate image", "edit screenshot"]
        case .pin: values = ["钉图文", "钉图", "贴图", "pin image", "pin text"]
        case .ocr: values = ["识字", "文字识别", "ocr", "recognize text"]
        }
        return values + values.flatMap { source -> [String] in
            var full: [UInt8] = [], initials: [UInt8] = []
            guard Array(source.utf8).withUnsafeBufferPointer({ Pinyin.shared.keys(for: $0, full: &full, initials: &initials) }) else { return [] }
            return [String(decoding: full, as: UTF8.self), String(decoding: initials, as: UTF8.self)]
        }
    }
    private static let indexedAliases = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.matchingAliases) })
    static func search(_ query: String) -> [CaptureAction] {
        guard !query.isEmpty else { return [] }
        return allCases.compactMap { action -> (CaptureAction, Int)? in
            LauncherMatch.rank(query, in: indexedAliases[action] ?? []).map { (action, $0) }
        }.sorted { $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 < $1.1 }.map(\.0)
    }
}
