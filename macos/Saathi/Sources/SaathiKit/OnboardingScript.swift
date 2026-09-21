//
//  OnboardingScript.swift
//  SaathiKit
//
//  Every line Saathi says during first run, and the title of the card it says it on.
//
//  The spec's rule is that everything on a card is also spoken: someone who cannot see the card
//  must be able to complete first run, which is the whole premise of the product applied to its own
//  front door. One table makes that checkable — a step with nothing to say fails a test — where
//  sentences scattered through view code would have it true of the steps someone remembered.
//
//  Sentences the spec wrote out are verbatim. The rest are in the same voice: short, first person,
//  said the way you would say them to someone sitting next to you.
//

import Foundation
import SaathiContract

public struct OnboardingLine: Equatable, Sendable {
    /// Shown on the card or in the notch panel.
    public let title: String
    /// Spoken when the step is entered.
    public let spoken: String
    public let tone: Tone

    public init(title: String, spoken: String, tone: Tone = .encouraging) {
        self.title = title
        self.spoken = spoken
        self.tone = tone
    }
}

public enum OnboardingScript {

    public static let hostedDisclosure =
        "For this chat I'll use Saathi's hosted service. Your voice goes to Saathi's servers and its "
        + "provider for these minutes. After this you choose where I think."

    /// Said once on the welcome card, next to the switch that undoes it.
    public static let startAtLoginNote = "I've set myself to start when you log in. You can turn that off right here."

    /// The floating card beside System Settings while Input Monitoring is being granted.
    public static let inputMonitoringHelper = "I'm Saathi. Turn me on in the list."

    public static func line(for model: OnboardingModel) -> OnboardingLine {
        switch model.step {
        case .welcome:
            return OnboardingLine(
                title: "Namaste",
                spoken: "Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this.")
        case .colour:
            return OnboardingLine(title: "Pick a colour", spoken: "Pick a colour for me. Any of these ten. You can change it later.")
        case .intoNotch:
            return OnboardingLine(
                title: "I live up here now",
                spoken: "I live up here now. I need three permissions to get started.")
        case let .permission(permission):
            return OnboardingLine(title: permission.title, spoken: permission.reason, tone: .calm)
        case .allSet:
            return OnboardingLine(title: "All set", spoken: "Turn your sound on. Meet Saathi.")
        case let .demo(demo):
            return line(for: demo, in: model)
        case .finished:
            return OnboardingLine(
                title: "Ready",
                spoken: model.opensSetupAfterwards
                    ? "That's everything. I've opened Setup, so you can tell me where to think."
                    : "That's everything. Hold control and option whenever you want me.")
        }
    }

    private static func line(for demo: DemoStep, in model: OnboardingModel) -> OnboardingLine {
        switch demo {
        case .micCheck:
            return OnboardingLine(
                title: "Can I hear you?",
                // No level bars yet — the audio engine has no tap to drive them — so the line does
                // not promise any. The transcript is the proof of being heard.
                spoken: "Can I hear you? Say anything, and I'll show you what I heard.")
        case .holdToTalk:
            return OnboardingLine(
                title: "This is how you talk to me.",
                spoken: model.permissions[.inputMonitoring] == .granted
                    ? "This is how you talk to me. Hold control and option, and say hi."
                    : "This is how you talk to me: hold control and option, and speak. That needs Input Monitoring, which isn't on yet, so for now use Talk in the menu.")
        case let .question(question):
            return OnboardingLine(
                title: title(for: question),
                spoken: model.isReasking ? reask(question) : ask(question),
                tone: .calm)
        case .trialChat:
            return trialLine(for: model.trial)
        case .providerChoice:
            return OnboardingLine(
                title: "Where should I think from now on?",
                spoken: model.availableProviderChoices.contains(.hosted)
                    ? "Where should I think from now on? Keep using Saathi's service, use a model on this Mac, or use your own key."
                    : "Where should I think from now on? A model on this Mac, or your own key.",
                tone: .calm)
        }
    }

