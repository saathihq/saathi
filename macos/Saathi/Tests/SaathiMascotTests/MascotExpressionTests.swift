//
//  MascotExpressionTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class MascotExpressionTests: XCTestCase {

    /// The enum and the JSON must agree exactly: a case with no data would show a blank face, and
    /// data with no case would be unreachable.
    func testTheEnumAndTheDataNameTheSameExpressions() throws {
        let data = try MascotData.load()
        let inCode = Set(MascotExpression.allCases.map(\.rawValue))
        let inData = Set(data.expressions.keys)
        XCTAssertEqual(inCode.subtracting(inData), [], "cases with no data")
        XCTAssertEqual(inData.subtracting(inCode), [], "data with no case")
        XCTAssertEqual(Set(data.motion.keys), inCode, "every expression has a motion preset")
    }

    func testTheNamesTheAppWillUseExist() {
        for name in ["idle", "sleeping", "listening", "thinking", "dictating", "working", "celebrate", "alerting", "powering-down"] {
            XCTAssertNotNil(MascotExpression(rawValue: name), name)
        }
    }
}
