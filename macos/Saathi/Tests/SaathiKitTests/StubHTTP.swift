//
//  StubHTTP.swift
//  SaathiKitTests
//
//  A URLSession that answers from a script and remembers what it was asked, bodies included.
//
//  Everything Saathi sends to Sarvam, and everything the chain lane sends to a model, is tested
//  against this rather than against a network: what matters is the exact request, and what is made
//  of each kind of answer. It can also hold an answer back, for the one question that needs the
//  moment between asking and hearing — what happens when the learner talks over it.
//

import Foundation
import os

final class StubHTTP: URLProtocol {

    struct Reply {
        var status = 200
        var body = Data()
        var failure: URLError.Code?

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        /// No answer at all: the network is not there.
        static func failing(_ code: URLError.Code = .notConnectedToInternet) -> Reply {
            Reply(failure: code)
        }
    }

    struct Seen {
        let request: URLRequest
        let body: Data

        /// The body as the JSON object it was sent as.
        var json: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        }
    }

    private struct Script {
        var replies: [Reply] = []
        var seen: [Seen] = []
        var holding = false
    }
    private static let script = OSAllocatedUnfairLock(initialState: Script())

    /// A session answered by `replies`, in order; the last one goes on answering. Starts a fresh
    /// script, so each test sees only its own requests.
    static func session(_ replies: [Reply]) -> URLSession {
        script.withLock { $0 = Script(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }

    static func session(_ replies: Reply...) -> URLSession {
        session(replies)
    }

    /// Every request since the session was made.
    static var seen: [Seen] {
        script.withLock { $0.seen }
    }

    /// From here on a request is taken and never answered, until its task is cancelled.
    static func hold() {
        script.withLock { $0.holding = true }
    }

    /// Requests are answered again. One that was taken while holding stays unanswered.
    static func release() {
        script.withLock { $0.holding = false }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLProtocol hands the body over as a stream, never as `httpBody`.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }

        let seen = Seen(request: request, body: body)
        let (reply, holding) = Self.script.withLock { script -> (Reply, Bool) in
            script.seen.append(seen)
            let reply = script.replies.count > 1 ? script.replies.removeFirst() : (script.replies.first ?? Reply())
            return (reply, script.holding)
        }
        if holding { return }

        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Whether `task` finishes within `seconds`, and how. For work that has to end when it is
/// interrupted: a test that simply awaited it would hang, rather than fail, if it did not.
func outcome<Success: Sendable>(
    of task: Task<Success, any Error>, within seconds: Double = 2
) async -> Result<Success, any Error>? {
    let finished = Collected<Result<Success, any Error>>()
    Task { finished.add(await task.result) }
    for _ in 0..<Int(seconds * 200) where finished.all.isEmpty {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return finished.all.first
}

/// Collects what callbacks were handed, from whichever thread they arrive on.
final class Collected<Value: Sendable>: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Value]())

    func add(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}
