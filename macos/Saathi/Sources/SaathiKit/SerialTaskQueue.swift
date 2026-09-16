//
//  SerialTaskQueue.swift
//  SaathiKit
//
//  Runs async operations strictly one after another, in the order they were chained, with a
//  caller's cancellation reaching its own operation. The chaining happens under ONE lock
//  acquisition — read the tail, create the successor, store it — so two callers cannot both see
//  the same predecessor and then run side by side, which is the race an earlier version had.
//

import Foundation
import os

public final class SerialTaskQueue: @unchecked Sendable {

    private struct State {
        var tail: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func run(_ operation: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never> = state.withLock { box in
            let previous = box.tail
            let next = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await operation()
            }
            box.tail = next
            return next
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
