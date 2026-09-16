//
//  SerialTaskQueueTests.swift
//  SaathiKitTests
//

import Foundation
import os
import XCTest
@testable import SaathiKit

final class SerialTaskQueueTests: XCTestCase {

    func testOperationsNeverOverlapEvenWhenCalledConcurrently() async {
        let queue = SerialTaskQueue()
        let tally = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0, finished: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await queue.run {
                        tally.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        tally.withLock { $0.running -= 1; $0.finished += 1 }
                    }
                }
            }
        }
        let result = tally.withLock { $0 }
        XCTAssertEqual(result.peak, 1, "two operations ran at once")
        XCTAssertEqual(result.finished, 20)
    }

    func testCancellingTheCallerCancelsItsOperation() async {
        let queue = SerialTaskQueue()
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        let caller = Task {
            await queue.run {
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                sawCancellation.withLock { $0 = Task.isCancelled }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        await caller.value
        XCTAssertTrue(sawCancellation.withLock { $0 }, "the operation should have seen the cancellation, not run to its deadline")
    }

    func testACancelledCallerThatNeverStartedDoesNotRunItsOperation() async {
        let queue = SerialTaskQueue()
        let ran = OSAllocatedUnfairLock(initialState: false)
        let blocker = Task { await queue.run { try? await Task.sleep(nanoseconds: 150_000_000) } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let waiting = Task { await queue.run { ran.withLock { $0 = true } } }
        waiting.cancel()
        await waiting.value
        await blocker.value
        XCTAssertFalse(ran.withLock { $0 })
    }
}
