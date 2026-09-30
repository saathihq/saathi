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
    let validator = KeyValidator()
    /// Which of Setup's key fields have text in them right now. Which, not what: a key being typed
    /// stays in the view. See `AppController+Setup.swift`.
    var typedKeyFields: Set<ProviderKind> = []
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
    private let dictation = Dictation()
    /// The dictation being started, resolved to whether it did; the end waits on it.
    private var dictationStart: Task<Bool, Never>?
    private var handsFree = false
    private lazy var textPrompt = TextPromptPanel { [weak self] text in self?.voice.sendText(text) }
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
        let companion = self.companion
        ScreenSight.concealOwnWindows = { hidden in companion.alphaValue = hidden ? 0 : 1 }
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
            // And only while a turn is open: the tap goes on firing for a moment after the turn is
            // closed, and a late buffer would leave the bars standing over a closed microphone.
            onListening: { [weak self] level, partial in
                guard let self, self.voice.isTurnOpen else { return }
                self.onboarding?.listening(level: level, partial: partial)
            })
        wireMenu()
        wireNotch()
    }

    public func start() {
        notch?.show()
        companion.show()
        menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        render(force: true)
        startTicking()
        // Dictate's model, fetched now if the system lacks it, so the first press is not a wait.
        let language = configuration.resolvedLanguage
        Task.detached(priority: .utility) { await Dictation.prepare(language: language) }
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
            case .keysReleased: onboarding.turnEnded()
            // A turn that could not open: no microphone, no recogniser. The mic check must hear
            // about it, or it shows "Listening…" with nothing listening and never unlocks.
            case .failure: onboarding.listeningFailed()
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
        if scripted { settings.language = "en-US" }
        return settings
    }

    // MARK: voice

    /// Swaps in a new configuration without a relaunch. The teardown order lives in
    /// `VoiceConductor.reconfigure`; a second Save while one is under way does nothing at all.
    func reconfigure(_ updated: SaathiConfiguration) async {
        guard await voice.reconfigure(to: updated) else { return }
        // A new session starts push-to-talk.
        handsFree = false
        notch?.model.isAlwaysListening = false
        configuration = updated
        systemSpeaker.apply(SpeechSettings(updated))
        applyConfigurationToIsland()
    }

    /// Re-fills everything the island says about where Saathi thinks. Called at startup and after
    /// every reconfigure, so the Home tab can never describe a provider that is no longer in use.
    func applyConfigurationToIsland() {
        guard let notch else { return }
        Self.describe(configuration, on: notch.model)

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

        // Last, and every time: what a Save would do depends on the file, and the file is what
        // has just changed.
        refreshPlanExplanation()
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
                case .talkBegan: self.voice.keysBegan()
                case .talkEnded: self.voice.keysEnded()
                case .textRequested: self.toggleTextPrompt()
                case .dictateBegan: self.beginDictation()
                case .dictateEnded: self.endDictation(typing: true)
                case .dictateCancelled: self.endDictation(typing: false)
                case .handsFreeToggled: self.toggleHandsFree()
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

    // MARK: the other three shortcuts

    /// Text: control twice. First run has its own cards to answer; these three wait for it.
    private func toggleTextPrompt() {
        guard onboarding == nil else { return }
        if textPrompt.isShowing { textPrompt.dismiss() } else { textPrompt.show(on: NSScreen.main) }
    }

    /// Dictate: fn and control held. Listens on this Mac only and types what was heard into the
    /// app in front — no model, no reply.
    private func beginDictation() {
        guard onboarding == nil else { return }
        let language = configuration.resolvedLanguage
        let dictation = self.dictation
        let microphone = voice.sharedMicrophone
        dictationStart = Task { @MainActor in
            do {
                try await dictation.begin(language: language, microphone: microphone)
                self.handle(.status("listening… (dictating)"))
                return true
            } catch {
                self.handle(.failure("dictation: \(error.localizedDescription)"))
                return false
            }
        }
    }

    private func endDictation(typing: Bool) {
        guard let start = dictationStart else { return }
        dictationStart = nil
        let dictation = self.dictation
        Task { @MainActor in
            guard await start.value else { return }
            guard typing else {
                self.conversation.append(.action("dictation cancelled: released too quickly to be speech"))
                dictation.cancel()
                self.handle(.status("heard"))
                return
            }
            let heard = await dictation.end()
            guard !heard.isEmpty else {
                self.conversation.append(.error("dictation heard nothing (\(dictation.lastReport))"))
                // Near-silence from the microphone is a different problem from speech not being
                // understood, and saying which is the difference between retrying and not.
                self.handle(.failure(dictation.heardSilence
                    ? "dictation got no sound from the microphone — try again, or check the input in Sound settings"
                    : "did not catch that"))
                return
            }
            self.handle(.status("heard"))
            self.conversation.append(.action("dictated: \(heard)"))
            do {
                try await TextTyper.type(heard)
            } catch {
                self.handle(.failure("dictation: \(error.localizedDescription)"))
            }
        }
    }

    /// Hands-free: fn and control twice, on and off.
    private func toggleHandsFree() {
        guard onboarding == nil else { return }
        let wanted = !handsFree
        Task { @MainActor in
            guard await self.voice.setHandsFree(wanted) else { return }
            self.handsFree = wanted
            self.notch?.model.isAlwaysListening = wanted
            if !wanted { self.handle(.status("heard")) }
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
        notch.model.companionVisible = true
        notch.model.tab = Self.openingTab(for: configuration)
        // The verdicts are seeded from what is already on disk — otherwise every launch shows
        // `.empty` regardless of what is stored, and a stored key never counts as one. Only for a
        // vendor the config actually names; see `seededKeyStates`. Before the island is filled in,
        // because the sentence under the fields is drawn from them.
        notch.model.keyStates = Self.seededKeyStates(for: configuration)
        applyConfigurationToIsland()

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
        // Keys, the picker, the switch and the language: `AppController+Setup.swift`.
        wireSetup(into: &actions)

        notch.actions = actions
    }
}
