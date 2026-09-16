//
//  AppController.swift
//  SaathiShell
//
//  Wires the pieces: configuration, the voice session and its callbacks, the state machine, the
//  hold-to-talk monitor, the two panels and the menu. Everything that touches a view happens on
//  the main actor; session callbacks arrive on other threads and are hopped over.
//

import AppKit
import SaathiContract
import SaathiKit
import SaathiMascot
import ServiceManagement

@MainActor
public final class AppController {

    private var configuration: SaathiConfiguration
    private let data: MascotData
    private let color: MascotColor
    private let validator = KeyValidator()
    /// Set while a reconfigure is waiting for an open turn to finish, so a second Save does not
    /// start a second teardown alongside the first.
    private var reconfiguring = false

    private var machine: CompanionStateMachine
    private var shown: CompanionState = .idle

    private let companion: CompanionPanel
    private let notch: NotchPanel?
    private let menu: MenuBarController

    private var speaker: ObservedSpeaker!
    private var performer: ActionPerformer!
    private var session: (any VoiceSession)?
    private var turns: TurnCoordinator!
    /// The in-flight `session.start(callbacks:)` call, held so a reconfigure can cancel it before
    /// stopping the session it belongs to — otherwise a start still resolving a connection can
    /// resume and open a socket after the replacement session already exists.
    private var startTask: Task<Void, Never>?
    private var monitor: HoldToTalkMonitor?
    private var ticker: Timer?
    private var ticks = 0
    private var permissionPoll: Timer?
    private var screenObserver: NSObjectProtocol?
    /// Why there is no voice session, kept so a press can say so instead of doing nothing.
    private var voiceStartFailure: String?

