//
//  TrialClientTests.swift
//  SaathiKitTests
//
//  Asking for a trial, against a stub URL session: what is sent, what each refusal becomes in
//  words, and that the device id is made once and kept — because a second id is a second trial.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class TrialStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    /// Runs while the request is "in flight", for tests about what else happens meanwhile.
    nonisolated(unsafe) static var duringRequest: (() -> Void)?

    static func reset(status: Int, body: String, shouldFail: Bool = false) {
        self.status = status; self.body = body; self.shouldFail = shouldFail
        lastRequest = nil; lastBody = nil
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrialStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        Self.duringRequest?()
        Self.duringRequest = nil
        // URLProtocol hands the body over as a stream, never as `httpBody`.
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastBody = data
        }
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TrialClientTests: XCTestCase {

    private let device = "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f"
    private let granted = #"{"token":"saathi_trial_abc","expiresAt":"2026-09-28T10:00:00+00:00","dailyVoiceSessions":3}"#

    private func client() throws -> TrialClient {
        try TrialClient(
            configuration: SaathiConfiguration(backendUrl: "https://backend.example.test"),
            session: TrialStubProtocol.session)
    }

    func testItPostsTheDeviceWithNoAuthorizationAndReadsTheGrant() async throws {
        TrialStubProtocol.reset(status: 200, body: granted)
        let grant = try await client().requestTrial(device: device)

        XCTAssertEqual(grant, TrialGrant(token: "saathi_trial_abc", expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3))
        let request = try XCTUnwrap(TrialStubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://backend.example.test/trial")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "a trial is asked for by someone who has no token yet")
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(TrialStubProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(sent, ["device": device])
    }

    /// Onboarding says "the exact reason in words", so the backend's sentence is what is kept.
    func testARefusalCarriesTheBackendsOwnSentence() async throws {
        for status in [429, 403] {
            TrialStubProtocol.reset(status: status, body: #"{"error":"that is five trial requests from this network today; try again tomorrow"}"#)
            do {
                _ = try await client().requestTrial(device: device)
                XCTFail("a \(status) must throw")
            } catch let error as TrialError {
                XCTAssertEqual(error, .refused("that is five trial requests from this network today; try again tomorrow"))
            }
        }
    }

    func testABackendThatDoesNotOfferTrialsSaysSo() async throws {
        for status in [501, 404] {
            TrialStubProtocol.reset(status: status, body: #"{"error":"this backend does not offer trials"}"#)
            do {
                _ = try await client().requestTrial(device: device)
                XCTFail("a \(status) must throw")
            } catch let error as TrialError {
                XCTAssertEqual(error, .notOffered("this backend does not offer trials"))
            }
        }
    }

    func testAnUnreachableBackendIsATransportError() async throws {
        TrialStubProtocol.reset(status: 200, body: "", shouldFail: true)
        do {
            _ = try await client().requestTrial(device: device)
            XCTFail("must throw")
        } catch let error as TrialError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
    }

    func testA5xxAndAnUnreadableGrantAreTransportErrorsNotGrants() async throws {
        TrialStubProtocol.reset(status: 503, body: #"{"error":"the accounts database did not answer (500)"}"#)
        do { _ = try await client().requestTrial(device: device); XCTFail("must throw") }
        catch let error as TrialError { XCTAssertEqual(error, .transport("the accounts database did not answer (500)")) }

        TrialStubProtocol.reset(status: 200, body: #"{"token":7}"#)
        do { _ = try await client().requestTrial(device: device); XCTFail("must throw") }
        catch let error as TrialError { guard case .transport = error else { return XCTFail("\(error)") } }
    }

    func testEveryTrialErrorReadsAsASentence() {
        let errors: [TrialError] = [.badBaseUrl("x"), .refused("r"), .notOffered("n"), .transport("t")]
        for error in errors { XCTAssertFalse(error.description.isEmpty) }
        XCTAssertEqual(TrialError.refused("your trial ended").description, "your trial ended")
    }

    // MARK: the device id

    func testTheDeviceIdIsMadeOnceAndIsALowercaseV4UUID() {
        var configuration = SaathiConfiguration()
        let first = TrialEnrollment.deviceId(in: &configuration)
        let second = TrialEnrollment.deviceId(in: &configuration)
        XCTAssertEqual(first, second, "a second id is a second trial")
        XCTAssertEqual(configuration.deviceId, first)
        XCTAssertNotNil(first.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression))
    }

    func testABlankStoredDeviceIdIsReplaced() {
        var configuration = SaathiConfiguration(deviceId: "  ")
        XCTAssertFalse(TrialEnrollment.deviceId(in: &configuration).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: enrolling

    private func temporaryConfigPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-trial-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shell.json")
    }

    func testEnrollingSavesTheTokenAndTheDeviceIdAndNothingElseChanges() async throws {
        let path = temporaryConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try ConfigurationStore.save(
            SaathiConfiguration(openaiKey: "sk-kept", backendUrl: "https://backend.example.test"), to: path)
        TrialStubProtocol.reset(status: 200, body: granted)

        let grant = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session)

        let saved = try ConfigurationStore.load(from: path)
        XCTAssertEqual(saved.token, grant.token)
        XCTAssertNotNil(saved.deviceId)
        XCTAssertEqual(saved.openaiKey, "sk-kept")
        XCTAssertNil(saved.provider, "choosing where Saathi thinks is onboarding's last step, not this one")
    }

    /// The id is written before the network is touched: a refused or failed ask must not mean a
    /// new id — and so a new trial — on the next attempt.
    func testTheDeviceIdSurvivesARefusal() async throws {
        let path = temporaryConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try ConfigurationStore.save(SaathiConfiguration(backendUrl: "https://backend.example.test"), to: path)

        TrialStubProtocol.reset(status: 429, body: #"{"error":"try again tomorrow"}"#)
        do { _ = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session); XCTFail("must throw") } catch {}
        let afterRefusal = try XCTUnwrap(try ConfigurationStore.load(from: path).deviceId)
        XCTAssertNil(try ConfigurationStore.load(from: path).token)

        TrialStubProtocol.reset(status: 200, body: granted)
        _ = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session)
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(TrialStubProtocol.lastBody)) as? [String: String]
        XCTAssertEqual(sent?["device"], afterRefusal)
    }

    /// The request takes seconds and first run saves on every change. The token goes onto what is
    /// on disk when the answer arrives, not onto the copy loaded before asking.
    func testWhatWasSavedWhileTheRequestWasInFlightSurvives() async throws {
        let path = temporaryConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try ConfigurationStore.save(SaathiConfiguration(backendUrl: "https://backend.example.test"), to: path)
        TrialStubProtocol.reset(status: 200, body: granted)
        TrialStubProtocol.duringRequest = {
            var meanwhile = (try? ConfigurationStore.load(from: path)) ?? SaathiConfiguration()
            meanwhile.name = "Asha"
            meanwhile.onboarded = true
            try? ConfigurationStore.save(meanwhile, to: path)
        }

        let grant = try await TrialEnrollment.enroll(at: path, session: TrialStubProtocol.session)

        let saved = try ConfigurationStore.load(from: path)
        XCTAssertEqual(saved.token, grant.token)
        XCTAssertEqual(saved.onboarded, true, "the enrolment wrote an older copy back over a newer one")
        XCTAssertEqual(saved.name, "Asha")
        XCTAssertNotNil(saved.deviceId)
    }

    func testHealthReadsWhetherTrialsAreOn() throws {
        let health = try JSONDecoder().decode(BackendHealth.self, from: Data(#"{"ok":true,"version":"0.8.0","trial":"on"}"#.utf8))
        XCTAssertEqual(health.trial, "on")
        let older = try JSONDecoder().decode(BackendHealth.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(older.trial, "a backend from before trials still parses")
    }
}
