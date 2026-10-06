//
//  AppController+Wording.swift
//  SaathiShell
//
//  What the island and the log say about a configuration, an action or the three key fields.
//
//  Static and pure so the wording can be tested without a window, a session or a key. These are
//  the sentences that tell someone where their voice goes, which makes them worth pinning down —
//  and worth keeping out from between the menu wiring and the voice lifecycle, where they sat.
//

import Foundation
import SaathiContract
import SaathiKit

extension AppController {

    /// An action as one log line: its wire name and the thing it carries.
    static func describe(_ action: SaathiAction) -> String {
        switch action {
        case let .say(say): return "say: \(say.text)"
        case let .showStep(step): return "show_step \(step.index)/\(step.total): \(step.title)"
        case let .openUrl(open): return "open_url: \(open.url)"
        case let .lookAtScreen(look): return "look_at_screen: \(look.question)"
        }
    }

    /// What the (i) says out loud. One sentence per thing Saathi actually does — not a description
    /// of the roadmap, because someone pressing (i) is asking what this can do for them now.
    static let whatSaathiDoes = """
        I am Saathi. Hold control and option and talk to me, and I will answer out loud. \
        Ask me about something on your screen and I will look at it. \
        Everything I know about where I think and what leaves this machine is on the Setup tab.
        """

    // MARK: what the island says about a configuration
    //
    // Static and pure so the wording can be tested without a window, a session or a key. These are
    // the sentences that tell someone where their voice goes, which makes them worth pinning down.

    static func providerTitle(for configuration: SaathiConfiguration) -> String {
        "\(configuration.resolvedProvider.rawValue) · \(configuration.resolvedModel)"
    }

    /// Everything the island says about a configuration, written onto its model: where it thinks,
    /// whose voice answers, what leaves the machine, and what the picker and the switch can offer.
    /// Static, so the Setup tab can be drawn for a configuration with no app behind it.
    static func describe(_ configuration: SaathiConfiguration, on model: IslandModel) {
        model.providerTitle = providerTitle(for: configuration)
        model.privacyLine = privacyLine(for: configuration)
        model.voiceTitle = voiceTitle(for: configuration)
        model.laneTitle = configuration.providerRow.voice == .realtime
            ? "one connection"
            : "three steps"
        model.language = configuration.resolvedLanguage

        // The picker and the switch under Voice: where it thinks and where it could, and whether
        // Sarvam is — or could be — its ears and mouth.
        model.provider = configuration.resolvedProvider
        model.providerChoices = providerChoices(for: configuration)
        model.sarvamSpeechOn = SarvamSpeech.isOn(configuration)
        model.sarvamSpeechAvailable = sarvamSpeechAvailable(for: configuration)

        // The status pill in the menu-bar band, and the Backend rows on Setup. Two different
        // questions: the pill says where Saathi is connected on the lane in use, the rows say
        // whether the hosted backend is set up — which off the hosted lane it need not be.
        let pill = connectionPill(for: configuration)
        model.connectionTitle = pill.title
        model.isConnectionConfigured = pill.isConfigured
        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model.usesBackend = configuration.providerRow.requiresToken
        model.isBackendConfigured = !token.isEmpty
        model.backendTitle = backendTitle(for: configuration)
    }

    /// What the status pill in the band says, and whether it reads as connected.
    struct ConnectionPill: Equatable {
        let title: String
        let isConfigured: Bool
    }

    /// The pill describes the lane in use, not the hosted backend regardless of lane. OpenClicky
    /// has one backend and shows its host; Saathi's config can talk straight to a vendor with its
    /// own key, and a red "Set up backend" over exactly that config told someone with a working
    /// install to go and configure something nothing would ever read. So: the backend's host on the
    /// hosted lane, the vendor's host on an own-key lane, the local server otherwise — and red only
    /// when the lane in use is missing the one credential it needs.
    static func connectionPill(for configuration: SaathiConfiguration) -> ConnectionPill {
        let row = configuration.providerRow
        if row.requiresToken {
            let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty
                ? ConnectionPill(title: "Set up backend", isConfigured: false)
                : ConnectionPill(title: host(of: configuration.resolvedBaseURL), isConfigured: true)
        }
        if row.requiresKey, configuration.credential(for: row.kind) == nil {
            return ConnectionPill(title: "Add a key", isConfigured: false)
        }
        return ConnectionPill(title: host(of: configuration.resolvedProviderBaseURL), isConfigured: true)
    }

