//
//  OnboardingAnswers.swift
//  SaathiKit
//
//  What an answer to one of first run's four questions means.
//
//  The questions are spoken and so, mostly, are the answers — which means what arrives is a
//  sentence from a speech recogniser, not a form field: "my name is asha", lower-cased, with a
//  full stop it invented. Onboarding that greets someone as "My name is asha." for the rest of
//  their time with it has failed at the first thing it did. So each question has a small, strict
//  reading here, and anything it cannot read is nil: the model asks once more and then moves on
//  with a default, rather than guessing.
//

import Foundation
import SaathiContract

public enum OnboardingQuestion: String, CaseIterable, Sendable {
    case name
    case firstGoal
    case manner
    case language
}

/// How Saathi should speak. Three offers, because a tone and a pace asked separately is two
/// questions about one feeling.
public enum Manner: String, CaseIterable, Sendable {
    case calmAndSlow
    case warmAndNormal
    case plain

    public var tone: Tone {
        switch self {
        case .calmAndSlow: return .calm
        case .warmAndNormal: return .encouraging
        case .plain: return .neutral
        }
    }

    public var pace: Pace {
        switch self {
        case .calmAndSlow: return .slow
        case .warmAndNormal, .plain: return .normal
        }
    }

    /// As offered out loud and on the card.
    public var title: String {
        switch self {
        case .calmAndSlow: return "calm and slow"
        case .warmAndNormal: return "warm and normal"
        case .plain: return "plain"
        }
    }

    /// Words that mean each choice, including its place in the list as it was read out.
    private var cues: [String] {
        switch self {
        case .calmAndSlow: return ["calm", "slow", "first"]
        case .warmAndNormal: return ["warm", "normal", "second", "middle"]
        case .plain: return ["plain", "third", "last"]
        }
    }

    /// The one manner the answer names. Nil when it names none, or more than one.
    public static func parse(_ spoken: String) -> Manner? {
        let words = Set(AnswerParser.words(in: spoken))
        let named = allCases.filter { manner in manner.cues.contains { words.contains($0) } }
        return named.count == 1 ? named[0] : nil
    }
}

public struct OnboardingAnswers: Equatable, Sendable {
    public var name: String?
    public var firstGoal: String?
    public var manner: Manner?
    public var language: String?

    public init(name: String? = nil, firstGoal: String? = nil, manner: Manner? = nil, language: String? = nil) {
        self.name = name
        self.firstGoal = firstGoal
        self.manner = manner
        self.language = language
    }
}

public enum AnswerParser {

    /// Lower-cased words, split on anything that is not a letter, a number or an apostrophe.
    static func words(in text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted
        return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Trimmed of whitespace and of the punctuation a recogniser adds at either end.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// `text` without the longest of `prefixes` it starts with, compared case-insensitively and
    /// only at a word boundary ("I'm" must not eat the start of "Imran").
    static func dropping(_ prefixes: [String], from text: String) -> String {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = text.dropFirst(prefix.count)
            if rest.isEmpty || rest.first == " " || rest.first == "," { return trimmed(String(rest)) }
        }
        return text
    }

    private static let fillers = ["uh", "um", "er", "erm", "hmm", "well", "oh", "so", "hi", "hello", "hey"]

    private static let namePreambles = [
        "my name is", "my name's", "the name is", "the name's", "i am", "i'm", "im",
        "you can call me", "call me", "just call me", "it is", "it's", "its", "this is",
    ]

    /// The name in an answer to "what should I call you?". At most four words: more than that is
    /// a misheard room, not a name.
    public static func name(from spoken: String) -> String? {
        var text = trimmed(spoken)
        text = dropping(fillers, from: text)
        text = dropping(namePreambles, from: text)
        text = trimmed(text)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count <= 4 else { return nil }
        // Only an all-lower-case answer is re-capitalised: that is what a recogniser produces, and
        // "McKenzie" typed by its owner is already right.
        guard text == text.lowercased(), text != text.uppercased() else { return text }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let goalPreambles = [
        "i want to learn", "i'd like to learn", "i would like to learn", "i want to play with",
        "i'd like to play with", "i want to try", "i'd like to try", "i want to", "i'd like to",
        "learn", "to learn", "maybe", "probably",
    ]

    /// What the learner wants to start with, without "I want to learn". Kept in their words: this
    /// is read back to them, and later handed to a model as context.
    public static func goal(from spoken: String) -> String? {
        var text = trimmed(spoken)
        text = dropping(fillers, from: text)
        text = dropping(goalPreambles, from: text)
        text = trimmed(text)
        return text.isEmpty ? nil : text
    }

    /// The supported tag the answer names, by its English name ("Hindi"), by its own name for
    /// itself ("हिन्दी"), or by the tag. Only ever one of `supported`; the first listed region of a
    /// language wins.
    public static func language(from spoken: String, supported: [String]) -> String? {
        let answer = trimmed(spoken)
        guard !answer.isEmpty else { return nil }
        if let exact = supported.first(where: { $0.caseInsensitiveCompare(answer) == .orderedSame }) { return exact }

        let lower = answer.lowercased()
        let english = Locale(identifier: "en")
        for tag in supported {
            let code = Locale(identifier: tag).language.languageCode?.identifier ?? tag
            let names = [
                english.localizedString(forLanguageCode: code),
                Locale(identifier: code).localizedString(forLanguageCode: code),
            ].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
            if names.contains(where: { lower.contains($0) }) { return tag }
        }
        return nil
    }
}
