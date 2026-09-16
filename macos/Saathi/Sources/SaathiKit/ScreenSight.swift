//
//  ScreenSight.swift
//  SaathiKit
//
//  Letting Saathi see the screen, which until now it could not do at all.
//
//  The gap this closes is not a small one. Asked "what is this folder?", a companion with no eyes
//  either invents an answer — which it did, describing a scene that was not there — or says it
//  cannot see, which is honest and useless. Neither is what someone pointing at their own screen
//  wants.
//
//  ── Why a second model, and not the realtime socket ──────────────────────────
//  The realtime lane carries audio, not images: `gpt-realtime` has no way to be handed a PNG
//  mid-conversation. So sight is a separate, deliberate call — the voice model asks for it through
//  a tool, this captures the screen and puts the question to a vision model, and the answer goes
//  back into the conversation as text the voice model then speaks.
//
//  ── Where the picture goes, said plainly ─────────────────────────────────────
//  This sends an image of the learner's screen to a provider. That is the most invasive thing
//  Saathi does, and it is why it happens only when a turn actually asks about something visual,
//  never on a timer and never in the background. `ProviderReport` says so out loud, and the
//  capture is a single frame of the main display that is written to a temporary file, read once,
//  and deleted.
//
//  Anthropic is preferred when a key for it exists: OpenClicky measured Claude locating an element
//  on a screenshot to within a few pixels where the realtime model's own guess was hundreds of
//  pixels out, and this is the same class of task. Otherwise OpenAI's vision model is used, so
//  sight works for someone who only ever pasted one key.
//

import Foundation
import SaathiContract

public enum ScreenSightError: Error, CustomStringConvertible, Equatable {
    case notPermitted(String)
    case captureFailed(String)
    case noVisionKey
    case refused(String)

    public var description: String {
        switch self {
        case let .notPermitted(reason): return reason
        case let .captureFailed(reason): return "could not capture the screen: \(reason)"
        case .noVisionKey:
            return "seeing the screen needs an OpenAI or Anthropic key. Add one in Setup."
        case let .refused(reason): return reason
        }
    }
}

/// Captures one frame of the main display.
///
/// `screencapture` rather than ScreenCaptureKit: it is the same tool OpenClicky uses, it needs no
/// entitlement of its own beyond the Screen Recording grant every path requires, and a failure is a
/// non-zero exit with a readable reason rather than a silent black frame.
public struct ScreenCapture: Sendable {

    public init() {}

    /// A PNG of the main display, as bytes. The file behind it is removed before this returns.
    public func capture() throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-sight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x silent, -t png, -m main display only. One display, so a second monitor's contents are
        // never sent along with the one that was asked about.
        process.arguments = ["-x", "-t", "png", "-m", url.path]
        let errors = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ScreenSightError.captureFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            // The overwhelmingly common cause is the grant, so name it rather than the exit code.
            throw ScreenSightError.notPermitted(
                "Saathi needs Screen Recording permission to see the screen. Grant it in System "
                + "Settings → Privacy & Security → Screen Recording, then quit and reopen Saathi."
                + (detail.isEmpty ? "" : " (\(detail))"))
        }
        return data
    }
}

/// Puts a question about the screen to a vision model and returns the answer as spoken-length text.
public struct ScreenSight: Sendable {

    private let configuration: SaathiConfiguration
    private let capture: ScreenCapture
    private let urlSession: URLSession

    public init(
        configuration: SaathiConfiguration,
        capture: ScreenCapture = ScreenCapture(),
        urlSession: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.configuration = configuration
        self.capture = capture
        self.urlSession = urlSession
    }

    /// Which provider answers the question, and with which model.
    ///
    /// Anthropic first when its key is there: OpenClicky measured Claude placing an element on a
    /// screenshot within a few pixels where the realtime model's own guess was hundreds out, and
    /// describing what is on screen is the same kind of looking. OpenAI otherwise, so sight works
    /// for someone who pasted one key and stopped.
    public enum Eye: Equatable, Sendable {
        case anthropic(model: String)
        case openai(model: String)

        public var vendorName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            }
        }
    }

    public static func eye(for configuration: SaathiConfiguration) -> Eye? {
        if configuration.credential(for: .anthropic) != nil {
            return .anthropic(model: "claude-haiku-4-5-20251001")
        }
        if configuration.credential(for: .openai) != nil {
            return .openai(model: "gpt-4o-mini")
        }
        return nil
    }

    /// The instruction the vision model works to.
    ///
    /// Written for someone who cannot see the screen themselves — which is the whole premise of the
    /// product — so it asks for what a thing *is* and where it sits, not for a catalogue of pixels.
    /// The length cap is not decoration: this answer is about to be read aloud.
    static func systemPrompt(question: String) -> String {
        """
        You are the eyes of a companion that is helping someone at their Mac. You are given a \
        screenshot of their screen and something they asked about it. Answer in one or two short \
        sentences, as they will be spoken aloud, not read.

        Say what the thing actually is and where it is, in words someone who cannot see the screen \
        can act on — "the folder under your pointer is called Saathi Signing, on the right of the \
        desktop" rather than "a blue folder icon". If they point at something and you cannot tell \
        which of several they mean, say which ones you can see and ask. If what they asked about is \
        not on the screen, say so plainly rather than describing something else.

        Their question: \(question)
        """
    }

    /// Captures the screen and answers `question` about it.
    public func look(question: String) async throws -> String {
        guard let eye = Self.eye(for: configuration) else { throw ScreenSightError.noVisionKey }
        let png = try capture.capture()
        let base64 = png.base64EncodedString()

        switch eye {
        case let .anthropic(model):
            return try await askAnthropic(model: model, base64: base64, question: question)
        case let .openai(model):
            return try await askOpenAI(model: model, base64: base64, question: question)
        }
    }

    private func askAnthropic(model: String, base64: String, question: String) async throws -> String {
        guard let key = configuration.credential(for: .anthropic) else { throw ScreenSightError.noVisionKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "system": Self.systemPrompt(question: question),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                    ["type": "text", "text": question],
                ],
            ]],
        ])
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data: data, vendor: "Anthropic")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ScreenSightError.refused("Anthropic's answer could not be read.")
        }
        let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        return Self.tidied(text)
    }

    private func askOpenAI(model: String, base64: String, question: String) async throws -> String {
        guard let key = configuration.credential(for: .openai) else { throw ScreenSightError.noVisionKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(question: question)],
                ["role": "user", "content": [
                    ["type": "text", "text": question],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/png;base64,\(base64)"]],
                ]],
            ],
        ])
        let (data, response) = try await urlSession.data(for: request)
        try Self.check(response, data: data, vendor: "OpenAI")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw ScreenSightError.refused("OpenAI's answer could not be read.")
        }
        return Self.tidied(text)
    }

    /// A non-2xx is reported without the response body: a vision request carries an image of the
    /// learner's screen, and a provider that quotes the request back would put part of it in a log.
    private static func check(_ response: URLResponse, data: Data, vendor: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ScreenSightError.refused("\(vendor) gave an answer that could not be read.")
        }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw ScreenSightError.refused("\(vendor) did not accept that key.")
        default: throw ScreenSightError.refused("\(vendor) answered \(http.statusCode); try again shortly.")
        }
    }

    static func tidied(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}