    /// The Setup tab's Backend row. Only the hosted lane has a backend, so on every other lane the
    /// row says so rather than nagging about a token nothing would read.
    static func backendTitle(for configuration: SaathiConfiguration) -> String {
        guard configuration.providerRow.requiresToken else { return "not used" }
        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? "Set up backend" : host(of: configuration.resolvedBaseURL)
    }

    /// "api.openai.com", or "localhost:11434": the port only when the URL names one, because a
    /// local server is told apart by its port and a vendor never is. The whole string if it is
    /// not a URL at all, so a typo in the config is shown rather than hidden.
    static func host(of urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    static func privacyLine(for configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "your voice leaves as audio" }
        // Before the provider's own line: with Sarvam's ears the audio goes whoever does the
        // thinking, a model on this Mac included.
        if SarvamSpeech.isOn(configuration) { return "your voice leaves as audio, to Sarvam" }
        return row.sendsDataOffMachine ? "only the transcript is sent" : "stays on this machine"
    }

    /// Whose voice answers: the realtime voice by name, Sarvam's speaker by name, or this Mac's.
    static func voiceTitle(for configuration: SaathiConfiguration) -> String {
        if configuration.providerRow.voice == .realtime {
            return configuration.resolvedVoice.isEmpty ? "—" : configuration.resolvedVoice
        }
        if SarvamSpeech.isOn(configuration) { return "Sarvam · \(SarvamSpeech.speaker(named: configuration.voice))" }
        return "this Mac's"
    }

    /// A provider as a person would name it.
    static func vendorName(_ kind: ProviderKind) -> String {
        switch kind {
        case .openai: return "OpenAI"
        case .sarvam: return "Sarvam"
        case .anthropic: return "Anthropic"
        case .local: return "This Mac"
        case .hosted: return "Saathi's service"
        }
    }

    /// What the stored keys are for, and what is in the way of the plan — under the sentence, in a
    /// smaller voice. Empty when there is nothing to add.
    ///
    /// It used to say "Anthropic key saved. Nothing uses it yet." about a key `ScreenSight` has
    /// preferred since the day it was written.
    static func keysNote(for plan: SetupPlan, language: String) -> String {
        var sentences: [String] = []
        if plan.speech == .sarvam, SarvamLanguage.code(for: language) == nil {
            // Said before it is saved: the session would refuse to start, and this is why.
            sentences.append(
                "Sarvam does not hear or speak \(SarvamLanguage.name(of: language)). "
                + "Choose another language under Voice first.")
        }
        if let eye = plan.eye, eye != plan.provider {
            sentences.append("The \(vendorName(eye)) key looks at the screen when you ask about something on it.")
        } else if plan.eye == nil, !plan.stored.isEmpty {
            sentences.append("Nothing here can look at the screen: that takes an OpenAI or an Anthropic key.")
        }
        for unused in plan.storedButUnused {
            let name = vendorName(unused)
            sentences.append("The \(name) key is saved and not in use. Choose \(name) under Where it thinks to use it.")
        }
        return sentences.joined(separator: " ")
    }

    /// Which face the island opens on. Derived from the configuration rather than from a
    /// "has onboarded" flag, so it cannot get out of step with what is actually configured.
    static func openingTab(for configuration: SaathiConfiguration) -> IslandTab {
        let hasKey = ProviderKind.allCases.contains { configuration.credential(for: $0) != nil }
        let hasToken = !(configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasKey || hasToken) ? .home : .setup
    }

