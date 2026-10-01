//
//  SarvamLanguage.swift
//  SaathiKit
//
//  Saathi's language tags, in Sarvam's spelling.
//
//  Saathi keeps a BCP 47 tag in `shell.json` — "ml", "hi-IN". Sarvam's speech models take their own
//  list of codes: always with the region, always India, and Odia spelled "od" where every other
//  system on this Mac calls it "or". This is the one place that knows the difference.
//

import Foundation

public enum SarvamLanguage {

    /// What Bulbul speaks. Saaras hears all of these and twelve more, but a companion has to do
    /// both, so the shorter list is the list.
    static let spoken: Set<String> = ["bn", "en", "gu", "hi", "kn", "ml", "mr", "od", "pa", "ta", "te"]

    /// Sarvam's code for a tag — "ml" and "ml-IN" are both "ml-IN" — or nil when Sarvam cannot both
    /// hear and speak the language. English is "en-IN" whichever English was asked for: it is the
    /// only one Bulbul has.
    public static func code(for tag: String) -> String? {
        let language = primary(tag)
        let sarvam = language == "or" ? "od" : language
        return spoken.contains(sarvam) ? "\(sarvam)-IN" : nil
    }

    /// The language's name in English, for a sentence that has to say Sarvam does not speak it.
    public static func name(of tag: String) -> String {
        let language = primary(tag)
        return Locale(identifier: "en").localizedString(forLanguageCode: language == "od" ? "or" : language) ?? tag
    }

    private static func primary(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { $0.lowercased() } ?? ""
    }
}
