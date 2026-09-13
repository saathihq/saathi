//
//  main.swift
//  saathi
//
//  The basic macOS client. A CLI for now — the point is that the contract, the config, the backend
//  client and the actions are all real and shared with whatever shell comes later.
//
//    saathi provider           which mode this is in, and whether anything leaves the machine
//    saathi voice              which voice lane that gives you, and where your voice goes
//    saathi actions            what this build can be asked to do
//    saathi health             is the backend up
//    saathi say "..."          say one line out loud
//    saathi demo               a three-step lesson, narrated
//
//  Add --quiet to any of them to print instead of speak.
//

import Foundation
import SaathiContract
import SaathiKit

let arguments = Array(CommandLine.arguments.dropFirst())
let quiet = arguments.contains("--quiet")
let positional = arguments.filter { !$0.hasPrefix("--") }
let command = positional.first ?? "help"

let speaker: any Speaker = quiet ? PrintingSpeaker() : SystemSpeaker()
let performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())

func toneOption() -> Tone {
    guard let raw = arguments.first(where: { $0.hasPrefix("--tone=") })?.dropFirst("--tone=".count),
          let tone = Tone(rawValue: String(raw))
    else { return .neutral }
    return tone
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("saathi: \(message)\n".utf8))
    exit(1)
}

switch command {
case "provider":
    let configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
    print(ProviderReport.describe(configuration))
    if arguments.contains("--probe") {
        let status = await ProviderReport.reachability(of: configuration)
        print("  status     \(status)")
    }

case "voice":
    // Deliberately the same shape as `provider`: the pure, contract-derived report by default, and
    // anything that touches this particular machine behind a flag. `check-parity.sh` diffs the
    // bare command against the Windows client, so nothing machine-specific may leak into it.
    let voiceConfiguration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
    print(VoiceLaneReport.describe(voiceConfiguration))

    if arguments.contains("--listen") {
        let session = try VoiceSessionFactory.make(configuration: voiceConfiguration, speaker: speaker)
        let callbacks = VoiceSessionCallbacks(
            onUserTranscript: { print("\nyou:    \($0)") },
            onSaathiTranscript: { print("saathi: \($0)") },
            onAction: { action in
                // The join that makes a voice turn and a typed command the same product: both end
                // at the same performer, with the same contract validation in front of them.
                Task { try? await performer.perform(action) }
            },
            onStatus: { FileHandle.standardError.write(Data("  [\($0)]\n".utf8)) }
        )
        do {
            try await session.start(callbacks: callbacks)
        } catch {
            fail("\(error.localizedDescription)")
        }
        print("\npress return to talk, return again to stop, or ctrl-c to quit")
        while true {
            _ = readLine()
            try await session.beginTurn()
            _ = readLine()
            try await session.endTurn()
        }
    }

case "actions":
    print("contract \(SaathiBackend.contractVersion) — \(SaathiAction.allWireNames.count) actions")
    for wireName in SaathiAction.allWireNames { print("  \(wireName)") }
    print("\ntones: \(Tone.allCases.map(\.rawValue).joined(separator: ", "))")
    print("paces: \(Pace.allCases.map(\.rawValue).joined(separator: ", "))")

case "health":
    let configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
    print("backend: \(configuration.resolvedBaseURL)")
    do {
        let client = try BackendClient(configuration: configuration)
        let health = try await client.health()
        print("health: ok=\(health.ok) version=\(health.version ?? "unknown")")
    } catch {
        fail("\(error)")
    }

case "say":
    guard positional.count > 1 else { fail("say what? — saathi say \"hello\"") }
    let text = positional.dropFirst().joined(separator: " ")
    try await performer.perform(.say(SayAction(text: text, tone: toneOption())))

case "demo":
    // Deliberately hard-coded: this is the smoke test that the contract, the action performer and
    // the speaker all line up, not a feature. What a real lesson looks like is one of the open
    // product questions in the root README.
    let steps = [
        ShowStepAction(title: "Pick something you want to learn", index: 1, total: 3,
                       detail: "Anything at all. Saathi is here to keep you company while you do."),
        ShowStepAction(title: "Try the first small piece of it", index: 2, total: 3,
                       detail: "Small enough that getting it wrong costs nothing."),
        ShowStepAction(title: "Tell Saathi how that went", index: 3, total: 3),
    ]
    for step in steps {
        try await performer.perform(.showStep(step))
    }
    try await performer.perform(.say(SayAction(text: "That is the whole loop.", tone: .calm)))

case "help", "--help", "-h":
    print("""
    saathi — a companion for learning and playing with new things

      saathi provider             which mode this is in  (--probe to check it is reachable)
      saathi voice                which voice lane, and where your voice goes  (--listen to talk)
      saathi actions              list what this build can be asked to do
      saathi health               check the backend
      saathi say "..."            say one line  (--tone=calm|encouraging|neutral)
      saathi demo                 a three-step lesson, narrated

      --quiet                     print instead of speaking
    """)

default:
    fail("unknown command \"\(command)\" — try `saathi help`")
}
