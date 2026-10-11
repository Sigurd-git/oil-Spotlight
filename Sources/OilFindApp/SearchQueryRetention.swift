import Foundation

enum SearchQueryRetention: Int, CaseIterable {
    case immediately = 0, minute = 60, fiveMinutes = 300, fifteenMinutes = 900, never = -1

    static func read(from defaults: UserDefaults) -> SearchQueryRetention {
        SearchQueryRetention(rawValue: defaults.object(forKey: "searchQueryRetention") as? Int ?? 60) ?? .minute
    }

    var localizationKey: String {
        switch self {
        case .immediately: return "settings.queryExpiry.immediate"
        case .minute: return "settings.queryExpiry.minute"
        case .fiveMinutes: return "settings.queryExpiry.fiveMinutes"
        case .fifteenMinutes: return "settings.queryExpiry.fifteenMinutes"
        case .never: return "settings.queryExpiry.never"
        }
    }

    func expired(hiddenAt: Date, now: Date) -> Bool {
        self != .never && now.timeIntervalSince(hiddenAt) >= Double(rawValue)
    }
}
