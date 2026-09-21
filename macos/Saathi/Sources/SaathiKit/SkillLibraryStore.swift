//
//  SkillLibraryStore.swift
//  SaathiKit
//
//  The user's skill library, as the island's Home tab sees it. Ported from OpenClicky's
//  `SkillLibraryStore.swift`; the on-disk layout is the same one, under Saathi's directory:
//
//    ~/.saathi/skills/library/<id>/SKILL.md   one folder per skill (created here or dropped in by hand)
//    ~/.saathi/skills/activations.json        { "active": [ids], "updatedAt": ISO-8601 }
//    ~/.saathi/skills/active/<id> → library/<id>   symlinks for activated skills only
//
//  The `active/` symlink directory is not decoration: it is the single path a future agent lane can
//  be pointed at without teaching it to read activations.json, which is why it is kept in sync here
//  rather than computed at the point of use.
//

import Combine
import Foundation
import SaathiContract

@MainActor
public final class SkillLibraryStore: ObservableObject {
    @Published public private(set) var librarySkills: [SkillFile] = []
    @Published public private(set) var activeIds: Set<String> = []
    @Published public private(set) var appSkills: [SkillFile] = []
    @Published public var lastError: String?
    @Published public var isCreating = false

    public let userSkillsDirectory: URL
    public let appSkillsDirectory: URL

    /// Drafts a skill on the backend. Injected so the panel can be built and tested without one.
    private let draft: (String, [String]) async throws -> String

    /// Watches `library/` (skills added or removed) and the root (activations.json rewritten from
    /// elsewhere), so a skill dropped into the folder by hand shows up without a relaunch.
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadDebounce: DispatchWorkItem?

    public var libraryDirectory: URL { userSkillsDirectory.appendingPathComponent("library", isDirectory: true) }
    public var activeDirectory: URL { userSkillsDirectory.appendingPathComponent("active", isDirectory: true) }
    public var activationsURL: URL { userSkillsDirectory.appendingPathComponent("activations.json") }

    /// Activated skills that apply to a spoken turn.
    public var activeTalkSkills: [SkillFile] {
        librarySkills.filter { activeIds.contains($0.id) && $0.isForTalk }
    }

