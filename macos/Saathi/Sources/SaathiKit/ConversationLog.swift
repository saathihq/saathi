//
//  ConversationLog.swift
//  SaathiKit
//
//  What was said, kept. Until this existed a voice turn left nothing behind: the transcripts came
//  in, moved the companion's face, and were dropped. "What did I ask and what did it say back?"
//  had no answer, which is a poor place to be when what it said back was wrong.
//
//  One file, `~/.saathi/conversation.log`, one line per thing that happened: what you said, what
//  Saathi said, what the screen look was asked and what it answered, which action was performed,
//  and any failure. It stays on this machine, at the same 0600 the settings file uses, and it is
//  written on its own queue so a slow disk never sits in the audio path.
//

import Foundation

public final class ConversationLog: @unchecked Sendable {

    public enum Entry: Equatable, Sendable {
        case you(String)
        case saathi(String)
        /// A screen look: what the voice model asked the eyes, and what they answered.
        case look(question: String, answer: String)
        /// An action the model asked for, in the contract's wire name plus a word about it.
        case action(String)
        case error(String)
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "dev.saathi.conversation-log", qos: .utility)

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// `conversation.log`, next to `shell.json`.
    public static func defaultURL(beside configuration: URL) -> URL {
        configuration.deletingLastPathComponent().appendingPathComponent("conversation.log", isDirectory: false)
    }

    public var fileURL: URL { url }

    public func append(_ entry: Entry) {
        let line = Self.line(entry, at: now())
        queue.async { [url] in
            let data = Data((line + "\n").utf8)
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // Created 0600 from the start, like the settings file: what someone said to their
                // computer is theirs.
                _ = FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }

    /// Waits for everything appended so far to be on disk. For the tests.
    public func flush() {
        queue.sync {}
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// One line: the time, a label padded so the text lines up, and the text on one line.
    public static func line(_ entry: Entry, at date: Date) -> String {
        let (label, text): (String, String)
        switch entry {
        case let .you(said): (label, text) = ("you", said)
        case let .saathi(said): (label, text) = ("saathi", said)
        case let .look(question, answer): (label, text) = ("look", "asked: \(question) — answered: \(answer)")
        case let .action(what): (label, text) = ("action", what)
        case let .error(what): (label, text) = ("error", what)
        }
        let flattened = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(stamp.string(from: date))  \(label.padding(toLength: 7, withPad: " ", startingAt: 0))\(flattened)"
    }
}
