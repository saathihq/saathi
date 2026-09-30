//
//  SarvamClient.swift
//  SaathiKit
//
//  Sarvam's ears and mouth: a held turn of speech to Saaras, a sentence to Bulbul.
//
//  Two requests and one way of reading a refusal, and nothing else — no microphone, no playback,
//  no state. The thinking does not come through here: Sarvam's chat endpoint is OpenAI-shaped and
//  the chain lane already speaks that to everyone.
//
//  One request per step rather than Sarvam's streaming sockets. The REST endpoints are exactly what
//  the reference specifies and can be written against a stub with confidence; a socket protocol
//  written with no key to try it on is a guess. The price is no words appearing as they are said,
//  and a reply that starts once all of it has been synthesised rather than during.
//
//  Written from docs.sarvam.ai as it stood on 2026-09-30, and never yet run against a real key.
//  `saathi sarvam` is the command that finds out.
//

import Foundation

public enum SarvamError: Error, LocalizedError, Equatable, Sendable {
    /// The key is missing, wrong or revoked.
    case keyRefused
    /// The key is fine and the account behind it has nothing left.
    case outOfCredits
    /// Too many requests, or Sarvam is under load. Worth trying again.
    case busy
    /// Any other no, in Sarvam's own words.
    case refused(status: Int, message: String)
    /// An answer that was not the shape the reference shows.
    case unreadable(String)
    /// No answer at all.
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .keyRefused:
            return "Sarvam did not accept the key. Put a new one in Setup."
        case .outOfCredits:
            return "Sarvam says this account is out of credits. Add some at dashboard.sarvam.ai."
        case .busy:
            return "Sarvam is busy, or this key is asking too fast. Try again in a moment."
        case let .refused(status, message):
            return "Sarvam refused (\(status)): \(message)"
        case let .unreadable(what):
            return "Sarvam's answer could not be read: \(what)."
        case let .unreachable(reason):
            return "Could not reach Sarvam: \(reason)"
        }
    }

    /// Reads a refusal.
    ///
    /// Sarvam says no to a key with 403, not 401, and uses 403 for "let in, and then told no" as
    /// well: only `error.code` tells them apart. A spent account and a rate limit are both 429, and
    /// the difference matters to the person reading — one is fixed by waiting and the other is not.
    public static func refusal(status: Int, body: Data) -> SarvamError {
        let stated = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
        let code = stated?["code"] as? String ?? ""
        let message = (stated?["message"] as? String) ?? String(decoding: body.prefix(300), as: UTF8.self)

        if code == "insufficient_quota_error" { return .outOfCredits }
        switch status {
        case 401:
            return .keyRefused
        case 403 where code.isEmpty || code == "invalid_api_key_error" || code == "authentication_error":
            return .keyRefused
        case 429, 503:
            return .busy
        default:
            return .refused(status: status, message: message)
        }
    }
}

public struct SarvamClient: Sendable {

    public static let host = URL(string: "https://api.sarvam.ai")!

    /// Bulbul's own default, and one of the two voices its reference calls a safe start in every
    /// language. Named rather than left to the default: a companion's voice should not change
    /// because a provider changed its mind about a default.
    public static let defaultSpeaker = "shubh"

    /// Bulbul v3's speakers, as its reference listed them on 2026-09-30. A name that is not here is
    /// not sent — see `SarvamSpeech.speaker(named:)` — so a new voice cannot be chosen until this
    /// catches up, and a stale or mistyped one cannot fail every sentence.
    public static let speakers: Set<String> = [
        "shubh", "aditya", "ritu", "priya", "neha", "rahul", "pooja", "rohan", "simran", "kavya",
        "amit", "dev", "ishita", "shreya", "ratan", "varun", "manan", "sumit", "roopa", "kabir",
        "aayan", "ashutosh", "advait", "anand", "tanya", "tarun", "sunny", "mani", "gokul", "vijay",
        "shruti", "suhani", "mohit", "kavitha", "rehan", "soham", "rupali",
    ]

    static let speechModel = "bulbul:v3"

    /// Bulbul v3 takes 2500 characters a request.
    public static let longestUtterance = 2500

    /// One session for every client: nothing is cached and no cookie is kept, and a session per
    /// voice would be a session per change of language.
    public static let session = URLSession(configuration: .ephemeral)

    private let key: String
    private let urlSession: URLSession
    private let host: URL

    public init(key: String, urlSession: URLSession = SarvamClient.session, host: URL = SarvamClient.host) {
        // A pasted key routinely brings a newline with it, and an untrimmed one is refused in a
        // way indistinguishable from a wrong one.
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlSession = urlSession
        self.host = host
    }

    // MARK: ears

    /// What was said in `wav`, in `language` — Sarvam's code, "ml-IN". Up to thirty seconds.
    public func transcribe(wav: Data, language: String) async throws -> String {
        let data = try await send(Self.transcriptionRequest(wav: wav, language: language, key: key, host: host))
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transcript = answer["transcript"] as? String else {
            throw SarvamError.unreadable("there was no transcript in it")
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No `model` is named: Saaras's current one is the default, and naming a version here would
    /// only be a way to be left behind by the next. The language is named, because the person chose
    /// it in Settings, and an unpinned transcript is how clean English once came back as Chinese.
    static func transcriptionRequest(
        wav: Data, language: String, key: String, host: URL,
        boundary: String = "saathi-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: host.appendingPathComponent("speech-to-text"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func text(_ string: String) { body.append(Data(string.utf8)) }
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"language_code\"\r\n\r\n\(language)\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\n")
        text("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        text("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    // MARK: mouth

    /// `text` as speech: one WAV, or several to be played in order. Up to `longestUtterance`
    /// characters. `pace` is 1 for ordinary speed.
    public func synthesize(
        _ text: String, language: String, speaker: String = SarvamClient.defaultSpeaker, pace: Double = 1
    ) async throws -> [Data] {
        let request = try Self.speechRequest(
            text: text, language: language, speaker: speaker, pace: pace, key: key, host: host)
        let data = try await send(request)
        let audios = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["audios"] as? [Any] ?? []
        let clips = audios.compactMap { entry -> Data? in
            // The reference says a list of base64 strings; the troubleshooting page reads `.audio`
            // off each one. Either is taken.
            let encoded = (entry as? String) ?? ((entry as? [String: Any])?["audio"] as? String)
            let clip = encoded.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            return clip?.isEmpty == false ? clip : nil
        }
        guard !clips.isEmpty else { throw SarvamError.unreadable("there was no audio in it") }
        return clips
    }

    /// The fewest fields the reference allows: the text, its language, the voice and the model.
    /// The sample rate and the container are left to Bulbul's defaults — a WAV — because the player
    /// reads both from the file, and every field not sent is a field that cannot be refused.
    static func speechRequest(
        text: String, language: String, speaker: String, pace: Double, key: String, host: URL
    ) throws -> URLRequest {
        var request = URLRequest(url: host.appendingPathComponent("text-to-speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "text": text, "language_code": language, "speaker": speaker, "model": speechModel,
        ]
        // Bulbul v3 takes 0.5 to 2. Two decimals, so calm-and-slow is sent as 0.76 and not as the
        // seventeen digits a float makes of 0.9 × 0.85.
        if abs(pace - 1) > 0.001 { body["pace"] = (min(2, max(0.5, pace)) * 100).rounded() / 100 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: the wire

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cancelled task this way. It is not Sarvam being unreachable.
            throw CancellationError()
        } catch {
            throw SarvamError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SarvamError.unreadable("it was not an HTTP answer")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SarvamError.refusal(status: http.statusCode, body: data)
        }
        return data
    }
}
