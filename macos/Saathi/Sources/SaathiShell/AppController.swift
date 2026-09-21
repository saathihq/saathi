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

    var configuration: SaathiConfiguration
    let data: MascotData
    private let color: MascotColor
    private let validator = KeyValidator()
    private var machine: CompanionStateMachine
    private var shown: CompanionState = .idle

    private let companion: CompanionPanel
    let notch: NotchPanel?
    let menu: MenuBarController

    /// The voice underneath `speaker`, kept so its language and pace can follow the configuration.
    private let systemSpeaker: SystemSpeaker
    var speaker: ObservedSpeaker!
    private var performer: ActionPerformer!
    /// The voice session's whole life — start, turns, reconfigure, quit. See `VoiceConductor`.
    var voice: VoiceConductor!
    private var monitor: HoldToTalkMonitor?
    /// What was said, kept: `~/.saathi/conversation.log`.
    private let conversation: ConversationLog
    private var ticker: Timer?
    private var ticks = 0
    private var permissionPoll: Timer?
    private var screenObserver: NSObjectProtocol?

    /// First run, while it is showing. See `AppController+Onboarding.swift`.
    var onboarding: OnboardingCoordinator?
    var onboardingWindow: OnboardingWindowController?
    /// During first run the voice session only listens — the mic check and the four questions
    /// must work before any model has been chosen — except for the trial chat, which is real.
    var listensOnly = false

    public init() throws {
        configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
        conversation = ConversationLog(url: ConversationLog.defaultURL(beside: ConfigurationStore.defaultPath()))
        data = try MascotData.load()
        color = MascotColor(paletteName: configuration.colour ?? OnboardingModel.defaultColour, in: data)
            ?? MascotColor(hex: "#377FE6")
        machine = CompanionStateMachine(now: CACurrentMediaTime())
        companion = CompanionPanel()
        if let screen = NSScreen.main {
            notch = NotchPanel(data: data, color: color, screen: screen)
        } else {
            notch = nil
        }
        menu = MenuBarController(icon: MenuBarIcon.image(data: data), installStatusItem: true)

        systemSpeaker = SystemSpeaker(settings: SpeechSettings(configuration))
        speaker = ObservedSpeaker(systemSpeaker) { [weak self] speaking in
            Task { @MainActor in self?.handle(.speakingChanged(speaking)) }
        }
        performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())
        let speaker = self.speaker!
        let performer = self.performer!
        voice = VoiceConductor(
            makeSession: { [weak self] configuration in
                if self?.listensOnly == true {
                    return ChainVoiceSession(configuration: configuration, speaker: speaker, thinks: false)
                }
                return try VoiceSessionFactory.make(configuration: configuration, speaker: speaker)
            },
            perform: { try await performer.perform($0) },
            stopSpeaking: { speaker.stop() },
            onEvent: { [weak self] in self?.handle($0) },
            onScreenLook: { [weak self] question, answer in
                self?.conversation.append(.look(question: question, answer: answer))
            },
            // Only first run draws these; the rest of the app has the face for that.
            onListening: { [weak self] level, partial in self?.onboarding?.listening(level: level, partial: partial) })
        wireMenu()
        wireNotch()
    }

    public func start() {
        notch?.show()
        companion.show()
        menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        render(force: true)
        startTicking()
        if Self.shouldOnboard(configuration) {
            // No voice session yet: starting one asks macOS for speech recognition, and first run
            // asks for that itself, one permission at a time, with the reason said first.
            beginOnboarding(isFirstRun: true)
        } else {
            voice.start(with: configuration)
        }
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

    func handle(_ event: CompanionEvent) {
        // First run listens through the same session and the same keys as everything else.
        if let onboarding {
            switch event {
            case let .userSpoke(text): onboarding.heard(text)
            case .keysHeld: onboarding.keysHeld()
            case let .status(text) where text.lowercased().hasPrefix("did not catch"): onboarding.heardNothing()
            default: break
            }
        }
        record(event)
        machine.apply(event, now: CACurrentMediaTime())
        render()
    }

    /// Everything worth keeping passes through `handle`, so this is the one place the log is
    /// written from — both lanes, the menu's Talk and the keys alike.
    private func record(_ event: CompanionEvent) {
        switch event {
        case let .userSpoke(text):
            conversation.append(.you(text))
            notch?.model.lastYouSaid = text
        case let .saathiSpoke(text):
            conversation.append(.saathi(text))
            notch?.model.lastSaathiSaid = text
        case let .action(action):
            conversation.append(.action(Self.describe(action)))
        case let .failure(message):
            conversation.append(.error(message))
        case .keysHeld, .keysReleased, .status, .speakingChanged, .quit:
            break
        }
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

    /// `scripted` is first run: its lines are written in English, so they are read by an English
    /// voice whatever language was just chosen — a Tamil synthesiser reading English sentences is
    /// the same noise as the reverse. The pace still follows at once.
    func applySpeechSettings(scripted: Bool = false) {
        systemSpeaker.apply(Self.speechSettings(for: configuration, scripted: scripted))
    }

    static func speechSettings(for configuration: SaathiConfiguration, scripted: Bool) -> SpeechSettings {
        var settings = SpeechSettings(configuration)
        if scripted { settings.language = "en" }
        return settings
    }

    // MARK: voice

    /// Swaps in a new configuration without a relaunch. The teardown order lives in
    /// `VoiceConductor.reconfigure`; a second Save while one is under way does nothing at all.
    func reconfigure(_ updated: SaathiConfiguration) async {
        guard await voice.reconfigure(to: updated) else { return }
        configuration = updated
        systemSpeaker.apply(SpeechSettings(updated))
        applyConfigurationToIsland()
    }

    /// Re-fills everything the island says about where Saathi thinks. Called at startup and after
    /// every reconfigure, so the Home tab can never describe a provider that is no longer in use.
    func applyConfigurationToIsland() {
        guard let notch else { return }
        notch.model.providerTitle = Self.providerTitle(for: configuration)
        notch.model.privacyLine = Self.privacyLine(for: configuration)
        notch.model.voiceTitle = configuration.resolvedVoice.isEmpty ? "—" : configuration.resolvedVoice
        notch.model.laneTitle = configuration.providerRow.voice == .realtime
            ? "one connection"
            : "three steps"

        // The status pill in the menu-bar band, and the Backend rows on Setup. Two different
        // questions: the pill says where Saathi is connected on the lane in use, the rows say
        // whether the hosted backend is set up — which off the hosted lane it need not be.
        let pill = Self.connectionPill(for: configuration)
        notch.model.connectionTitle = pill.title
        notch.model.isConnectionConfigured = pill.isConfigured
        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        notch.model.usesBackend = configuration.providerRow.requiresToken
        notch.model.isBackendConfigured = !token.isEmpty
        notch.model.backendTitle = Self.backendTitle(for: configuration)

        // Neither integration exists in Saathi yet, so both draw in their real "not configured"
        // state. They are a list rather than two hand-written tiles so that wiring one up later is
        // a line here, not a change to the panel.
        notch.model.integrations = IslandIntegration.all

        // One store for the life of the app: it watches `~/.saathi/skills` with a dispatch source,
        // and rebuilding it on every reconfigure would leak a watcher per provider change.
        if notch.model.skills == nil {
            let launched = configuration
            notch.model.skills = SkillLibraryStore(configuration: { [weak self] in self?.configuration ?? launched })
        }
    }

    // MARK: hold to talk

    /// A no-op when a monitor is already installed or Input Monitoring is not yet granted. Called
    /// from `start()`, from the Talk item (a granted-while-running permission takes effect there
    /// too), and from the Fix permissions poll below — so the tap is retried wherever the grant
    /// might land, with no relaunch needed.
    func startHoldToTalkIfPossible() {
        guard monitor == nil, HoldToTalkMonitor.isPermitted() else { return }
        let monitor = HoldToTalkMonitor { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .began: self.voice.keysBegan()
                case .ended: self.voice.keysEnded()
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

    func refreshPermissions() {
        let statuses = Permission.allCases.map { ($0, Permissions.status(of: $0)) }
        notch?.model.permissions = Dictionary(uniqueKeysWithValues: statuses)
        menu.setPermissionsNeeded(statuses.filter { $0.0.isRequired && $0.1 != .granted }.map { $0.0.title })
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
            self.voice.toggleTalk()
        }
        menu.onRunOnboarding = { [weak self] in self?.beginOnboarding(isFirstRun: false) }
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
            } else if let first = Permission.allCases.first(where: { $0.isRequired && Permissions.status(of: $0) != .granted }) {
                NSWorkspace.shared.open(first.settingsURL)
            }
            self.refreshPermissions()
        }
        menu.onQuit = { [weak self] in
            guard let self else { return }
            self.handle(.quit)
            Task {
                await self.voice.shutDown()
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
                        // Screen Recording is the one grant a running process never sees: the
                        // preflight keeps answering no until a fresh start, so the row would sit
                        // on "Fix" after the switch was turned on, with no way forward offered.
                        if permission == .screenRecording { self.notch?.model.needsRestart = true }
                    }
                }
            }
        }
        actions.onToggleCompanion = { [weak self] in
            guard let self, let notch = self.notch else { return }
            self.setCompanionVisible(!notch.model.companionVisible)
        }
        // Dock Cursor, as far as Saathi can honour it today: it takes the companion off the desktop
        // and puts it back. OpenClicky's version flies the buddy into the notch and leaves it there
        // as a glowing badge — that badge is the next slice, and this is the seam it lands on.
        actions.onToggleCursorDock = { [weak self] in
            guard let self, let notch = self.notch else { return }
            let docking = !notch.model.isCursorDocked
            notch.model.isCursorDocked = docking
            self.setCompanionVisible(!docking)
        }
        actions.onExplain = { [weak self] in
            guard let self, let notch = self.notch else { return }
            // The panel closes first so the companion is actually in view when it starts talking —
            // the same reason OpenClicky's (i) closes its own island before speaking.
            notch.apply(.collapsed)
            Task { await self.speaker.speak(Self.whatSaathiDoes, tone: .calm) }
        }
        actions.onRevealSettingsFile = {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.defaultPath()])
        }
        actions.onOpenConversationLog = { [weak self] in
            guard let self else { return }
            let url = self.conversation.fileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                self.conversation.append(.error("nothing has been said yet"))
                self.conversation.flush()
            }
            NSWorkspace.shared.open(url)
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
            guard !self.voice.isReconfiguring else {
                self.voice.reportReconfiguring()
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
