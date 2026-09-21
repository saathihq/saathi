//
//  AppController+Onboarding.swift
//  SaathiShell
//
//  First run, wired to the app: when it shows, what each of the coordinator's effects really does,
//  and how the voice session behaves while it is up.
//
//  Three things here are decisions rather than plumbing:
//
//  • First run shows itself only to an install that has nothing configured. `onboarded` did not
//    exist before contract 0.8.0, so every working install has it unset; treating those as new
//    would greet someone who has been using Saathi for weeks with "Namaste, I'm Saathi". The menu's
//    "Run onboarding again" shows it to anyone who asks.
//  • No voice session exists until the permission cards are done. Starting one asks macOS for
//    speech recognition on the spot, and first run asks for that itself — one permission at a time,
//    with the reason said first.
//  • After that the session only listens (`listensOnly`): the mic check and the four questions
//    are answered by what was heard, before any model has been chosen. The trial chat is the one
//    real conversation, on the hosted lane, and only for as long as that card is showing; the
//    configuration it runs on is never the one written to disk.
//

import AppKit
import SaathiContract
import SaathiKit
import ServiceManagement

extension AppController {

    /// Whether launch should open first run by itself.
    static func shouldOnboard(_ configuration: SaathiConfiguration) -> Bool {
        configuration.onboarded != true && openingTab(for: configuration) == .setup
    }

    func beginOnboarding(isFirstRun: Bool) {
        guard onboarding == nil else {
            onboardingWindow?.show()
            return
        }

        let languages = OnboardingLanguages.supported()
        let model = OnboardingModel(
            supportedLanguages: languages.map(\.tag),
            palette: Array(data.palette.keys))

        // The spec's welcome card: Saathi registers itself to start at login and says so, with the
        // switch that undoes it right there. Only on a true first run — asking to see onboarding
        // again is not asking to have a login item put back.
        // Once, ever. `isFirstRun` is true on every launch until first run is finished, so without
        // the flag someone who turned the switch off and then closed the card would be registered
        // again at the next launch, against the one choice they had made.
        let registeredKey = "didRegisterLoginItemOnFirstRun"
        if isFirstRun, !UserDefaults.standard.bool(forKey: registeredKey) {
            UserDefaults.standard.set(true, forKey: registeredKey)
            if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
            menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        }

        var effects = OnboardingEffects()
        effects.speak = { [weak self] text, tone in await self?.speaker.speak(text, tone: tone) }
        effects.stopSpeaking = { [weak self] in self?.speaker.stop() }
        effects.requestPermission = { [weak self] permission in
            if permission == .inputMonitoring { _ = HoldToTalkMonitor.requestPermission() }
            let status = await Permissions.request(permission)
            self?.startHoldToTalkIfPossible()
            self?.refreshPermissions()
            return status
        }
        effects.permissionStatus = { [weak self] permission in
            self?.startHoldToTalkIfPossible()   // a grant made in System Settings takes effect here
            self?.refreshPermissions()
            return Permissions.status(of: permission)
        }
        effects.openSettings = { NSWorkspace.shared.open($0.settingsURL) }
        effects.enrollTrial = { [weak self] in
            _ = try await TrialEnrollment.enroll(at: ConfigurationStore.defaultPath())
            // The token and the device id were written by the enrolment; take them up so the next
            // save from here does not write an older copy back over them.
            if let self, let saved = try? ConfigurationStore.load(from: ConfigurationStore.defaultPath()) {
                self.configuration.token = saved.token
                self.configuration.deviceId = saved.deviceId
            }
        }
        effects.save = { [weak self] model in self?.onboardingChanged(model) }
        effects.trialChatChanged = { [weak self] active in self?.setTrialChat(active) }
        effects.setListening = { [weak self] on in
            // The menu's Talk is a toggle; only press it when it is not already where it should be.
            guard let self, self.voice.isTurnOpen != on else { return }
            self.voice.toggleTalk()
        }
        effects.finish = { [weak self] model in self?.finishOnboarding(model) }

        let coordinator = OnboardingCoordinator(model: model, effects: effects)
        onboarding = coordinator
        onboardingWindow = OnboardingWindowController(
            coordinator: coordinator,
            data: data,
            languages: languages.map { (tag: $0.tag, name: $0.name) },
            startAtLogin: SMAppService.mainApp.status == .enabled,
            onStartAtLoginChanged: { [weak self] enabled in self?.menu.onToggleStartAtLogin(enabled) })

        // Asked for from the menu, with a session already running: it listens only from here on.
        if voice.hasSession {
            listensOnly = true
            Task { await self.voice.reconfigure(to: self.configuration) }
        }

        notch?.apply(.collapsed)
        onboardingWindow?.show()
        coordinator.begin()
    }

    /// Every change first run makes: keep what was learned, and bring the listening session up the
    /// moment the permission cards are behind us.
    private func onboardingChanged(_ model: OnboardingModel) {
        model.apply(to: &configuration)
        do {
            try ConfigurationStore.save(configuration, to: ConfigurationStore.defaultPath())
        } catch {
            handle(.failure("could not save: \(error.localizedDescription)"))
        }

        if onboarding != nil, model.step == .allSet, !voice.hasSession, !voice.isReconfiguring {
            listensOnly = true
            voice.start(with: configuration)
        }
    }

    /// The one real conversation in first run. `active` runs the hosted lane on the trial token
    /// that was just issued; leaving the card goes back to listening only. Neither is saved: where
    /// Saathi thinks afterwards is the last card's question.
    private func setTrialChat(_ active: Bool) {
        listensOnly = !active
        var running = configuration
        if active { running.provider = .hosted }
        Task { await self.voice.reconfigure(to: running) }
    }

    private func finishOnboarding(_ model: OnboardingModel) {
        let coordinator = onboarding
        onboardingWindow?.close()
        onboardingWindow = nil
        onboarding = nil
        listensOnly = false

        onboardingChanged(model)
        if model.opensSetupAfterwards { notch?.model.tab = .setup }
        notch?.model.language = configuration.language ?? ""

        // A fresh session on whatever was chosen — or the first real one, if first run was closed
        // before the listening session ever started.
        let final = configuration
        Task {
            // The closing line first: swapping the session stops the speaker, and "That's
            // everything…" was being cut off by the very thing it announces.
            await coordinator?.settle()
            // And any swap already under way: a reconfigure that finds another in flight does
            // nothing at all, which here would leave Saathi listening only, for good.
            for _ in 0..<100 where self.voice.isReconfiguring {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if self.voice.hasSession {
                await self.reconfigure(final)
            } else {
                self.voice.start(with: final)
                self.applyConfigurationToIsland()
            }
        }
    }
}
