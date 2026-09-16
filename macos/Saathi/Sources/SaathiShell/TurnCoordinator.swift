//
//  TurnCoordinator.swift
//  SaathiShell
//
//  One place that knows whether a voice turn is open. Begin and end calls to the session are run
//  strictly one after another, so a fast open/close cannot overlap them, and a begin that fails
//  puts the flag back so the next press starts a turn instead of trying to end one that never
//  opened.
//

import Foundation

@MainActor
public final class TurnCoordinator {
    public private(set) var isOpen = false
    private var work: Task<Void, Never>?
    private let begin: @Sendable () async throws -> Void
    private let end: @Sendable () async throws -> Void
    private let onFailure: (String) -> Void

    public init(begin: @escaping @Sendable () async throws -> Void,
                end: @escaping @Sendable () async throws -> Void,
                onFailure: @escaping (String) -> Void) {
        self.begin = begin
        self.end = end
        self.onFailure = onFailure
    }

    /// Opens a turn if none is open. Returns whether it did.
    @discardableResult
    public func open() -> Bool {
        guard !isOpen else { return false }
        isOpen = true
        run(begin) { [weak self] in self?.isOpen = false }
        return true
    }

    /// Closes the open turn if there is one. Returns whether it did.
    @discardableResult
    public func close() -> Bool {
        guard isOpen else { return false }
        isOpen = false
        run(end, onError: nil)
        return true
    }

    /// Waits for every queued session call to finish. Tests use it; the app does not need to.
    public func settle() async {
        await work?.value
    }

    private func run(_ operation: @escaping @Sendable () async throws -> Void, onError: (@MainActor () -> Void)?) {
        let previous = work
        work = Task {
            await previous?.value
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    onError?()
                    self.onFailure(error.localizedDescription)
                }
            }
        }
    }
}
