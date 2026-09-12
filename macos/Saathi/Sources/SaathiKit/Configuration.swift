//
//  Configuration.swift
//  SaathiKit
//
//  Reading `~/.saathi/shell.json`, and refusing to be careless with the token in it.
//

import Foundation
import SaathiContract

public enum ConfigurationError: Error, CustomStringConvertible, Equatable {
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason): return "cannot read \(path): \(reason)"
        case let .malformed(path, reason): return "\(path) is not valid Saathi config: \(reason)"
        }
    }
}

public enum ConfigurationStore {

    /// `~/.saathi/shell.json`, or whatever `SAATHI_CONFIG` points at (tests and CI use that).
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["SAATHI_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory
            .appendingPathComponent(".saathi", isDirectory: true)
            .appendingPathComponent("shell.json", isDirectory: false)
    }

    /// A missing file is not an error — it means "no token yet, use the hosted default", which is
    /// exactly the state a fresh install is in.
    public static func load(from url: URL) throws -> SaathiConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return SaathiConfiguration() }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigurationError.unreadable(path: url.path, reason: error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(SaathiConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.malformed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Written 0600 from the start. The file holds a bearer token, and a token in a world-readable
    /// file is a token every process on the machine has — OpenClicky shipped that mistake for
    /// months before a review caught it, and it costs nothing to avoid here.
    public static func save(_ configuration: SaathiConfiguration, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)

        // Create with the right mode rather than chmod-ing after: between the two there is a window
        // in which the token is readable, and that window is the whole bug.
        FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