    private static func trialLine(for trial: TrialState) -> OnboardingLine {
        let title = "Talk to me properly."
        switch trial {
        case .notAsked:
            return OnboardingLine(title: title, spoken: hostedDisclosure, tone: .calm)
        case .asking:
            return OnboardingLine(title: title, spoken: "One moment. I'm setting that up.", tone: .calm)
        case .ready:
            return OnboardingLine(title: title, spoken: "Ready. Hold control and option, and ask me anything.")
        case let .failed(reason):
            return OnboardingLine(
                title: title,
                spoken: "I couldn't set that up: \(reason). You can try again, or skip this and choose where I think.",
                tone: .calm)
        }
    }

    private static func title(for question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "What should I call you?"
        case .firstGoal: return "What do you want to start with?"
        case .manner: return "How should I speak?"
        case .language: return "Which language?"
        }
    }

    private static var mannerChoices: String {
        let titles = Manner.allCases.map(\.title)
        return titles.dropLast().joined(separator: ", ") + ", or " + (titles.last ?? "")
    }

    private static func ask(_ question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "What should I call you?"
        case .firstGoal: return "What do you want to learn, or play with, first?"
        case .manner: return "How would you like me to speak: \(mannerChoices)?"
        case .language: return "Which language shall we talk in?"
        }
    }

    private static func reask(_ question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "Sorry, I didn't catch a name. What should I call you? You can type it too."
        case .firstGoal: return "Sorry, I missed that. What would you like to start with? You can type it too."
        case .manner: return "Sorry, I need one of these: \(mannerChoices). Which would you like?"
        case .language: return "Sorry, that isn't one I can listen in on this Mac. You can pick from the list on the card."
        }
    }

    /// Said on leaving a question. Works with nothing answered, because a question can be left
    /// that way.
    public static func acknowledgement(of question: OnboardingQuestion, in answers: OnboardingAnswers) -> String {
        switch question {
        case .name:
            return answers.name.map { "Good to meet you, \($0)." } ?? "That's fine. We can do names later."
        case .firstGoal:
            return answers.firstGoal.map { "\($0). Good, we'll start there." } ?? "No hurry. We'll find something."
        case .manner:
            return "Okay, \((answers.manner ?? .warmAndNormal).title) it is."
        case .language:
            let name = answers.language.flatMap { tag -> String? in
                let code = Locale(identifier: tag).language.languageCode?.identifier ?? tag
                return Locale(identifier: "en").localizedString(forLanguageCode: code)
            }
            return name.map { "\($0) it is." } ?? "We'll carry on as we are."
        }
    }

    public static func deniedNote(for permission: Permission) -> String {
        let cost: String
        switch permission {
        case .microphone: cost = "Without the microphone I can't hear you at all."
        case .speechRecognition: cost = "Without it I can't turn your voice into words on this Mac."
        case .inputMonitoring: cost = "Without it I can't notice the keys, so you'd use Talk in the menu instead."
        case .screenRecording: cost = "Without it I can't look at your screen when you ask."
        case .accessibility: cost = "Without it I'm less sure exactly what your pointer is on."
        }
        return "\(cost) You can turn it on later in System Settings, under Privacy and Security, \(permission.title)."
    }

    public static func title(for choice: ProviderChoice) -> String {
        switch choice {
        case .hosted: return "Keep using Saathi's service"
        case .local: return "A model on this Mac"
        case .ownKey: return "Your own key"
        }
    }

    public static func detail(for choice: ProviderChoice) -> String {
        switch choice {
        case .hosted: return "Your voice goes to Saathi's servers and its provider. Three conversations a day, for the rest of your seven-day trial."
        case .local: return "Everything stays on this Mac. It needs a local model running; I'll tell you if I can't find one."
        case .ownKey: return "Your voice goes straight to the provider whose key you paste, never through Saathi's servers."
        }
    }
}
