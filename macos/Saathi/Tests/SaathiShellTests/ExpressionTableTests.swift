//
//  ExpressionTableTests.swift
//  SaathiShellTests
//

import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

final class ExpressionTableTests: XCTestCase {

    func testEveryStateHasAFace() {
        let states: [CompanionState] = [
            .asleep, .idle, .listening, .thinking, .speaking,
            .showingStep(index: 1, total: 3), .celebrating, .alert("x"), .poweringDown,
        ]
        let expected: [MascotExpression] = [
            .sleeping, .idle, .listening, .thinking, .dictating,
            .working, .celebrate, .alerting, .poweringDown,
        ]
        XCTAssertEqual(states.map(\.mascotExpression), expected)
    }
}
