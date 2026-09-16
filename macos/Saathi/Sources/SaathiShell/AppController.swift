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
            Task {
                do {
                    try await session.start(callbacks: callbacks)
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

        if let turns, turns.isOpen {
            _ = turns.close()
            handle(.keysReleased)
            // One beat for the turn to finish landing. Longer than this and a person notices;
            // shorter and the close races the teardown it exists to prevent.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

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
                    if turns.open() { self.handle(.keysHeld) }
                case .ended:
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
                        if self.monitor != nil || remaining <= 0 { timer.invalidate(); self.permissionPoll = nil }
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
        if notch.model.tab == .setup {
            notch.model.planExplanation =
                SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false).explanation
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
        actions.onCheckKey = { [weak self] kind, key in
            guard let self, let notch = self.notch else { return }
            switch kind {
            case .openai: notch.model.openAIKeyState = .checking
            case .anthropic: notch.model.anthropicKeyState = .checking
            default: return
            }
            Task {
                let result = await self.validator.check(kind, key: key)
                await MainActor.run {
                    switch kind {
                    case .openai: notch.model.openAIKeyState = .checked(result)
                    case .anthropic: notch.model.anthropicKeyState = .checked(result)
                    default: break
                    }
                    self.refreshPlanExplanation()
                }
            }
        }

        actions.onSaveKeys = { [weak self] openAIKey, anthropicKey in
            guard let self, let notch = self.notch else { return }
            let plan = SetupPlan.make(
                openAIKeyValid: notch.model.openAIKeyState.isValid,
                anthropicKeyValid: notch.model.anthropicKeyState.isValid)
            let updated = plan.applied(
                to: self.configuration, openAIKey: openAIKey, anthropicKey: anthropicKey)

            do {
                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            } catch {
                self.handle(.failure("could not save your keys: \(error.localizedDescription)"))
                return
            }

            // Saved keys come back only as their last four characters; the full key is never put
            // back into a field.
            if plan.provider == .openai || plan.storedButUnused.contains(.openai) {
                notch.model.openAIKeyState = .saved(masked: IslandModel.masked(openAIKey))
            }
            if plan.provider == .anthropic || plan.storedButUnused.contains(.anthropic) {
                notch.model.anthropicKeyState = .saved(masked: IslandModel.masked(anthropicKey))
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
    private func refreshPlanExplanation() {
        guard let notch else { return }
        let plan = SetupPlan.make(
            openAIKeyValid: notch.model.openAIKeyState.isValid,
            anthropicKeyValid: notch.model.anthropicKeyState.isValid)
        notch.model.planExplanation = plan.explanation
        notch.model.unusedKeyNote = Self.unusedKeyNote(for: plan)
    }
}
