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
//  capture is a single frame of one display — the one the pointer is on — written to a temporary
//  file, read once, and deleted.
//
//  ── "This song" ──────────────────────────────────────────────────────────────
//  Nearly every question asked of a screen is about the thing under the pointer. A frame of the
//  whole display does not say where that is: asked "how do I play this song" over a list of
//  songs, the vision model answered about the one that happened to be playing. Drawing the pointer
//  into the frame and stating its position as a percentage did not help either — a 3000-pixel
//  screenshot is downscaled before the model sees it, and a 20-pixel arrow does not survive. What
//  worked, measured against Spotify on this machine, is a second picture: a close-up around the
//  pointer, cut from the same frame, with the pointer at its centre. It named the row.
//
//  Anthropic is preferred when a key for it exists: OpenClicky measured Claude locating an element
//  on a screenshot to within a few pixels where the realtime model's own guess was hundreds of
//  pixels out, and this is the same class of task. Otherwise OpenAI's vision model is used, so
//  sight works for someone who only ever pasted one key.
//

import CoreGraphics
import Foundation
import ImageIO
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

/// Captures one frame of the display the pointer is on, with the pointer drawn in, and cuts a
/// close-up around the pointer from it.
///
/// `screencapture` rather than ScreenCaptureKit: it is the same tool OpenClicky uses, it needs no
/// entitlement of its own beyond the Screen Recording grant every path requires, and a failure is a
/// non-zero exit with a readable reason rather than a silent black frame. The grant is checked
/// first, because without it `screencapture` does not fail — it returns the wallpaper.
public struct ScreenCapture: Sendable {

    public init() {}

    /// The close-up around the pointer, in points: wide enough for a row of a list with its title
    /// and its controls, short enough that the pointer's own row is unmistakably the middle one.
    public static let closeUpSize = CGSize(width: 600, height: 360)

    /// What one look sends: the pointer's whole display, and the close-up cut from it. Both PNG.
    public struct Frames: Sendable {
        public let display: Data
        public let closeUp: Data
        /// Where the pointer was when the frame was taken, in global top-left-origin coordinates,
        /// so Accessibility is asked about the same spot the close-up is centred on.
        public let pointer: CGPoint
    }

