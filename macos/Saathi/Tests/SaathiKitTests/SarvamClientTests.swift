//
//  SarvamClientTests.swift
//  SaathiKitTests
//
//  What is sent to Saaras and to Bulbul, and what is made of each kind of answer. Written against
//  Sarvam's reference as it stood on 2026-09-30: the requests here are the documented ones, field
//  for field, and the answers are the documented shapes. No key, no network.
//

import Foundation
import XCTest
@testable import SaathiKit

final class SarvamClientTests: XCTestCase {

    private func client(_ replies: StubHTTP.Reply...) -> SarvamClient {
        SarvamClient(key: " sk-sarvam \n", urlSession: StubHTTP.session(replies))
    }

    private let turn = WaveFile.wrap(pcm16: Data(repeating: 7, count: 320), sampleRate: 16_000)

    // MARK: ears

    func testATurnGoesToSaarasAsAMultipartWavWithItsLanguage() async throws {
        let sarvam = client(.json(["request_id": "r", "transcript": " നമസ്കാരം ", "language_code": "ml-IN"]))

        let heard = try await sarvam.transcribe(wav: turn, language: "ml-IN")
        XCTAssertEqual(heard, "നമസ്കാരം", "trimmed")

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(StubHTTP.seen.count, 1)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.sarvam.ai/speech-to-text")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(
            seen.request.value(forHTTPHeaderField: "api-subscription-key"), "sk-sarvam",
            "a pasted key brings a newline with it; an untrimmed one is refused like a wrong one")