    /// What `onSaveKeys` should actually save: the field's text if there is any, the key already on
    /// disk otherwise. The Setup fields live in view-local `@State`, destroyed whenever the view
    /// leaves the tree — saving switches to Home, and the island collapsing on hover-out tears down
    /// the whole tree — while a `.saved` verdict survives in the long-lived `IslandModel`. Without
    /// this fallback, reopening Setup with an empty field but a remembered "saved" verdict reads as
    /// "no key" and erases the one that already worked.
    static func effectiveKey(field: String, stored: String?) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (stored ?? "") : field
    }

    /// The verdict that stands for a field. A check is about the text that was in the field when it
    /// ran; once the field is empty — the island collapsed and took the text with it — that verdict
    /// is about nothing, and the key that stands in is the one on disk, with the verdict the disk
    /// earns. Without this a new key checked, then lost to a collapse, left "works" beside an empty
    /// field, and Save wrote the old, dead key back under it.
    static func verdict(_ state: KeyFieldState, isTyped: Bool, seeded: KeyFieldState) -> KeyFieldState {
        guard !isTyped else { return state }
        switch state {
        case .saved, .empty: return state
        case .editing, .checking, .checked: return seeded
        }
    }

    /// The vendors whose field has something in it. Which, not what: a key being typed stays in
    /// the view, and the plan only ever needs to know that one is there.
    static func typed(in fields: VendorKeys) -> Set<ProviderKind> {
        Set(SetupPlan.vendors.filter { !fields[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// The typed keys Save has to check before it can save them: text in the field and no verdict
    /// of "accepted" behind it. A check already in flight is left to land on its own.
    static func keysNeedingCheck(fields: VendorKeys, states: KeyStates) -> [ProviderKind] {
        let withText = typed(in: fields)
        return SetupPlan.vendors.filter { kind in
            guard withText.contains(kind) else { return false }
            switch states[kind] {
            case .checked(.valid), .checking: return false
            default: return true
            }
        }
    }

    /// Whether a key counts as usable for `SetupPlan`: a verdict that says so, *and* a key actually
    /// behind it. A `.saved` or `.checked(.valid)` verdict with no key (nothing on disk, an empty
    /// field) must not count.
    static func isUsable(_ state: KeyFieldState, hasKey: Bool) -> Bool {
        state.isValid && hasKey
    }

    /// What a Save would do: the plan, and the keys it would be applied with.
    struct SetupDecision: Equatable {
        let plan: SetupPlan
        let keys: VendorKeys
    }

    /// The one place the Setup tab decides anything.
    ///
    /// **The invariant: the sentence shown under the key fields must describe exactly the plan that
    /// pressing Save would produce, at every point.** It is the most consequential text in the app —
    /// it tells someone whether their voice leaves this machine — so a preview that is merely
    /// *usually* right is a lie waiting to happen.
    ///
    /// Sharing a rule was not enough: `refreshPlanExplanation` used to default the field that had
    /// not just changed to `""` and fall back to `configuration.openaiKey`/`anthropicKey`, so on a
    /// fresh install checking a second key judged the first one against an empty string, flipped the
    /// plan to Anthropic and promised "your voice stays here" — and then Save, which saw both real
    /// fields, streamed audio to OpenAI. So the sentence and Save both come through here, with the
    /// same three inputs: which fields have text, every verdict, and the file. The stored fallback
    /// is `credential(for:)`, not the vendor field, so a legacy shared `apiKey` counts here exactly
    /// as it counts everywhere else that asks for a key; reading the vendor fields directly made
    /// Save see no key at all on a legacy config and demote a working install to `.local`.
    static func setupPlan(
        typed: Set<ProviderKind>, states: KeyStates, configuration: SaathiConfiguration
    ) -> SetupPlan {
        let seeded = seededKeyStates(for: configuration)
        let valid = SetupPlan.vendors.filter { kind in
            isUsable(
                verdict(states[kind], isTyped: typed.contains(kind), seeded: seeded[kind]),
                hasKey: typed.contains(kind) || configuration.credential(for: kind) != nil)
        }
        return SetupPlan.make(
            valid: Set(valid), typed: typed,
            current: providerInUse(configuration), speech: configuration.resolvedSpeech)
    }

    /// The sentence under the key fields, and the plan it describes.
    struct SetupPreview: Equatable {
        let plan: SetupPlan
        let sentence: String
    }

    /// What Save would do, for the sentence under the fields.
    ///
    /// Save checks every typed key and saves in the same breath if they were all accepted, so a
    /// key has been saved by the time it has a verdict. What is described here is therefore the
    /// plan with every typed key taken as accepted — which is `setupPlan` once the checks have
    /// landed — and while any of them has not been accepted yet the sentence is an "if". Someone
    /// pasting a key reads where their voice would go before they press Save, not in the instant
    /// after it has gone there.
    static func setupPreview(
        typed: Set<ProviderKind>, states: KeyStates, configuration: SaathiConfiguration
    ) -> SetupPreview {
        var accepted = states
        var awaited: [String] = []
        for kind in SetupPlan.vendors where typed.contains(kind) && states[kind] != .checked(.valid) {
            accepted[kind] = .checked(.valid)
            awaited.append(vendorName(kind))
        }
        let plan = setupPlan(typed: typed, states: accepted, configuration: configuration)
        guard let last = awaited.last else { return SetupPreview(plan: plan, sentence: plan.explanation) }

        let condition = awaited.count == 1
            ? "If \(last) accepts this key: "
            : "If \(awaited.dropLast().joined(separator: ", ")) and \(last) accept these keys: "
        return SetupPreview(plan: plan, sentence: condition + plan.explanation)
    }

    /// `setupPlan`, and the keys a Save would write with it: the field's text where there is any,
    /// the key on disk otherwise.
    static func setupDecision(
        fields: VendorKeys, states: KeyStates, configuration: SaathiConfiguration
    ) -> SetupDecision {
        var keys = VendorKeys()
        for kind in SetupPlan.vendors {
            keys[kind] = effectiveKey(field: fields[kind], stored: configuration.credential(for: kind))
        }
        return SetupDecision(
            plan: setupPlan(typed: typed(in: fields), states: states, configuration: configuration),
            keys: keys)
    }

    /// The provider the file names, for `SetupPlan` to stay on — nil when it names none, or names
    /// the hosted service with no token to use it with.
    static func providerInUse(_ configuration: SaathiConfiguration) -> ProviderKind? {
        guard let provider = configuration.provider else { return nil }
        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .hosted, token.isEmpty { return nil }
        return provider
    }

    /// The verdicts Setup opens with, read from what is on disk so a stored key counts before
    /// anything has been checked this launch.
    ///
    /// A vendor field seeds its own vendor and nothing else, and the legacy shared `apiKey` seeds
    /// only the vendor the config names as its provider: it is one key, and a config with a legacy
    /// key and no provider named says nothing about whose it is. That rule used to be written out
    /// here, because `credential(for:)` handed the shared key to every vendor and the panel would
    /// otherwise have shown it masked under all three. It is `credential(for:)`'s own rule now.
    static func seededKeyStates(for configuration: SaathiConfiguration) -> KeyStates {
        func seed(_ kind: ProviderKind) -> KeyFieldState {
            configuration.credential(for: kind).map { .saved(masked: IslandModel.masked($0)) } ?? .empty
        }
        return KeyStates(openAI: seed(.openai), sarvam: seed(.sarvam), anthropic: seed(.anthropic))
    }

    // MARK: where it could think

    /// The vendors with a key on disk, as Setup counts them: what `seededKeyStates` shows as saved.
    static func storedVendors(in configuration: SaathiConfiguration) -> Set<ProviderKind> {
        let seeded = seededKeyStates(for: configuration)
        return Set(SetupPlan.vendors.filter { seeded[$0].isValid })
    }

    /// What the picker under Voice offers: each vendor with a key, this Mac, the hosted service
    /// when there is a token for it — and whatever is in use now, so the picker can always show it.
    static func providerChoices(for configuration: SaathiConfiguration) -> [IslandProviderChoice] {
        let stored = storedVendors(in: configuration)
        var kinds = SetupPlan.vendors.filter(stored.contains) + [.local]
        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { kinds.append(.hosted) }
        if !kinds.contains(configuration.resolvedProvider) { kinds.append(configuration.resolvedProvider) }
        return kinds.map { IslandProviderChoice(kind: $0, title: vendorName($0)) }
    }

    /// Whether the switch for Sarvam's ears and mouth has anything to switch: a Sarvam key on
    /// disk, and a lane that reads `speech` at all.
    static func sarvamSpeechAvailable(for configuration: SaathiConfiguration) -> Bool {
        configuration.providerRow.voice == .chain && storedVendors(in: configuration).contains(.sarvam)
    }
}
