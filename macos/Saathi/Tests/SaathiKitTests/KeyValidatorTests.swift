//
//  KeyValidatorTests.swift
//  SaathiKitTests
//
//  A wrong key and an aeroplane-mode laptop must never produce the same sentence. That is the whole
//  point of this type having three outcomes rather than a Bool.
//

import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class KeyValidatorTests: XCTestCase {

    func testA200MeansTheKeyWorks() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        let result = await validator.check(.openai, key: "sk-good")
        XCTAssertEqual(result, .valid)
    }

    func testA401NamesTheVendorThatRefused() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 401))
        guard case let .rejected(message) = await validator.check(.openai, key: "sk-bad") else {
            return XCTFail("a 401 must be a rejection, not a transport problem")
        }
        XCTAssertTrue(message.contains("OpenAI"), "the person needs to know who refused: \(message)")
    }

    func testA403IsAlsoARejection() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 403))
        guard case .rejected = await validator.check(.anthropic, key: "sk-ant-bad") else {
            return XCTFail("403 is the key being refused, not the network failing")
        }
    }

    /// The distinction that matters most: someone offline must not be told their key is wrong and
    /// go and generate a new one.
    func testATransportFailureIsNotARejection() async {
        let validator = KeyValidator(urlSession: .keyStubFailing())
        guard case let .unreachable(message) = await validator.check(.openai, key: "sk-good") else {
            return XCTFail("a dead network must not read as a bad key")
        }
        XCTAssertFalse(message.contains("did not accept"), "that wording belongs to rejection only")
    }

    /// A 500 is the vendor's problem, not the key's.
    func testAServerErrorIsUnreachableRatherThanRejected() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 500))
        guard case .unreachable = await validator.check(.openai, key: "sk-good") else {
            return XCTFail("a 500 says nothing about whether the key is valid")
        }
    }

    /// Pasting from a password manager or a terminal brings a newline along more often than not.
    func testAPastedKeyWithATrailingNewlineStillValidates() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        let result = await validator.check(.openai, key: "sk-good\n")
        XCTAssertEqual(result, .valid)
    }

    func testAnEmptyKeyIsRejectedWithoutAskingTheVendor() async {
        let validator = KeyValidator(urlSession: .keyStubFailing())
        guard case .rejected = await validator.check(.openai, key: "   ") else {
            return XCTFail("an empty key needs no round trip to be wrong")
        }
    }

    /// Each vendor is asked in its own dialect. Anthropic refuses a Bearer header and OpenAI ignores
    /// x-api-key, so getting this wrong would make every key look invalid.
    func testEachVendorIsAskedTheWayItExpects() async {
        KeyStubProtocol.reset(status: 200)
        _ = await KeyValidator(urlSession: .keyStub(status: 200)).check(.openai, key: "sk-o")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.url?.host, "api.openai.com")
        XCTAssertEqual(
            KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-o")

        KeyStubProtocol.reset(status: 200)
        _ = await KeyValidator(urlSession: .keyStub(status: 200)).check(.anthropic, key: "sk-a")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.url?.host, "api.anthropic.com")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-a")
        XCTAssertEqual(
            KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    /// Providers that take no key of their own cannot be checked, and saying "valid" would be a lie.
    func testAProviderThatNeedsNoKeyCannotBeChecked() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        guard case .rejected = await validator.check(.local, key: "anything") else {
            return XCTFail("local takes no key; there is nothing here to validate")
        }
    }
}

// MARK: - A URLSession that answers without a network

final class KeyStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset(status: Int, shouldFail: Bool = false) {
        self.status = status
        self.shouldFail = shouldFail
        self.lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // `URLProtocol` strips the body but keeps the headers, which is what these tests assert on.
        Self.lastRequest = request

        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension URLSession {
    static func keyStub(status: Int) -> URLSession {
        KeyStubProtocol.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func keyStubFailing() -> URLSession {
        KeyStubProtocol.reset(status: 0, shouldFail: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
