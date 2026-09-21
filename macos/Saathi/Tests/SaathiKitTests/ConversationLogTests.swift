//
//  ConversationLogTests.swift
//  SaathiKitTests
//

import XCTest
@testable import SaathiKit

final class ConversationLogTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_789_646_400)   // 2026-09-17 in UTC terms; only the shape matters

    func testALineIsTheTimeALabelAndTheTextOnOneLine() {
        let line = ConversationLog.line(.you("how do I play\nthis song"), at: noon)
        XCTAssertTrue(line.hasSuffix("  you    how do I play this song"), line)
        XCTAssertEqual(line.prefix(19).count, 19, "a timestamp first: \(line)")
        let look = ConversationLog.line(.look(question: "which song", answer: "Kun Faya Kun, row three"), at: noon)
        XCTAssertTrue(look.hasSuffix("  look   asked: which song — answered: Kun Faya Kun, row three"), look)
        XCTAssertTrue(ConversationLog.line(.error("boom"), at: noon).contains("  error  boom"))
    }

    func testEntriesAreAppendedInOrderToAPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("conversation.log")
        let log = ConversationLog(url: url, now: { Date(timeIntervalSince1970: 0) })
        log.append(.you("how do I play this song"))
        log.append(.saathi("Click the play button next to Kun Faya Kun."))
        log.flush()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("you    how do I play this song"))
        XCTAssertTrue(lines[1].contains("saathi Click the play button"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600, "what someone said to their computer is theirs")
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheDefaultLogSitsBesideTheSettingsFile() {
        let config = URL(fileURLWithPath: "/Users/someone/.saathi/shell.json")
        XCTAssertEqual(ConversationLog.defaultURL(beside: config).path, "/Users/someone/.saathi/conversation.log")
    }
}
