//
//  AppController+Setup.swift
//  SaathiShell
//
//  What the Setup tab does: saving the keys that were typed, and choosing where Saathi thinks,
//  whose ears it uses and which language it speaks.
//
//  These were closures inside `wireNotch`, written out once for OpenAI and once for Anthropic. A
//  third vendor would have made each a third longer. They are methods here, written once over
//  `SetupPlan.vendors`, and `wireNotch` points the island at them.
//
//  Nothing here decides anything. `setupPlan` — in the wording file, pure and tested — says what a
//  Save would do, and the sentence under the fields is drawn from the same call.
//

import AppKit
import SaathiContract
import SaathiKit

extension AppController {

    /// Points the island's Setup actions at the methods below.
    func wireSetup(into actions: inout IslandActions) {
        actions.onKeyFields = { [weak self] fields, edited in self?.keyFieldsChanged(fields, edited: edited) }
        actions.onSaveKeys = { [weak self] fields in self?.saveKeys(fields) }
        actions.onChooseProvider = { [weak self] kind in self?.chooseProvider(kind) }
        actions.onSarvamSpeech = { [weak self] on in self?.chooseSarvamSpeech(on) }
        actions.onLanguage = { [weak self] tag in self?.chooseLanguage(tag) }
    }

    /// The text in a field changed, or the Setup tab was built afresh with every field empty.
    ///
    /// Which fields have text is remembered — not the text — so that the sentence can be redrawn
    /// when something other than a field changes what a Save would do: the language, the picker,
    /// the switch. Each of those used to be able to redraw it as though every field were empty.
    private func keyFieldsChanged(_ fields: VendorKeys, edited: ProviderKind?) {
        guard let notch else { return }
        typedKeyFields = Self.typed(in: fields)
        var states = notch.model.keyStates
        // Typing invalidates an earlier verdict: a green tick next to a key that has since been
        // edited is the panel lying about what it checked.
        if let edited, typedKeyFields.contains(edited) { states[edited] = .editing }
        // A verdict about text that has gone goes with it — the island collapsing takes every
        // field's text — and the key on disk earns its own back.
        let seeded = Self.seededKeyStates(for: configuration)
        for kind in SetupPlan.vendors {
            states[kind] = Self.verdict(states[kind], isTyped: typedKeyFields.contains(kind), seeded: seeded[kind])
        }
        notch.model.keyStates = states
        refreshPlanExplanation()
    }

    /// Checks whatever was typed and saves it — and switches over — if every typed key was
    /// accepted.
    private func saveKeys(_ fields: VendorKeys) {
        guard let notch else { return }
        // Refused coherently rather than half-applied: without this a second Save during an
        // in-flight reconfigure could still write the file, flip the fields to `.saved` and
        // switch to Home, only to have the reconfigure it raced drop on the floor — leaving
        // disk naming one provider and the island showing another until relaunch.
        guard !voice.isReconfiguring else {
            voice.reportReconfiguring()
            return
        }
        typedKeyFields = Self.typed(in: fields)

        // A key typed but never checked is checked here, and saved only if the vendor accepts
        // it. Save used to stay disabled until Check had been pressed, and a disabled Save
        // looks like a Save that worked — the old key stayed on disk and the voice kept
        // failing with nothing on screen saying why.
        let unchecked = Self.keysNeedingCheck(fields: fields, states: notch.model.keyStates)
        if !unchecked.isEmpty {
            for kind in unchecked { notch.model.keyStates[kind] = .checking }
            Task {
                var allValid = true
                for kind in unchecked {
                    let result = await validator.check(kind, key: fields[kind])
                    if result != .valid { allValid = false }
                    notch.model.keyStates[kind] = .checked(result)
                }
                refreshPlanExplanation()
                // Every typed key now carries a verdict, so this second pass saves or, with a
                // rejection on show under its row, does nothing.
                if allValid { saveKeys(fields) }
            }
            return
        }

        // The same call the sentence under the fields is drawn from, with the same inputs, so
        // what was promised there is what is written here.
        let decision = Self.setupDecision(
            fields: fields, states: notch.model.keyStates, configuration: configuration)
        let updated = decision.plan.applied(to: configuration, keys: decision.keys)
        guard write(updated, orSay: "could not save your keys") else { return }

        // Saved keys come back only as their last four characters; the full key is never put
        // back into a field. Masked from the effective key, not the field, so a retained
        // stored key still shows its real suffix instead of the empty field's generic mask.
        for kind in decision.plan.stored {
            notch.model.keyStates[kind] = .saved(masked: IslandModel.masked(decision.keys[kind]))
        }
        // Going to Home takes the Setup view, and the text in its fields, out of the tree.
        typedKeyFields = []
        notch.model.tab = .home

        Task { await reconfigure(updated) }
    }