        let type = try XCTUnwrap(seen.request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(type.hasPrefix(prefix), type)
        let boundary = String(type.dropFirst(prefix.count))

        XCTAssertNotNil(seen.body.range(of: Data("name=\"language_code\"\r\n\r\nml-IN\r\n".utf8)))
        XCTAssertNotNil(seen.body.range(of: Data(
            "name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)))
        XCTAssertNotNil(seen.body.range(of: turn), "the WAV itself, byte for byte")
        XCTAssertTrue(seen.body.starts(with: Data("--\(boundary)\r\n".utf8)))
        let closing = Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertEqual(Data(seen.body.suffix(closing.count)), closing, "closed with the final boundary")
    }

    /// Saaras's current model is its default. Naming a version would only be a way to be left
    /// behind by the next one.
    func testNoModelIsNamedForTheEars() async throws {
        _ = try await client(.json(["transcript": "hello"])).transcribe(wav: turn, language: "en-IN")
        let body = try XCTUnwrap(StubHTTP.seen.first?.body)
        XCTAssertNil(body.range(of: Data("name=\"model\"".utf8)))
    }

    func testAnAnswerWithNoTranscriptIsAnErrorNotSilence() async {
        do {
            _ = try await client(.json(["request_id": "r"])).transcribe(wav: turn, language: "en-IN")
            XCTFail("an answer with nothing in it must not read as a turn in which nothing was said")
        } catch {
            XCTAssertEqual(error as? SarvamError, .unreadable("there was no transcript in it"))
        }
    }

    // MARK: mouth

    func testASentenceGoesToBulbulAndComesBackAsAudio() async throws {
        let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 100), sampleRate: 24_000)
        let sarvam = client(.json(["request_id": "r", "audios": [clip.base64EncodedString()]]))

        let clips = try await sarvam.synthesize("നമസ്കാരം", language: "ml-IN")
        XCTAssertEqual(clips, [clip])

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.sarvam.ai/text-to-speech")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "api-subscription-key"), "sk-sarvam")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen.json["text"] as? String, "നമസ്കാരം")
        XCTAssertEqual(seen.json["language_code"] as? String, "ml-IN")
        XCTAssertEqual(seen.json["speaker"] as? String, "shubh")
        XCTAssertEqual(seen.json["model"] as? String, "bulbul:v3")
        XCTAssertEqual(
            Set(seen.json.keys), ["text", "language_code", "speaker", "model"],
            "the fewest fields the reference allows: every one not sent is one that cannot be refused")
    }

    func testAPaceIsAskedForOnlyWhenItIsNotTheOrdinaryOneAndKeptInsideWhatBulbulTakes() async throws {
        let clip = Data("clip".utf8).base64EncodedString()
        func pace(_ asked: Double) async throws -> Double? {
            _ = try await client(.json(["audios": [clip]])).synthesize("x", language: "en-IN", pace: asked)
            return StubHTTP.seen.first?.json["pace"] as? Double
        }
        let ordinary = try await pace(1)
        XCTAssertNil(ordinary)
        // Calm and slow, as the speaker works it out: 0.9 × 0.85 in single precision.
        let calmAndSlow = try await pace(Double(Float(0.9) * Float(0.85)))
        XCTAssertEqual(calmAndSlow, 0.76)
        XCTAssertNotNil(
            StubHTTP.seen.first?.body.range(of: Data("\"pace\":0.76".utf8)),
            "two decimals on the wire, not the seventeen digits a float makes of it")
        let tooSlow = try await pace(0.1)
        XCTAssertEqual(tooSlow, 0.5)
        let tooFast = try await pace(5)
        XCTAssertEqual(tooFast, 2)
    }

    /// The reference says a list of base64 strings; its troubleshooting page reads `.audio` off
    /// each one. Whichever arrives is played.
    func testAudioWrappedInAnObjectIsReadToo() async throws {
        let clip = Data("a clip".utf8)
        let clips = try await client(.json(["audios": [["audio": clip.base64EncodedString()]]]))
            .synthesize("x", language: "en-IN")
        XCTAssertEqual(clips, [clip])
    }

    func testAnAnswerWithNoAudioInItIsAnError() async {
        for answer in [["request_id": "r"], ["audios": []], ["audios": [""]], ["audios": [42]]] as [[String: Any]] {
            do {
                _ = try await client(.json(answer)).synthesize("x", language: "en-IN")
                XCTFail("\(answer) has nothing to play in it")
            } catch {
                XCTAssertEqual(error as? SarvamError, .unreadable("there was no audio in it"))
            }
        }
    }

    // MARK: refusals

    /// Sarvam says no to a key with 403, not 401 — and says "out of credits" and "slow down" with
    /// the same 429. Only the code in the body tells them apart, and the difference is the whole
    /// of what the person needs to know.
    func testEachRefusalIsReadAsWhatItIs() {
        func refusal(_ status: Int, _ code: String) -> SarvamError {
            SarvamError.refusal(status: status, body: Data(#"{"error":{"message":"m","code":"\#(code)"}}"#.utf8))
        }
        XCTAssertEqual(refusal(403, "invalid_api_key_error"), .keyRefused)
        XCTAssertEqual(refusal(401, "anything"), .keyRefused)
        XCTAssertEqual(SarvamError.refusal(status: 403, body: Data()), .keyRefused, "a bare 403 is the key")
        XCTAssertEqual(refusal(403, "some_other_error"), .refused(status: 403, message: "m"), "let in, then told no")
        XCTAssertEqual(refusal(429, "insufficient_quota_error"), .outOfCredits)
        XCTAssertEqual(refusal(429, "rate_limit_exceeded_error"), .busy)
        XCTAssertEqual(refusal(503, "rate_limit_exceeded_error"), .busy)
        XCTAssertEqual(refusal(422, "unprocessable_entity_error"), .refused(status: 422, message: "m"))
        XCTAssertEqual(
            SarvamError.refusal(status: 500, body: Data("upstream fell over".utf8)),
            .refused(status: 500, message: "upstream fell over"),
            "not JSON: the body itself, as far as it goes")
    }

    func testEveryRefusalIsASentenceThatNamesSarvam() {
        let all: [SarvamError] = [
            .keyRefused, .outOfCredits, .busy, .refused(status: 422, message: "m"),
            .unreadable("x"), .unreachable("offline"),
        ]
        for error in all {
            XCTAssertTrue(error.localizedDescription.contains("Sarvam"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("couldn’t be completed"), error.localizedDescription)
        }
        XCTAssertTrue(SarvamError.keyRefused.localizedDescription.contains("Setup"))
        XCTAssertTrue(SarvamError.outOfCredits.localizedDescription.contains("credits"))
    }

    func testARefusalFromEitherEndpointIsThrownAsItself() async {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        do {
            _ = try await client(refused).transcribe(wav: turn, language: "en-IN")
            XCTFail("a 403 is not a transcript")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
        do {
            _ = try await client(refused).synthesize("x", language: "en-IN")
            XCTFail("a 403 is not audio")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
    }

    /// A wrong key and an aeroplane-mode laptop must never produce the same sentence.
    func testBeingOfflineIsNotARefusal() async {
        do {
            _ = try await client(.failing()).synthesize("x", language: "en-IN")
            XCTFail("there was no network")
        } catch {
            guard case .unreachable = error as? SarvamError else {
                return XCTFail("no network is unreachable, not \(error)")
            }
        }
    }
}
