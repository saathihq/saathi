//
//  main.swift
//  SaathiApp
//
//  The bundle's main executable. Everything lives in SaathiShell so it can be tested; this only
//  starts it.
//

import AppKit
import SaathiShell

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar app: no Dock tile, no main window

// An accessory app has no menu bar, so nothing built a main menu — and ⌘V is dispatched through the
// main menu, so pasting an API key into the Setup tab did nothing at all. This menu is never shown;
// it exists so the editing commands have somewhere to be dispatched from.
MainActor.assumeIsolated { EditMenu.install(into: app) }

// main.swift's top-level code runs on the main thread but is not itself main-actor-isolated;
// `assumeIsolated` asserts what is already true here rather than adding a hop.
let controller: AppController = MainActor.assumeIsolated {
    do {
        return try AppController()
    } catch {
        let alert = NSAlert()
        alert.messageText = "Saathi could not start"
        alert.informativeText = "\(error)"
        alert.runModal()
        exit(1)
    }
}
MainActor.assumeIsolated {
    controller.start()
}
app.run()
