import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    static let key = "strata.language"
    var id: Self { self }

    static var current: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    var resolved: Self {
        guard self == .system else { return self }
        return Self.preferred(in: Locale.preferredLanguages)
    }

    static func preferred(in languages: [String]) -> Self {
        for identifier in languages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .chinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }

    var locale: Locale {
        Locale(identifier: resolved.rawValue)
    }
}

func tr(_ chinese: String, _ english: String) -> String {
    AppLanguage.current.resolved == .chinese ? chinese : english
}