    /// `~/.saathi/skills`, or a sibling of whatever `SAATHI_CONFIG` points at — so a test or a CI
    /// run that redirects the config file takes the skills with it rather than writing into the
    /// developer's own library.
    nonisolated public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ConfigurationStore.defaultPath(environment: environment, homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// `configuration` is asked at every draft rather than captured once: the store lives for the
    /// life of the app, and a configuration swapped in by a reconfigure must be the one drafted with.
    public convenience init(configuration: @escaping @MainActor () -> SaathiConfiguration) {
        let directory = Self.defaultDirectory()
        self.init(
            userSkillsDirectory: directory,
            appSkillsDirectory: directory.appendingPathComponent("app", isDirectory: true),
            draft: { request, capabilities in
                let client = try BackendClient(configuration: configuration())
                return try await client.createSkill(request: request, capabilities: capabilities).markdown
            }
        )
    }

    public init(
        userSkillsDirectory: URL,
        appSkillsDirectory: URL,
        watch: Bool = true,
        draft: @escaping (String, [String]) async throws -> String = { _, _ in throw SkillLibraryError.notConfigured }
    ) {
        self.userSkillsDirectory = userSkillsDirectory
        self.appSkillsDirectory = appSkillsDirectory
        self.draft = draft
        ensureDirectories()
        reload()
        if watch { startWatching() }
    }

    deinit {
        watchers.forEach { $0.cancel() }
    }

    // MARK: - Reading

    /// Re-reads the library, the activations, and the app skills; drops stale `active/` links.
    ///
    /// `clearingErrors`: an explicit reload (launch, a click) drops a stale `lastError` from an
    /// earlier failure; a background reload (the directory watcher, the reload after a failed save)
    /// keeps it so the panel still shows what went wrong.
    public func reload(clearingErrors: Bool = true) {
        ensureDirectories()
        librarySkills = SkillFile.load(directory: libraryDirectory)
        let known = Set(librarySkills.map(\.id))
        activeIds = Set(readActivations().filter { known.contains($0) })
        appSkills = SkillFile.load(directory: appSkillsDirectory)
        if clearingErrors { lastError = nil }
        syncActiveDirectory()
    }

    private func readActivations() -> [String] {
        guard let data = try? Data(contentsOf: activationsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = object["active"] as? [Any] else { return [] }
        return active.compactMap { $0 as? String }
    }

    // MARK: - Activation

    public func setActive(_ id: String, _ on: Bool) {
        var ids = readActivations().filter { $0 != id }
        if on { ids.append(id) }
        do {
            try writeActivations(ids)
            reload()
        } catch {
            lastError = "Could not save activations: \(error.localizedDescription)"
            reload(clearingErrors: false)
        }
    }

    private func writeActivations(_ ids: [String]) throws {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let payload: [String: Any] = ["active": unique, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: activationsURL, atomically: true, encoding: .utf8)
    }

    /// `active/` holds exactly one symlink per activated existing skill.
    private func syncActiveDirectory() {
        let fileManager = FileManager.default
        let wanted = librarySkills.map(\.id).filter { activeIds.contains($0) }
        let existing = (try? fileManager.contentsOfDirectory(atPath: activeDirectory.path)) ?? []
        for entry in existing where !wanted.contains(entry) {
            try? fileManager.removeItem(at: activeDirectory.appendingPathComponent(entry))
        }
        for id in wanted {
            let link = activeDirectory.appendingPathComponent(id)
            let target = libraryDirectory.appendingPathComponent(id, isDirectory: true)
            if let current = try? fileManager.destinationOfSymbolicLink(atPath: link.path), current == target.path { continue }
            try? fileManager.removeItem(at: link)
            do {
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            } catch let error as NSError where Self.isAlreadyExists(error) {
                continue // another writer linked it first
            } catch {
                lastError = "Could not link \(id) into active/: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Creating

    /// Writes a SKILL.md into the library under a unique id derived from its name, and activates it.
    @discardableResult
    public func importSkill(markdown: String) throws -> SkillFile {
        guard let parsed = SkillFile.parse(markdown, id: "pending") else {
            throw SkillLibraryError.invalidMarkdown
        }
        ensureDirectories()
        let base = Self.slugify(parsed.name)
        // The id is claimed by creating its directory non-recursively: EEXIST means another writer
        // owns it, so try the next suffix. SKILL.md is never written into a folder we did not make.
        var id = base
        var suffix = 2
        var folder = libraryDirectory.appendingPathComponent(id, isDirectory: true)
        while true {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                break
            } catch let error as NSError where Self.isAlreadyExists(error) {
                id = "\(base)-\(suffix)"
                suffix += 1
                folder = libraryDirectory.appendingPathComponent(id, isDirectory: true)
            }
        }
        let text = markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        do {
            try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            // The folder was made here and holds nothing: left behind it would claim the id for
            // good, and every retry would land on "-2", "-3", ….
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        setActive(id, true)
        guard let skill = librarySkills.first(where: { $0.id == id }) else { throw SkillLibraryError.invalidMarkdown }
        return skill
    }

    /// "Create a skill": the backend drafts the SKILL.md from a one-line request; this stores and
    /// activates it.
    @discardableResult
    public func createSkill(request: String, capabilities: [String] = []) async throws -> SkillFile {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw fail(.emptyRequest) }
        isCreating = true
        lastError = nil
        defer { isCreating = false }

        do {
            return try importSkill(markdown: try await draft(trimmed, capabilities))
        } catch {
            // `BackendError` states itself through `description`, not `LocalizedError`; asking it
            // for `localizedDescription` gives "The operation couldn't be completed (… error 2.)"
            // in place of the sentence the backend actually sent.
            lastError = (error as? LocalizedError)?.errorDescription
                ?? (error as? BackendError)?.description
                ?? error.localizedDescription
            throw error
        }
    }

    // MARK: - Helpers

    /// Records the error for the panel and returns it for throwing.
    @discardableResult
    private func fail(_ error: SkillLibraryError) -> SkillLibraryError {
        lastError = error.errorDescription
        return error
    }

    /// `NSFileWriteFileExistsError` (Foundation) or `EEXIST` (POSIX) — the path is already taken.
    nonisolated public static func isAlreadyExists(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteFileExistsError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EEXIST) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isAlreadyExists(underlying) }
        return false
    }

    private func ensureDirectories() {
        let fileManager = FileManager.default
        // 0700 for the same reason shell.json is 0600: the library is about to hold whatever a
        // person told Saathi about how they work.
        try? fileManager.createDirectory(
            at: libraryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
    }

    /// Mirrors `slugify` in the backend's `skillMarkdown.ts`: lowercase, non-alphanumerics → "-",
    /// trimmed, never empty.
    nonisolated public static func slugify(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "skill" : out
    }

    private func startWatching() {
        for directory in [libraryDirectory, userSkillsDirectory] {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            // Delivered on the main queue because reload() mutates @Published state on the main actor.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    /// One reload per burst of file events (both watchers share the 300 ms debounce).
    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reload(clearingErrors: false) }
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

public enum SkillLibraryError: LocalizedError, Equatable {
    case invalidMarkdown
    case emptyRequest
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidMarkdown: return "The skill file needs frontmatter with a name and a description."
        case .emptyRequest: return "Describe what the skill should do."
        case .notConfigured: return "Creating a skill needs a backend. Add a token in ~/.saathi/shell.json."
        }
    }
}
