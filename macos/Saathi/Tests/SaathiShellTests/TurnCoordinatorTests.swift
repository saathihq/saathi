import XCTest
import os
@testable import SaathiShell

@MainActor
final class TurnCoordinatorTests: XCTestCase {

    func testOpenThenCloseRunBeginThenEndInOrderEvenWhenCalledBackToBack() async {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let turns = TurnCoordinator(
            begin: { try? await Task.sleep(nanoseconds: 30_000_000); log.withLock { $0.append("begin") } },
            end: { log.withLock { $0.append("end") } },
            onFailure: { _ in XCTFail("no failure expected") })
        XCTAssertTrue(turns.open())
        XCTAssertTrue(turns.close())
        await turns.settle()
        XCTAssertEqual(log.withLock { $0 }, ["begin", "end"], "end must wait for begin even though begin is slow")
        XCTAssertFalse(turns.isOpen)
    }

    func testAFailedBeginPutsTheFlagBackAndReportsIt() async {
        struct Refused: Error {}
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        let turns = TurnCoordinator(
            begin: { throw Refused() },
            end: {},
            onFailure: { message in failures.withLock { $0.append(message) } })
        XCTAssertTrue(turns.open())
        XCTAssertTrue(turns.isOpen, "optimistically open until the session answers")
        await turns.settle()
        XCTAssertFalse(turns.isOpen, "the session refused, so nothing is open")
        XCTAssertEqual(failures.withLock { $0 }.count, 1)
        XCTAssertTrue(turns.open(), "the next press starts a turn rather than trying to end one")
    }

    func testDoubleOpenAndDoubleCloseAreNoOps() async {
        let turns = TurnCoordinator(begin: {}, end: {}, onFailure: { _ in })
        XCTAssertTrue(turns.open())
        XCTAssertFalse(turns.open())
        XCTAssertTrue(turns.close())
        XCTAssertFalse(turns.close())
        await turns.settle()
    }
}
