//
//  SkillFile.swift
//  SaathiKit
//
//  A Hermes-style SKILL.md: YAML frontmatter (flat keys, inline `[a, b]` lists) followed by a
//  Markdown body. Ported from OpenClicky's `SkillFile.swift` unchanged apart from access control —
//  the format is shared with the backend's `skillMarkdown.ts`, so a divergence here is a skill the
//  backend wrote and the app then refuses to read.
//
//  Lives in `~/.saathi/skills/library/<id>/SKILL.md`.
//

import Foundation

public struct SkillFile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    /// Bundle identifiers this skill applies to (app-teaching skills only).
    public let apps: [String]
    /// Browser host suffixes this skill applies to (app-teaching skills only).
    public let sites: [String]
    /// Where the skill is injected: "talk" (the spoken turn) and/or "agent" (the doing lane).
    public let surfaces: Set<String>
    /// The toolkit behind the app ("gmail", "youtube"), for app-teaching skills whose app has an
    /// account to connect. Only these get a "Connect <app>" card; nil for plain apps.
    public let integration: String?
    public let body: String

    public var isForTalk: Bool { surfaces.contains("talk") }

    private static let frontmatterPattern = try! NSRegularExpression(pattern: #"^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$"#)
    private static let keyValuePattern = try! NSRegularExpression(pattern: #"^([A-Za-z_][\w-]*):\s*(.*)$"#)

    /// Parses one SKILL.md. Returns nil without frontmatter or without `name` / `description`.
    public static func parse(_ markdown: String, id: String) -> SkillFile? {
        let text = markdown.hasPrefix("\u{FEFF}") ? String(markdown.dropFirst()) : markdown
        let range = NSRange(text.startIndex..., in: text)
        guard let match = frontmatterPattern.firstMatch(in: text, range: range),
              let frontRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else { return nil }

        var fields: [String: String] = [:]
        for line in text[frontRange].components(separatedBy: .newlines) {
            let lineRange = NSRange(line.startIndex..., in: line)
            guard let keyValueMatch = keyValuePattern.firstMatch(in: line, range: lineRange),
                  let keyRange = Range(keyValueMatch.range(at: 1), in: line),
                  let valueRange = Range(keyValueMatch.range(at: 2), in: line) else { continue }
            fields[String(line[keyRange])] = stripQuotes(stripComment(String(line[valueRange])))
        }
        guard let name = fields["name"], !name.isEmpty,
              let description = fields["description"], !description.isEmpty else { return nil }

        let surfaces = fields["surfaces"].map(parseList) ?? ["talk", "agent"]
        return SkillFile(
            id: id,
            name: name,
            description: description,
            apps: fields["apps"].map(parseList) ?? [],
            sites: fields["sites"].map(parseList) ?? [],
            surfaces: Set(surfaces),
            integration: fields["integration"].flatMap { $0.isEmpty ? nil : $0 },
            body: String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Every `<directory>/<id>/SKILL.md`, sorted by id. Missing directory → empty.
    public static func load(directory: URL) -> [SkillFile] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var skills: [SkillFile] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let file = entry.appendingPathComponent("SKILL.md")
            guard let markdown = try? String(contentsOf: file, encoding: .utf8),
                  let skill = parse(markdown, id: entry.lastPathComponent) else { continue }
            skills.append(skill)
        }
        return skills.sorted { $0.id < $1.id }
    }

    // MARK: - Helpers

    /// Drops a trailing ` # comment` from an unquoted scalar — the same rule as `stripComment` in
    /// the backend's `skillMarkdown.ts`, so `surfaces: [talk] # spoken only` reads the same here.
    private static func stripComment(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first == "\"" || first == "'" { return trimmed }
        guard let range = trimmed.range(of: #"\s+#.*$"#, options: .regularExpression) else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// `[a, "b", 'c']` (or a bare comma list) → ["a", "b", "c"].
    private static func parseList(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return inner.split(separator: ",")
            .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}