    /// The picker under Voice: think somewhere else, with the keys that are already here.
    private func chooseProvider(_ kind: ProviderKind) {
        guard kind != configuration.resolvedProvider, canChangeSetup() else { return }

        let plan = SetupPlan.choosing(kind, valid: Self.storedVendors(in: configuration))
        // The keys as they stand, so a legacy shared key is filed under the vendor it belongs to
        // before the provider that said whose it was changes.
        var keys = VendorKeys()
        for vendor in plan.stored { keys[vendor] = configuration.credential(for: vendor) ?? "" }
        let updated = plan.applied(to: configuration, keys: keys)
        guard write(updated, orSay: "could not save that choice") else { return }

        // Shown at once rather than when the new session is up, so the picker does not sit on the
        // old answer for a second and then jump.
        notch?.model.provider = kind
        Task { await reconfigure(updated) }
    }

    /// The switch under Voice: Sarvam's ears and mouth, or this Mac's.
    private func chooseSarvamSpeech(_ on: Bool) {
        guard on != SarvamSpeech.isOn(configuration), canChangeSetup() else { return }
        var updated = configuration
        updated.speech = on ? .sarvam : nil
        guard write(updated, orSay: "could not save that choice") else { return }
        notch?.model.sarvamSpeechOn = on
        Task { await reconfigure(updated) }
    }

    /// The language Saathi answers in — and, with Sarvam's speech, the one it listens and speaks in.
    private func chooseLanguage(_ tag: String) {
        guard canChangeSetup() else { return }
        var updated = configuration
        updated.language = tag.isEmpty ? nil : tag
        guard write(updated, orSay: "could not save the language") else { return }
        notch?.model.language = tag
        // The language is baked into the session's instructions — and into Sarvam's ears — so it
        // only takes effect on a fresh session: the same reconfigure a saved key goes through.
        Task { await reconfigure(updated) }
    }

    /// False, and said out loud, while a reconfigure is under way. The model is left alone, so a
    /// picker or a switch goes back to what is true rather than showing a choice that was not made.
    private func canChangeSetup() -> Bool {
        guard voice.isReconfiguring else { return true }
        voice.reportReconfiguring()
        return false
    }

    /// The plan changes as each check lands, so the sentence under the fields follows it rather
    /// than appearing only after a save. Someone should be able to see what they are about to get.
    ///
    /// Drawn from `typedKeyFields` — which fields have text right now — the verdicts, and the
    /// file: the three things Save decides from.
    func refreshPlanExplanation() {
        guard let notch else { return }
        let plan = Self.setupPlan(
            typed: typedKeyFields, states: notch.model.keyStates, configuration: configuration)
        notch.model.planExplanation = plan.explanation
        notch.model.keysNote = Self.keysNote(for: plan, language: configuration.resolvedLanguage)
    }

    private func write(_ updated: SaathiConfiguration, orSay failure: String) -> Bool {
        do {
            try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            return true
        } catch {
            handle(.failure("\(failure): \(error.localizedDescription)"))
            return false
        }
    }
}
