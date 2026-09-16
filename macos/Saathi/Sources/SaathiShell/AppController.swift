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

    private let configuration: SaathiConfiguration
    private let data: MascotData
    private let color: MascotColor

    private var machine: CompanionStateMachine
    private var shown: CompanionState = .idle

    private let companion: CompanionPanel
    private let notch: NotchPanel?
    private let menu: MenuBarController

    private var speaker: ObservedSpeaker!
    private var performer: ActionPerformer!
    private var session: (any VoiceSession)?
    private var turnOpen = false
    private var monitor: HoldToTalkMonitor?
    private var ticker: Timer?

    public init() throws {
        configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
        data = try MascotData.load()
        color = MascotColor(paletteName: "blue", in: data) ?? MascotColor(hex: "#377FE6")
        machine = CompanionStateMachine(now: CACurrentMediaTime())
        companion = CompanionPanel(data: data, color: color)
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
    }

    public func start() {
        notch?.show()
        companion.show()
        menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        render(force: true)
        startTicking()
        startVoice()
        startHoldToTalk()
        refreshPermissions()
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
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: voice

    private func startVoice() {
        do {
            let session = try VoiceSessionFactory.make(configuration: configuration, speaker: speaker)
            self.session = session
            let callbacks = VoiceSessionCallbacks(
                onUserTranscript: { [weak self] text in Task { @MainActor in self?.handle(.userSpoke(text)) } },
                onSaathiTranscript: { [weak self] text in Task { @MainActor in self?.handle(.saathiSpoke(text)) } },
                onAction: { [weak self] action in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handle(.action(action))
                        Task { try? await self.performer.perform(action) }
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
            handle(.failure(error.localizedDescription))
        }
    }

    private func beginTurn() {
        guard let session, !turnOpen else { return }
        turnOpen = true
        Task {
            do { try await session.beginTurn() } catch { await MainActor.run { self.handle(.failure(error.localizedDescription)) } }
        }
    }

    private func endTurn() {
        guard let session, turnOpen else { return }
        turnOpen = false
        Task {
            do { try await session.endTurn() } catch { await MainActor.run { self.handle(.failure(error.localizedDescription)) } }
        }
    }

    // MARK: hold to talk

    private func startHoldToTalk() {
        let monitor = HoldToTalkMonitor { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .began:
                    self.beginTurn()
                    self.handle(.keysHeld)
                case .ended:
                    self.endTurn()
                    self.handle(.keysReleased)
                }
            }
        }
        do {
            try monitor.start()
            self.monitor = monitor
        } catch {
            // Not permitted: the menu's Fix permissions item opens the pane; the Talk item still works.
            self.monitor = nil
        }
    }

    private func refreshPermissions() {
        let missing = Permission.allCases.filter { Permissions.status(of: $0) != .granted }.map(\.title)
        menu.setPermissionsNeeded(missing)
    }

    // MARK: menu

    private func wireMenu() {
        menu.onTalk = { [weak self] in
            guard let self else { return }
            if self.turnOpen { self.endTurn() } else { self.beginTurn() }
            self.handle(.talkPressed)
        }
        menu.onToggleCompanion = { [weak self] visible in
            guard let self else { return }
            if visible { self.companion.show() } else { self.companion.hide() }
        }
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
                // If the grant arrives while we run, the tap can be installed next time Talk is used.
            } else if let first = Permission.allCases.first(where: { Permissions.status(of: $0) != .granted }) {
                NSWorkspace.shared.open(first.settingsURL)
            }
            self.refreshPermissions()
        }
        menu.onQuit = { [weak self] in
            guard let self else { return }
            self.handle(.quit)
            Task {
                await self.session?.stop()
                try? await Task.sleep(nanoseconds: 1_400_000_000)   // let powering-down settle
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}
