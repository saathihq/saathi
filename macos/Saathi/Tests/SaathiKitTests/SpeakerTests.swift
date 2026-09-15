//
//  SpeakerTests.swift
//  SaathiKitTests
//
//  AVSpeechSynthesizer reports `isSpeaking == false` for tens of milliseconds after `speak()`,
//  so a poll on that flag returns before any audio and a CLI exits silent. These pin the
//  delegate-driven wait that replaced it.
//

import AVFoundation
import Foundation
import os
import XCTest
@testable import SaathiKit

final class UtteranceWaiterTests: XCTestCase {

    private let synthesizer = AVSpeechSynthesizer()
    private let utterance = AVSpeechUtterance(string: "x")

    func testWaitDoesNotReturnUntilTheDelegateReportsAFinish() async {
        let waiter = UtteranceWaiter()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let waiting = Task {
            await waiter.wait()
            finished.withLock { $0 = true }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished.withLock { $0 }, "wait() returned before the delegate said anything")

        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiting.value
        XCTAssertTrue(finished.withLock { $0 })
    }

    func testAFinishThatArrivesBeforeWaitDoesNotHang() async {
        let waiter = UtteranceWaiter()
        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiter.wait()   // would hang forever if the early finish were lost
    }

    func testACancelAlsoEndsTheWait() async {
        let waiter = UtteranceWaiter()
        let waiting = Task { await waiter.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.speechSynthesizer(synthesizer, didCancel: utterance)
        await waiting.value
    }
}
