//
//  ActionPerformer.swift
//  SaathiKit
//
//  Performing a contract action. The interesting part is what it refuses to do.
//

import Foundation
import SaathiContract

/// Saying things out loud is the companion's primary output, so it is a protocol from the start:
/// the CLI prints, the app speaks, and the tests assert without either.
public protocol Speaker: Sendable {
    func speak(_ text: String, tone: Tone) async
}

/// Opening things in the world is the other side. Same reason.
public protocol UrlOpener: Sendable {
    func open(_ url: URL) async throws
}

public enum ActionError: Error, CustomStringConvertible, Equatable {
    case unsupportedUrlScheme(String)
    case malformedUrl(String)
    case stepOutOfRange(index: Int, total: Int)

    public var description: String {
        switch self {
        case let .unsupportedUrlScheme(scheme):
            return "refusing to open a \(schemeic: scheme) URL — Saathi opens http and https only"
        case let .malformedUrl(raw):
            return "not a URL Saathi can open: \(raw)"
        case let .stepOutOfRange(index, total):
            return "step \(index) of \(total) is not a step that exists"
        }
    }
}

/// Trivial helper so the error message reads naturally for an empty scheme.
private extension String.StringInterpolation {
    mutating func appendInterpolation(schemeic scheme: String) {
        appendLiteral(scheme.isEmpty ? "scheme-less" : "\"\(scheme)\"")
    }
}

public struct ActionPerformer: Sendable {
    private let speaker: any Speaker
    private let urlOpener: any UrlOpener

    public init(speaker: any Speaker, urlOpener: any UrlOpener) {
        self.speaker = speaker
        self.urlOpener = urlOpener
    }

    public func perform(_ action: SaathiAction) async throws {
        switch action {
        case let .say(say):
            await speaker.speak(say.text, tone: say.tone)

        case let .showStep(step):
            let narration = try Self.narration(for: step)
            await speaker.speak(narration, tone: .encouraging)

        case let .openUrl(open):
            try await urlOpener.open(Self.validated(open.url))
        }
    }

    /// A step is announced with its place in the whole. Someone who cannot see a progress bar still
    /// needs to know how much is left, and someone who can see one is not harmed by hearing it.
    public static func narration(for step: ShowStepAction) throws -> String {
        guard step.total >= 1, step.index >= 1, step.index <= step.total else {
            throw ActionError.stepOutOfRange(index: step.index, total: step.total)
        }
        var sentence = "Step \(step.index) of \(step.total). \(step.title)"
        if !sentence.hasSuffix(".") { sentence += "." }
        if let detail = step.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentence += " \(detail)"
            if !sentence.hasSuffix(".") { sentence += "." }
        }
        return sentence
    }

    /// http(s) only, checked here rather than at the call site.
    ///
    /// The contract says a client MUST reject every other scheme. This is where that happens, and
    /// it is deliberately not a nicety: the URL in an `open_url` action came from a model, which got
    /// it from speech. `file:`, `ssh:`, or a custom scheme registered by some other app all hand
    /// that chain the ability to make the OS do something no one asked for.
    public static func validated(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw ActionError.malformedUrl(raw)
        }
        guard scheme == "http" || scheme == "https" else {
            throw ActionError.unsupportedUrlScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw ActionError.malformedUrl(raw)
        }
        return url
    }
}
