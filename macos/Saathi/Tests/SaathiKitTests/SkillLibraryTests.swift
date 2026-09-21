//
//  SkillLibraryTests.swift
//  SaathiKitTests
//
//  The skill library, checked against a temporary directory rather than `~/.saathi`.
//

import XCTest
@testable import SaathiKit

final class SkillFileTests: XCTestCase {

    func testReadsTheFrontmatterTheBackendWrites() throws {
        let skill = try XCTUnwrap(SkillFile.parse("""
        ---
        name: Write Like Me
        description: Answer in the user's own voice.
        surfaces: [talk]
        ---

        ## Use When
        The user asks for something written.
        """, id: "write-like-me"))

        XCTAssertEqual(skill.name, "Write Like Me")
        XCTAssertEqual(skill.surfaces, ["talk"])
        XCTAssertTrue(skill.isForTalk)
        XCTAssertTrue(skill.body.hasPrefix("## Use When"))
    }

    /// A file with no name or no description is not a skill with blanks in it — it is not a skill.
    func testRefusesAFileWithNothingToCallItBy() {
        XCTAssertNil(SkillFile.parse("# Just a heading", id: "x"))
        XCTAssertNil(SkillFile.parse("---\nname: No Description\n---\nbody", id: "x"))
    }

    /// Both surfaces when the file does not say, matching the backend's default.
    func testASkillThatDoesNotSayWhereItAppliesAppliesEverywhere() throws {
        let skill = try XCTUnwrap(SkillFile.parse("---\nname: N\ndescription: D\n---\nbody", id: "n"))
        XCTAssertEqual(skill.surfaces, ["talk", "agent"])
    }
}

final class SkillLibraryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saathi-skills-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func store() -> SkillLibraryStore {
        // `watch: false`: a dispatch source on a directory a test is about to delete is a race with
        // nothing to gain — every mutation here goes through the store, which reloads itself.
        SkillLibraryStore(
            userSkillsDirectory: directory,
            appSkillsDirectory: directory.appendingPathComponent("app"),
            watch: false
        )
    }

    @MainActor
    func testImportingASkillWritesItAndTurnsItOn() throws {
        let library = store()
        let skill = try library.importSkill(markdown: "---\nname: Write Like Me\ndescription: D\n---\nbody")

        XCTAssertEqual(skill.id, "write-like-me", "the id is the slug of the name, as the backend spells it")
        XCTAssertEqual(library.librarySkills.map(\.id), ["write-like-me"])
        XCTAssertTrue(library.activeIds.contains("write-like-me"), "a skill you just made is on")

        let link = directory.appendingPathComponent("active/write-like-me")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            directory.appendingPathComponent("library/write-like-me", isDirectory: true).path,
            "active/ is the one path a doing lane can be pointed at without reading activations.json")
    }

    @MainActor
    func testTwoSkillsWithTheSameNameGetSeparateFolders() throws {
        let library = store()
        let first = try library.importSkill(markdown: "---\nname: Same\ndescription: D\n---\none")
        let second = try library.importSkill(markdown: "---\nname: Same\ndescription: D\n---\ntwo")

        XCTAssertEqual(first.id, "same")
        XCTAssertEqual(second.id, "same-2", "the second claims the next id rather than overwriting the first")
        XCTAssertEqual(library.librarySkills.count, 2)
    }

    @MainActor
    func testTurningASkillOffDropsItsLink() throws {
        let library = store()
        try library.importSkill(markdown: "---\nname: N\ndescription: D\n---\nbody")
        library.setActive("n", false)

        XCTAssertFalse(library.activeIds.contains("n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("active/n").path))
    }

    @MainActor
    func testAFileThatIsNotASkillIsIgnoredRatherThanCrashingTheRow() throws {
        let library = store()
        let folder = directory.appendingPathComponent("library/not-a-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "no frontmatter here".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        library.reload()
        XCTAssertTrue(library.librarySkills.isEmpty)
    }

    @MainActor
    func testCreatingASkillWithNoBackendSaysSoRatherThanFailingSilently() async {
        let library = store()
        do {
            _ = try await library.createSkill(request: "reply in my voice")
            XCTFail("a store with no backend cannot draft anything")
        } catch {
            XCTAssertEqual(error as? SkillLibraryError, .notConfigured)
            XCTAssertNotNil(library.lastError, "the row shows what went wrong")
        }
    }

    @MainActor
    func testAnEmptyRequestNeverReachesTheBackend() async {
        var asked = false
        let library = SkillLibraryStore(
            userSkillsDirectory: directory,
            appSkillsDirectory: directory.appendingPathComponent("app"),
            watch: false,
            draft: { _, _ in asked = true; return "" }
        )
        do {
            _ = try await library.createSkill(request: "   ")
            XCTFail("an empty request is not a request")
        } catch {
            XCTAssertEqual(error as? SkillLibraryError, .emptyRequest)
            XCTAssertFalse(asked, "nothing is spent on a blank field")
        }
    }

    @MainActor
    func testADraftedSkillIsStoredAndActivated() async throws {
        let library = SkillLibraryStore(
            userSkillsDirectory: directory,
            appSkillsDirectory: directory.appendingPathComponent("app"),
            watch: false,
            draft: { _, _ in "---\nname: Drafted\ndescription: D\n---\nbody" }
        )
        let skill = try await library.createSkill(request: "do a thing")

        XCTAssertEqual(skill.id, "drafted")
        XCTAssertTrue(library.activeIds.contains("drafted"))
        XCTAssertFalse(library.isCreating, "the spinner stops whether it worked or not")
    }

    /// Mirrors the backend's `slugify`. Two spellings of the same name is a skill written into one
    /// folder and looked for in another.
    func testSlugifyMatchesTheBackend() {
        XCTAssertEqual(SkillLibraryStore.slugify("Write Like Me"), "write-like-me")
        XCTAssertEqual(SkillLibraryStore.slugify("  Émile's 2nd skill!  "), "mile-s-2nd-skill")
        XCTAssertEqual(SkillLibraryStore.slugify("!!!"), "skill")
    }
}