    /// The two regions of one look, in the global top-left-origin coordinates that `CGDisplayBounds`,
    /// `CGEvent.location` and `screencapture -R` share: the pointer's whole display, and the close-up
    /// centred on the pointer, slid inward where centring would leave the display.
    public static func regions(display: CGRect, pointer: CGPoint) -> (display: CGRect, closeUp: CGRect) {
        let size = CGSize(width: min(closeUpSize.width, display.width), height: min(closeUpSize.height, display.height))
        var closeUp = CGRect(origin: CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2), size: size)
        closeUp.origin.x = max(display.minX, min(closeUp.origin.x, display.maxX - size.width))
        closeUp.origin.y = max(display.minY, min(closeUp.origin.y, display.maxY - size.height))
        return (display, closeUp)
    }

    static let permissionMessage =
        "Saathi needs Screen Recording permission to see the screen. Grant it in System "
        + "Settings → Privacy & Security → Screen Recording, then quit and reopen Saathi."

    /// One frame of the pointer's display and the close-up around the pointer. The file behind
    /// them is removed before this returns.
    public func capture() throws -> Frames {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system dialog the first time and only reports afterwards. Either way the
            // answer is no right now, and the model is told so rather than handed the wallpaper.
            _ = CGRequestScreenCaptureAccess()
            throw ScreenSightError.notPermitted(Self.permissionMessage)
        }

        let main = CGDisplayBounds(CGMainDisplayID())
        let pointer = CGEvent(source: nil)?.location ?? CGPoint(x: main.midX, y: main.midY)
        var displayID = CGMainDisplayID()
        var underPointer: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(pointer, 1, &underPointer, &count) == .success, count > 0 {
            displayID = underPointer
        }
        let regions = Self.regions(display: CGDisplayBounds(displayID), pointer: pointer)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-sight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x silent, -t png, -C with the pointer drawn in, -R exactly the pointer's display. One
        // display, so a second monitor's contents are never sent along with the one asked about.
        let region = regions.display
        process.arguments = [
            "-x", "-t", "png", "-C",
            "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))",
            url.path,
        ]
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
            throw ScreenSightError.captureFailed(detail.isEmpty ? "screencapture exited \(process.terminationStatus)" : detail)
        }
        return Frames(
            display: data,
            closeUp: try Self.crop(data, from: regions.display, to: regions.closeUp),
            pointer: pointer)
    }

    /// The close-up, cut from the frame rather than captured again: a second capture a moment
    /// later can differ from the first, and the pointer must be in the same place in both.
    static func crop(_ png: Data, from display: CGRect, to region: CGRect) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenSightError.captureFailed("the captured frame could not be read")
        }
        // Points to pixels: 2 on a Retina display, 1 on most external ones.
        let scale = CGFloat(image.width) / display.width
        let pixels = CGRect(
            x: (region.minX - display.minX) * scale,
            y: (region.minY - display.minY) * scale,
            width: region.width * scale,
            height: region.height * scale)
        guard let cropped = image.cropping(to: pixels) else {
            throw ScreenSightError.captureFailed("the close-up could not be cut from the frame")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw ScreenSightError.captureFailed("the close-up could not be encoded")
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenSightError.captureFailed("the close-up could not be encoded")
        }
        return out as Data
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
    /// It says what the second picture is, because "this" in the question is resolved there. The
    /// length cap is not decoration: this answer is about to be read aloud.
    ///
    /// `grounding` is what macOS Accessibility says is under the pointer, when it says anything.
    /// It settles *which* thing is meant — the one question pixels answer badly, since forty rows
    /// of a list look alike and a 20-pixel arrow does not survive downscaling — and the pictures
    /// answer everything else.
    static func systemPrompt(question: String, grounding: PointerContext? = nil) -> String {
        let grounded = grounding.map {
            """


            \($0.sentence) This comes from the system, not from the pictures: trust it for which \
            thing "this" is, and use the pictures for what that thing looks like, what is around \
            it and how to act on it. Do not mention Accessibility in your answer.
            """
        } ?? ""
        return """
        You are the eyes of a companion that is helping someone at their Mac. You are given two \
        pictures of their screen and something they asked about it: the whole display, and a \
        close-up of the area around the mouse pointer, with the pointer at its centre. "This", \
        "here" and "that" mean whatever is under or nearest the pointer in the close-up. Answer in \
        one or two short sentences, as they will be spoken aloud, not read.

        Say what the thing actually is and where it is, in words someone who cannot see the screen \
        can act on — "the folder under your pointer is called Saathi Signing, on the right of the \
        desktop" rather than "a blue folder icon". If what they asked about is not on the screen, \
        say so plainly rather than describing something else.\(grounded)

        Their question: \(question)
        """
    }

    /// Captures the screen and answers `question` about it.
    public func look(question: String) async throws -> String {
        guard let eye = Self.eye(for: configuration) else { throw ScreenSightError.noVisionKey }
        let frames = try capture.capture()
        let pictures = [frames.display.base64EncodedString(), frames.closeUp.base64EncodedString()]
        // Nil without the Accessibility grant or over an app with no tree; sight then works from
        // the pictures alone, as it did before.
        let system = Self.systemPrompt(question: question, grounding: PointerGrounding.context(at: frames.pointer))

        switch eye {
        case let .anthropic(model):
            return try await askAnthropic(model: model, pictures: pictures, system: system, question: question)
        case let .openai(model):
            return try await askOpenAI(model: model, pictures: pictures, system: system, question: question)
        }
    }

    private func askAnthropic(model: String, pictures: [String], system: String, question: String) async throws -> String {
        guard let key = configuration.credential(for: .anthropic) else { throw ScreenSightError.noVisionKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "system": system,
            "messages": [[
                "role": "user",
                "content": pictures.map {
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": $0]]
                } + [["type": "text", "text": question]],
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

    private func askOpenAI(model: String, pictures: [String], system: String, question: String) async throws -> String {
        guard let key = configuration.credential(for: .openai) else { throw ScreenSightError.noVisionKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [["type": "text", "text": question]] + pictures.map {
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\($0)"]]
                }],
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
