//
//  AppController+Wording.swift
//  SaathiShell
//
//  What the island and the log say about a configuration, an action or a pair of key fields.
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
        return row.sendsDataOffMachine ? "only the transcript is sent" : "stays on this machine"
    }

    /// Says out loud that a key was saved and is not being used. Empty when there is nothing to
    /// confess — a panel that quietly banks an Anthropic key lets someone believe Claude is
    /// answering them.
    static func unusedKeyNote(for plan: SetupPlan) -> String {
        guard !plan.storedButUnused.isEmpty else { return "" }
        let names = plan.storedButUnused.map { $0.rawValue.capitalized }.joined(separator: " and ")
        return "\(names) key saved. Nothing uses it yet."
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

    /// Whether a key counts as usable for `SetupPlan`: a verdict that says so, *and* an effective
    /// key actually behind it. A `.saved` or `.checked(.valid)` verdict with no effective key
    /// (nothing on disk, an empty field) must not count.
    static func isUsable(_ state: KeyFieldState, effectiveKey: String) -> Bool {
        state.isValid && !effectiveKey.isEmpty
    }

    /// What a Save would do: the plan, and the two keys it would be applied with.
    struct SetupDecision: Equatable {
        let plan: SetupPlan
        let openAIKey: String
        let anthropicKey: String
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
    /// fields, streamed audio to OpenAI. So both callers pass *both* live field values through here
    /// and read the same answer. The stored fallback is `credential(for:)`, not the vendor field, so
    /// a legacy shared `apiKey` counts here exactly as it counts everywhere else that asks for a
    /// key; reading the vendor fields directly made Save see no key at all on a legacy config and
    /// demote a working install to `.local`.
    static func setupDecision(
        openAIField: String,
        anthropicField: String,
        openAIState: KeyFieldState,
        anthropicState: KeyFieldState,
        configuration: SaathiConfiguration
    ) -> SetupDecision {
        let openAI = effectiveKey(field: openAIField, stored: configuration.credential(for: .openai))
        let anthropic = effectiveKey(
            field: anthropicField, stored: configuration.credential(for: .anthropic))
        return SetupDecision(
            plan: SetupPlan.make(
                openAIKeyValid: isUsable(openAIState, effectiveKey: openAI),
                anthropicKeyValid: isUsable(anthropicState, effectiveKey: anthropic)),
            openAIKey: openAI,
            anthropicKey: anthropic)
    }

    /// The verdicts Setup opens with, read from what is on disk so a stored key counts before
    /// anything has been checked this launch.
    ///
    /// A vendor field seeds its own vendor and nothing else. The legacy shared `apiKey` seeds only
    /// the vendor the config actually names as its provider: it is one key that could belong to
    /// either vendor, and `credential(for:)` hands it to both, so seeding both would have the panel
    /// assert an Anthropic key exists on a config that never mentioned Anthropic — showing that key
    /// masked under Anthropic, and lighting up Save with two empty fields. A config with a legacy
    /// key and no provider named says nothing about whose key it is, so it seeds neither.
    static func seededKeyStates(
        for configuration: SaathiConfiguration
    ) -> (openAI: KeyFieldState, anthropic: KeyFieldState) {
        func seed(_ kind: ProviderKind, vendorKey: String?) -> KeyFieldState {
            let vendor = vendorKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !vendor.isEmpty { return .saved(masked: IslandModel.masked(vendor)) }
            guard configuration.provider == kind,
                  let legacy = configuration.credential(for: kind) else { return .empty }
            return .saved(masked: IslandModel.masked(legacy))
        }
        return (
            openAI: seed(.openai, vendorKey: configuration.openaiKey),
            anthropic: seed(.anthropic, vendorKey: configuration.anthropicKey))
    }
}
