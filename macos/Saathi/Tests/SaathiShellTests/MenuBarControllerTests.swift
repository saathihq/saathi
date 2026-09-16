//
//  MenuBarControllerTests.swift
//  SaathiShellTests
//

import AppKit
import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

@MainActor
final class MenuBarControllerTests: XCTestCase {

    private func controller() throws -> MenuBarController {
        MenuBarController(icon: MenuBarIcon.image(data: try MascotData.load()))
    }

    func testTheMenuHasTheItemsTheSpecLists() throws {
        let titles = try controller().menu.items.map(\.title).filter { !$0.isEmpty }
        for expected in ["Ready", "Talk", "Companion", "Start at login", "Provider…", "Run onboarding again", "Quit Saathi"] {
            XCTAssertTrue(titles.contains(expected), "missing \(expected) in \(titles)")
        }
    }

    func testTheStateWordAndTheTalkItemFollowTheState() throws {
        let menu = try controller()
        menu.setState(.listening)
        XCTAssertEqual(menu.menu.items.first?.title, "Listening")
        XCTAssertTrue(menu.menu.items.contains { $0.title == "Stop talking" })
        menu.setState(.idle)
        XCTAssertTrue(menu.menu.items.contains { $0.title == "Talk" })
    }

    func testPermissionsItemAppearsOnlyWhenSomethingIsMissing() throws {
        let menu = try controller()
        let item = try XCTUnwrap(menu.menu.items.first { $0.title.hasPrefix("Fix permissions") })
        XCTAssertTrue(item.isHidden)
        menu.setPermissionsNeeded(["Input Monitoring"])
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Fix permissions: Input Monitoring…")
        menu.setPermissionsNeeded([])
        XCTAssertTrue(item.isHidden)
    }

    func testTheCheckboxesReflectWhatTheyAreTold() throws {
        let menu = try controller()
        menu.setCompanionVisible(false)
        XCTAssertEqual(menu.menu.items.first { $0.title == "Companion" }?.state, .off)
        menu.setStartAtLogin(true)
        XCTAssertEqual(menu.menu.items.first { $0.title == "Start at login" }?.state, .on)
    }
}
