import Foundation

/// One text-to-speech voice on the device, described without AVFoundation so the choice can be tested.
public struct LearnVoiceCandidate: Equatable, Hashable, Sendable {
    public enum Quality: Int, Sendable, Comparable {
        case standard = 0, enhanced = 1, premium = 2
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var name: String
    public var language: String
    public var quality: Quality
    public var isNovelty: Bool

    public init(id: String, name: String, language: String, quality: Quality, isNovelty: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
    }
}

/// Picks the most natural-sounding English voice for lessons.
///
/// Order of what matters: the voice the learner picked themselves, then quality (premium, then enhanced),
/// then the learner's own kind of English, then voices that are known to sound warm and natural.
/// Novelty voices (bells, whispers, robots) and the older Eloquence voices are pushed to the bottom.
public enum LearnVoiceChoice {
    /// Voices that sound especially natural when the premium or enhanced version is downloaded.
    public static let naturalNames: Set<String> = [
        "Ava", "Zoe", "Evan", "Nathan", "Joelle", "Noelle", "Samantha", "Tom", "Allison", "Susan", "Serena",
        "Daniel", "Kate", "Karen", "Lee", "Moira", "Isha", "Matilda", "Jamie", "Aaron", "Nicky",
    ]

    /// Higher is better. Non-English voices score far below any English one.
    public static func score(_ v: LearnVoiceCandidate, preferredLanguage: String) -> Int {
        var r = 0
        if !v.language.lowercased().hasPrefix("en") { r -= 1000 }
        switch v.quality {
        case .premium: r += 40
        case .enhanced: r += 20
        case .standard: break
        }
        if v.language.caseInsensitiveCompare(preferredLanguage) == .orderedSame { r += 6 }
        let first = v.name.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? v.name
        if naturalNames.contains(first) { r += 4 }
        if v.isNovelty { r -= 100 }
        if v.id.lowercased().contains("eloquence") { r -= 50 }
        return r
    }

    /// English voices, best first. Ties keep a stable order by name.
    public static func ranked(_ voices: [LearnVoiceCandidate], preferredLanguage: String) -> [LearnVoiceCandidate] {
        voices.filter { $0.language.lowercased().hasPrefix("en") && !$0.isNovelty }
            .sorted { a, b in
                let sa = score(a, preferredLanguage: preferredLanguage)
                let sb = score(b, preferredLanguage: preferredLanguage)
                return sa != sb ? sa > sb : a.name < b.name
            }
    }

    /// The voice to use: the picked one if it's still on the device, otherwise the best one.
    public static func best(_ voices: [LearnVoiceCandidate], preferredLanguage: String,
                            picked: String? = nil) -> LearnVoiceCandidate? {
        if let picked, let v = voices.first(where: { $0.id == picked }) { return v }
        return ranked(voices, preferredLanguage: preferredLanguage).first
    }

    /// The English the learner speaks, or US English when the device isn't in English.
    public static func preferredLanguage(deviceLanguage: String) -> String {
        deviceLanguage.lowercased().hasPrefix("en") ? deviceLanguage : "en-US"
    }

    /// True when there's no premium or enhanced English voice, so it's worth telling the learner how to get one.
    public static func shouldSuggestDownload(_ voices: [LearnVoiceCandidate]) -> Bool {
        !voices.contains { $0.language.lowercased().hasPrefix("en") && $0.quality >= .enhanced && !$0.isNovelty }
    }
}
