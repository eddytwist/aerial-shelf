import AerialCore
import Foundation

/// UI strings in the app's language: the Mac's language by default (when the app has it), otherwise English,
/// or the language chosen in Settings. English is always there: it is the source language and the fallback.
///
/// English text is the key. Translations live in `Resources/<lang>.lproj/Localizable.strings`,
/// copied into the app bundle by `scripts/build-app.sh`.
@MainActor
enum L {
    /// Language names are written in their own language, without flags.
    static let supported: [(code: String, name: String)] = [("en", "English"), ("ru", "Русский")]
    private(set) static var language = "en"
    private static var table: [String: String] = [:]

    /// The language a choice stands for: `system` becomes the first system language the app has, else English.
    static func resolve(_ choice: String, systemLanguages: [String]? = nil) -> String {
        if choice != RotationState.systemLanguage {
            return supported.contains { $0.code == choice } ? choice : "en"
        }
        let preferred = systemLanguages ?? CustomCategoryNames.systemLanguages
        for identifier in preferred {
            let code = String(identifier.prefix(2))
            if supported.contains(where: { $0.code == code }) { return code }
        }
        return "en"
    }

    static func use(_ choice: String) {
        language = resolve(choice)
        table = [:]
        guard language != "en",
              let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else { return }
        table = dict
    }

    static func t(_ key: String) -> String { table[key] ?? key }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale(identifier: language), arguments: args)
    }

    /// "1 video", "36 videos" / "36 видео" ("видео" does not change with the number in Russian).
    static func videos(_ count: Int) -> String {
        if language == "ru" { return "\(count) видео" }
        return count == 1 ? "1 video" : "\(count) videos"
    }
}
