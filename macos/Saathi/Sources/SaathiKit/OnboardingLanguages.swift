//
//  OnboardingLanguages.swift
//  SaathiKit
//
//  The languages first run can offer: the ones this Mac can actually recognise speech in.
//
//  `SFSpeechRecognizer.supportedLocales()` lists regions, not languages — English alone is a dozen
//  of them — and a row of twelve chips all reading "English" is not a choice anyone can make. So
//  one entry per language: the machine's own region when it speaks that language, otherwise the
//  first region alphabetically. The machine's language leads the list, because `OnboardingModel`
//  takes the first entry as the default when an answer cannot be read.
//

import Foundation
import Speech

public enum OnboardingLanguages {

    public struct Entry: Equatable, Sendable {
        /// BCP 47, e.g. "ta-IN".
        public let tag: String
        /// As shown on the chip: the language's English name.
        public let name: String
    }

    /// What this Mac supports, for the machine's current locale.
    public static func supported() -> [Entry] {
        entries(
            from: SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) },
            machine: Locale.current.identifier(.bcp47))
    }

    /// Pure, so the rule can be tested without a recogniser.
    static func entries(from tags: [String], machine: String) -> [Entry] {
        let english = Locale(identifier: "en")
        let machineLanguage = Locale(identifier: machine).language.languageCode?.identifier

        var byLanguage: [String: String] = [:]
        for tag in tags.sorted() {
            guard let code = Locale(identifier: tag).language.languageCode?.identifier else { continue }
            if tag.caseInsensitiveCompare(machine) == .orderedSame || byLanguage[code] == nil {
                byLanguage[code] = tag
            }
        }

        let all = byLanguage.compactMap { code, tag -> (code: String, entry: Entry)? in
            guard let name = english.localizedString(forLanguageCode: code) else { return nil }
            return (code, Entry(tag: tag, name: name))
        }
        .sorted { $0.entry.name < $1.entry.name }

        let leading = all.filter { $0.code == machineLanguage }
        let rest = all.filter { $0.code != machineLanguage }
        let ordered = (leading + rest).map(\.entry)
        // A Mac with no recogniser at all still has to be able to finish first run.
        return ordered.isEmpty ? [Entry(tag: "en-US", name: "English")] : ordered
    }
}