    public init() throws {
        configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
        data = try MascotData.load()
        color = MascotColor(paletteName: "blue", in: data) ?? MascotColor(hex: "#377FE6")
        machine = CompanionStateMachine(now: CACurrentMediaTime())
        companion = CompanionPanel()
        if let screen = NSScreen.main {
            notch = NotchPanel(data: data, color: color, screen: screen)
        } else {
            notch = nil
        }
        menu = MenuBarController(icon: MenuBarIcon.image(data: data), installStatusItem: true)

        speaker = ObservedSpeaker(SystemSpeaker()) { [weak self] speaking in
            Task { @MainActor in self?.handle(.speakingChanged(speaking)) }
        }
        performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())
        wireMenu()
        wireNotch()
    }

    public func start() {
        notch?.show()
        companion.show()
        menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        render(force: true)
        startTicking()
        startVoice()
        startHoldToTalkIfPossible()
        refreshPermissions()
        observeScreenChanges()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// A display arriving or leaving, a resolution change, a menu bar that starts hiding itself:
    /// all of them move the notch the island hangs in, and none of them move the pointer, so the
    /// poll that follows the pointer between displays would not notice. Lay the island out again
    /// on the screen that is now the main one.
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
                self.notch?.moveTo(screen: screen)
            }
        }
    }

    // MARK: events

    private func handle(_ event: CompanionEvent) {
        machine.apply(event, now: CACurrentMediaTime())
        render()
    }

    private func render(force: Bool = false) {
        let state = machine.state
        guard force || state != shown else { return }
        shown = state
        companion.setState(state)
        notch?.setState(state)
        menu.setState(state)
    }

    private func startTicking() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.machine.tick(now: CACurrentMediaTime())
                self.render()
                // A permission is granted over in System Settings, which tells the app nothing.
                // Every twentieth tick — five seconds — the menu item catches up by itself, so
                // it stops claiming something is missing long after it was granted.
                self.ticks += 1
                if self.ticks % 20 == 0 { self.refreshPermissions() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: voice

    private func startVoice() { startVoice(with: configuration) }

    private func startVoice(with configuration: SaathiConfiguration) {
        voiceStartFailure = nil
        do {
            let session = try VoiceSessionFactory.make(configuration: configuration, speaker: speaker)
            self.session = session
            turns = TurnCoordinator(
                begin: { try await session.beginTurn() },
                end: { try await session.endTurn() },
                onFailure: { [weak self] message in self?.handle(.failure(message)) })
            let callbacks = VoiceSessionCallbacks(
                onUserTranscript: { [weak self] text in Task { @MainActor in self?.handle(.userSpoke(text)) } },
                onSaathiTranscript: { [weak self] text in Task { @MainActor in self?.handle(.saathiSpoke(text)) } },
                onAction: { [weak self] action in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handle(.action(action))
                        Task {
                            do {
                                try await self.performer.perform(action)
                            } catch {
                                await MainActor.run { self.handle(.failure(error.localizedDescription)) }
                            }
                        }
                    }
                },
                onStatus: { [weak self] status in Task { @MainActor in self?.handle(.status(status)) } }
            )
            // Cancelling any previous start before racing a fresh one in keeps at most one
            // start in flight for this controller — see `startTask`'s doc comment.
            startTask?.cancel()
            startTask = Task {
                do {
                    try await session.start(callbacks: callbacks)
                } catch is CancellationError {
                    // Superseded by a reconfigure; the session this call belonged to is already
                    // gone, so there is nothing left to report.
                } catch let error as URLError where error.code == .cancelled {
                    // URLSession reports a cancelled task this way, not as `CancellationError` — the
                    // same supersede-by-reconfigure case as above, just surfaced by the transport
                    // instead of the task tree. (The own-key branch of `resolveConnection()` has no
                    // real suspension point, so this arm is dead there — harmless, since the worst
                    // case is an extra banner, never a swallowed failure.)
                } catch {
                    await MainActor.run { self.handle(.failure(error.localizedDescription)) }
                }
            }
        } catch {
            voiceStartFailure = error.localizedDescription
            handle(.failure(error.localizedDescription))
        }
    }

    /// There is no session, so there is nothing to talk to. Say why rather than swallow the press:
    /// a dead session that answers nothing reads as a broken key.
    private func reportNoVoice() {
        handle(.failure(voiceStartFailure ?? "voice is not available"))
    }

    /// A turn cannot open or close on a coordinator that a reconfigure is in the middle of tearing
    /// down — opening one there is the same "two things holding the microphone" hazard the teardown
    /// ordering exists to prevent, entered from the input side instead of the session side. Say so
    /// rather than swallow the press: it is brief, but real.
    private func reportReconfiguring() {
        handle(.failure("switching over — try again in a moment"))
    }

    /// Swaps in a new configuration without a relaunch.
    ///
    /// The order is not negotiable. A turn is closed before anything is torn down — `TurnCoordinator`
    /// exists because a turn that never opened must not be ended, and ripping a session out from
    /// under an open turn is the same bug approached from the other side. The old socket is closed
    /// before a new one opens, so two realtime sessions never hold the microphone at once.
    private func reconfigure(_ updated: SaathiConfiguration) async {
        guard !reconfiguring else { return }
        reconfiguring = true
        defer { reconfiguring = false }

        if let turns {
            if turns.isOpen {
                _ = turns.close()
                handle(.keysReleased)
            }
            // Drain whatever end call is queued, whether or not a turn is open right now.
            // `close()` marks `isOpen` false synchronously, but the end call it queues can still be
            // running long after that flips — and gating this wait behind `isOpen` skipped it in
            // exactly the ordinary case that matters: keys are usually already released by the time
            // someone opens Setup and hits Save, so `isOpen` already reads false while `endTurn()`
            // is still finishing underneath. Waiting unconditionally is free when nothing is
            // queued — `work` is never nilled, so awaiting a finished task returns immediately.
            await turns.settle()
        }

        // The old session's start may still be resolving a connection or opening a socket; cancel
        // it before stopping the session, or it can resume afterwards and open a second live
        // socket after the new session already exists — the same hazard this ordering exists to
        // prevent, entered from the start side instead of the stop side.
        startTask?.cancel()
        speaker.stop()
        await session?.stop()
        session = nil
        turns = nil

        configuration = updated
        startVoice(with: updated)
        applyConfigurationToIsland()
    }

    /// Re-fills everything the island says about where Saathi thinks. Called at startup and after
    /// every reconfigure, so the Home tab can never describe a provider that is no longer in use.
    private func applyConfigurationToIsland() {
        guard let notch else { return }
        notch.model.providerTitle = Self.providerTitle(for: configuration)
        notch.model.privacyLine = Self.privacyLine(for: configuration)
    }

    // MARK: what the island says about a configuration
    //
    // Static and pure so the wording can be tested without a window, a session or a key. These are
    // the sentences that tell someone where their voice goes, which makes them worth pinning down.

    static func providerTitle(for configuration: SaathiConfiguration) -> String {
        "\(configuration.resolvedProvider.rawValue) · \(configuration.resolvedModel)"
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

    // MARK: hold to talk

    /// A no-op when a monitor is already installed or Input Monitoring is not yet granted. Called
    /// from `start()`, from the Talk item (a granted-while-running permission takes effect there
    /// too), and from the Fix permissions poll below — so the tap is retried wherever the grant
    /// might land, with no relaunch needed.
    private func startHoldToTalkIfPossible() {
        guard monitor == nil, HoldToTalkMonitor.isPermitted() else { return }
        let monitor = HoldToTalkMonitor { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let turns = self.turns else {
                    if case .began = event { self.reportNoVoice() }
                    return
                }
                switch event {
                case .began:
                    if self.reconfiguring {
                        self.reportReconfiguring()
                        return
                    }
                    if turns.open() { self.handle(.keysHeld) }
                case .ended:
                    // Unguarded on purpose: `reconfigure` closes any open turn itself,
                    // synchronously, before its first await, so by the time `reconfiguring` is
                    // observably true here `turns.isOpen` already reads false and this is a no-op.
                    // `open()` has exactly one other call site (`menu.onTalk`, guarded above) — if
                    // a future await ever lands above that `close()`, this comment is the tripwire.
                    if turns.close() { self.handle(.keysReleased) }
                }
            }
        }
        do {
            try monitor.start()
            self.monitor = monitor
            refreshPermissions()
        } catch {
            self.monitor = nil
        }
    }

    private func refreshPermissions() {
        let statuses = Permission.allCases.map { ($0, Permissions.status(of: $0)) }
        notch?.model.permissions = Dictionary(uniqueKeysWithValues: statuses)
        menu.setPermissionsNeeded(statuses.filter { $0.1 != .granted }.map { $0.0.title })
    }

    /// Shows or hides the pointer companion and keeps the menu's checkbox and the island's toggle
    /// wording in step with it, whichever of the three asked for the change.
    private func setCompanionVisible(_ visible: Bool) {
        if visible { companion.show() } else { companion.hide() }
        menu.setCompanionVisible(visible)
        notch?.model.companionVisible = visible
    }

    // MARK: menu

    private func wireMenu() {
        menu.onTalk = { [weak self] in
            guard let self else { return }
            self.startHoldToTalkIfPossible()   // a granted-while-running permission takes effect here too
            if self.reconfiguring {
                self.reportReconfiguring()
                return
            }
            guard let turns = self.turns else {
                self.reportNoVoice()
                return
            }
            if turns.isOpen {
                turns.close(); self.handle(.keysReleased)
            } else {
                turns.open(); self.handle(.keysHeld)
            }
        }
        menu.onToggleCompanion = { [weak self] visible in self?.setCompanionVisible(visible) }
        menu.onToggleStartAtLogin = { [weak self] enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self?.handle(.failure("start at login: \(error.localizedDescription)"))
            }
            self?.menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        }
        menu.onProvider = { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Where Saathi thinks"
            alert.informativeText = ProviderReport.describe(self.configuration) + "\n\n" + VoiceLaneReport.describe(self.configuration)
            alert.runModal()
        }
        menu.onFixPermissions = { [weak self] in
            guard let self else { return }
            if Permissions.status(of: .inputMonitoring) != .granted, self.monitor == nil {
                _ = HoldToTalkMonitor.requestPermission()
                NSWorkspace.shared.open(Permission.inputMonitoring.settingsURL)
                // The poll below and the Talk item both retry installing the tap, so the grant
                // takes effect without a relaunch.
                self.permissionPoll?.invalidate()
                self.startHoldToTalkIfPossible()   // it may already have been granted
                var remaining = 120
                // A common-mode timer: a scheduled one stops firing while a menu is tracking,
                // which is exactly when this poll is asked for.
                let poll = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                    Task { @MainActor in
                        guard let self else { timer.invalidate(); return }
                        remaining -= 1
                        self.startHoldToTalkIfPossible()
                        if self.monitor != nil {
                            timer.invalidate()
                            self.permissionPoll = nil
                            self.notch?.model.needsRestart = false
                        } else if remaining <= 0 {
                            timer.invalidate()
                            self.permissionPoll = nil
                            // Two minutes of retrying and the tap still will not install. Either the
                            // grant never happened, or macOS is not going to hand it to this process
                            // without a fresh start. Offer the restart rather than saying nothing.
                            self.notch?.model.needsRestart = Permissions.status(of: .inputMonitoring) == .granted
                        }
                    }
                }
                RunLoop.main.add(poll, forMode: .common)
                self.permissionPoll = poll
            } else if let first = Permission.allCases.first(where: { Permissions.status(of: $0) != .granted }) {
                NSWorkspace.shared.open(first.settingsURL)
            }
            self.refreshPermissions()
        }
        menu.onQuit = { [weak self] in
            guard let self else { return }
            self.handle(.quit)
            self.speaker.stop()   // whatever it was saying does not outlive the goodbye
            self.startTask?.cancel()   // an in-flight start must not open a socket during power-down
            Task {
                await self.session?.stop()
                try? await Task.sleep(nanoseconds: 1_400_000_000)   // let powering-down settle
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: notch

    /// The island's Home panel says the same things the menu does, through the same code: Talk,
    /// Provider and Quit are literally the menu's own closures, so there is one Talk, one Quit and
    /// one place that opens the provider alert.
    private func wireNotch() {
        guard let notch else { return }
        applyConfigurationToIsland()
        notch.model.companionVisible = true
        notch.model.tab = Self.openingTab(for: configuration)
        notch.model.language = configuration.language ?? ""
        // Seed both verdicts from what is already on disk — otherwise every launch shows `.empty`
        // regardless of what is stored, and the `isValid && !effectiveKey.isEmpty` gate never sees
        // a stored key as valid. Only for a vendor the config actually names; see `seededKeyStates`.
        let seeded = Self.seededKeyStates(for: configuration)
        notch.model.openAIKeyState = seeded.openAI
        notch.model.anthropicKeyState = seeded.anthropic
        if notch.model.tab == .setup {
            refreshPlanExplanation()
        }

        var actions = IslandActions()
        actions.onTalk = menu.onTalk
        actions.onProvider = menu.onProvider
        actions.onFixPermission = { [weak self] permission in
            guard let self else { return }
            Task {
                _ = await Permissions.request(permission)
                await MainActor.run {
                    self.startHoldToTalkIfPossible()   // a grant just made takes effect here too
                    self.refreshPermissions()
                    if Permissions.status(of: permission) != .granted {
                        NSWorkspace.shared.open(permission.settingsURL)
                    }
                }
            }
        }
        actions.onToggleCompanion = { [weak self] in
            guard let self, let notch = self.notch else { return }
            self.setCompanionVisible(!notch.model.companionVisible)
        }
        actions.onQuit = menu.onQuit
        actions.onRestart = {
            // `IslandActions.onRestart` is typed `() -> Void`, a non-actor-qualified closure type,
            // so this literal is nonisolated and `Task {}` is a cross-actor hop — safe only because
            // `AppRelauncher.relaunch` is itself `@MainActor`.
            Task { await AppRelauncher.relaunch(bundleURL: Bundle.main.bundleURL) }
        }
        // Both fields arrive, not just the one being checked: the verdict that lands changes the
        // plan, and the plan is decided by both keys at once. See `setupDecision`.
        actions.onCheckKey = { [weak self] kind, openAIField, anthropicField in
            guard let self, let notch = self.notch else { return }
            let key: String
            switch kind {
            case .openai:
                key = openAIField
                notch.model.openAIKeyState = .checking
            case .anthropic:
                key = anthropicField
                notch.model.anthropicKeyState = .checking
            default: return
            }
            Task {
                let result = await self.validator.check(kind, key: key)
                await MainActor.run {
                    switch kind {
                    case .openai: notch.model.openAIKeyState = .checked(result)
                    case .anthropic: notch.model.anthropicKeyState = .checked(result)
                    default: return
                    }
                    self.refreshPlanExplanation(
                        openAIField: openAIField, anthropicField: anthropicField)
                }
            }
        }

        actions.onLanguage = { [weak self] tag in
            guard let self, let notch = self.notch else { return }
            notch.model.language = tag
            var updated = self.configuration
            updated.language = tag.isEmpty ? nil : tag
            do {
                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            } catch {
                self.handle(.failure("could not save the language: \(error.localizedDescription)"))
                return
            }
            // The language is baked into the session's instructions, so it only takes effect on a
            // fresh session — the same reconfigure a saved key goes through.
            Task { await self.reconfigure(updated) }
        }

        actions.onSaveKeys = { [weak self] openAIKey, anthropicKey in
            guard let self, let notch = self.notch else { return }
            // Refused coherently rather than half-applied: without this a second Save during an
            // in-flight reconfigure could still write the file, flip the fields to `.saved` and
            // switch to Home, only to have the reconfigure it raced drop on the floor — leaving
            // disk naming one provider and the island showing another until relaunch.
            guard !self.reconfiguring else {
                self.reportReconfiguring()
                return
            }

            // The same call the sentence under the fields is drawn from, with the same inputs, so
            // what was promised there is what is written here.
            let decision = Self.setupDecision(
                openAIField: openAIKey,
                anthropicField: anthropicKey,
                openAIState: notch.model.openAIKeyState,
                anthropicState: notch.model.anthropicKeyState,
                configuration: self.configuration)
            let plan = decision.plan
            let updated = plan.applied(
                to: self.configuration,
                openAIKey: decision.openAIKey,
                anthropicKey: decision.anthropicKey)

            do {
                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            } catch {
                self.handle(.failure("could not save your keys: \(error.localizedDescription)"))
                return
            }

            // Saved keys come back only as their last four characters; the full key is never put
            // back into a field. Masked from the effective key, not the field, so a retained
            // stored key still shows its real suffix instead of the empty field's generic mask.
            if plan.provider == .openai || plan.storedButUnused.contains(.openai) {
                notch.model.openAIKeyState = .saved(masked: IslandModel.masked(decision.openAIKey))
            }
            if plan.provider == .anthropic || plan.storedButUnused.contains(.anthropic) {
                notch.model.anthropicKeyState = .saved(masked: IslandModel.masked(decision.anthropicKey))
            }
            notch.model.planExplanation = plan.explanation
            notch.model.unusedKeyNote = Self.unusedKeyNote(for: plan)
            notch.model.tab = .home

            Task { await self.reconfigure(updated) }
        }

        notch.actions = actions
    }

    /// The plan changes as each check lands, so the sentence under the fields follows it rather than
    /// appearing only after a save. Someone should be able to see what they are about to get.
    ///
    /// `openAIField`/`anthropicField` are the live text of *both* fields, as the panel holds them
    /// right now — not just the one that changed. Empty means the field really is empty, and then
    /// the key on disk stands in. Both default to empty for the one call that has no panel behind it
    /// yet: the seed from `wireNotch`, before the Setup view has been built.
    private func refreshPlanExplanation(openAIField: String = "", anthropicField: String = "") {
        guard let notch else { return }
        let decision = Self.setupDecision(
            openAIField: openAIField,
            anthropicField: anthropicField,
            openAIState: notch.model.openAIKeyState,
            anthropicState: notch.model.anthropicKeyState,
            configuration: configuration)
        notch.model.planExplanation = decision.plan.explanation
        notch.model.unusedKeyNote = Self.unusedKeyNote(for: decision.plan)
    }
}
