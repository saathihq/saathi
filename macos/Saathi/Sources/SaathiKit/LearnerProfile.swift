//
//  LearnerProfile.swift
//  SaathiKit
//
//  What first run learned about the learner, as a paragraph for the model that talks to them.
//
//  First run asks four questions and, until this, the answers went into `shell.json` and nowhere
//  else: Saathi asked someone their name and then never used it, asked how they would like to be
//  spoken to and then spoke however the model felt like. This is the other half.
//
//  Two things it is careful about. What the learner typed or said is *their* text going into a
//  system prompt, so it is flattened to one line and clipped — not because they are an adversary,
//  but because a transcript can be a paragraph and a prompt should not grow a stray instruction by
//  accident. And with nothing set it is empty, so an install that never ran first run gets exactly
//  the prompt it had before.
//

import Foundation
import SaathiContract

public enum LearnerProfile {

    static let maxFieldLength = 160

    /// One line, no quotes or line breaks, clipped.
    static func tidied(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = text
            .replacingOccurrences(of: "\"", with: "'")
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > maxFieldLength ? String(flat.prefix(maxFieldLength)) + "…" : flat
    }

    /// How to speak, from the tone and pace first run saved. Nil when neither is set.
    static func manner(tone: Tone?, pace: Pace?) -> String? {
        guard tone != nil || pace != nil else { return nil }
        var parts: [String] = []
        switch tone {
        case .calm: parts.append("They asked you to be calm: an even voice, no exclamation, no hurry in your words.")
        case .encouraging: parts.append("They asked you to be warm: notice what went right before what went wrong.")
        case .neutral: parts.append("They asked you to be plain: no cheerleading, no filler, just what is useful.")
        case .none: break
        }
        switch pace {
        case .slow: parts.append("Go slowly: one idea at a time, short sentences, and leave room after a question.")
        case .normal, .none: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The paragraph, or "" when first run has told us nothing.
    public static func paragraph(for configuration: SaathiConfiguration) -> String {
        var lines: [String] = []
        if let name = tidied(configuration.name) {
            lines.append(
                "The learner asked to be called \(name). Use the name now and then — a greeting, or to "
                + "get their attention — not in every reply.")
        }
        if let goal = tidied(configuration.firstGoal) {
            lines.append(
                "Asked what they wanted to start with, they said: \"\(goal)\". That is where they are "
                + "starting, not a task to do for them, and they may have moved on since.")
        }
        if let manner = manner(tone: configuration.tone, pace: configuration.pace) { lines.append(manner) }
        return lines.joined(separator: " ")
    }
}
