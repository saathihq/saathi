//
//  main.swift
//  MascotPreview
//
//  Every expression in a grid, a colour menu, and eyes that follow the pointer. For looking at,
//  not for shipping: `swift run MascotPreview`.
//

import AppKit
import SaathiMascot

let data = try MascotData.load()
let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class PreviewController: NSObject {
    var mascots: [MascotView] = []
    let colorMenu = NSPopUpButton(frame: .zero, pullsDown: false)

    @objc func colorChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, let color = MascotColor(paletteName: name, in: data) else { return }
        for m in mascots { m.color = color }
    }

    @objc func blinkAll(_ sender: Any?) { mascots.forEach { $0.blinkNow() } }
    @objc func spinAll(_ sender: Any?) { mascots.forEach { $0.spin() } }
}

let controller = PreviewController()
let cell: CGFloat = 96
let columns = 8
let rows = Int((Double(MascotExpression.allCases.count) / Double(columns)).rounded(.up))
let content = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * (cell + 24) + 24, height: CGFloat(rows) * (cell + 36) + 80))
content.wantsLayer = true
content.layer?.backgroundColor = CGColor(gray: 0.06, alpha: 1)

let blue = MascotColor(paletteName: "blue", in: data)!
for (i, expression) in MascotExpression.allCases.enumerated() {
    let column = i % columns, row = i / columns
    let x = 24 + CGFloat(column) * (cell + 24)
    let y = content.bounds.height - 80 - CGFloat(row + 1) * (cell + 36)
    let mascot = MascotView(data: data, color: blue, expression: expression, frame: NSRect(x: x, y: y + 24, width: cell, height: cell))
    content.addSubview(mascot)
    controller.mascots.append(mascot)

    let label = NSTextField(labelWithString: expression.rawValue)
    label.frame = NSRect(x: x - 12, y: y, width: cell + 24, height: 18)
    label.alignment = .center
    label.font = .systemFont(ofSize: 11)
    label.textColor = NSColor(white: 0.6, alpha: 1)
    content.addSubview(label)
}

controller.colorMenu.frame = NSRect(x: 24, y: content.bounds.height - 56, width: 140, height: 28)
controller.colorMenu.addItems(withTitles: data.palette.keys.sorted())
controller.colorMenu.selectItem(withTitle: "blue")
controller.colorMenu.target = controller
controller.colorMenu.action = #selector(PreviewController.colorChanged(_:))
content.addSubview(controller.colorMenu)

let blink = NSButton(title: "Blink", target: controller, action: #selector(PreviewController.blinkAll(_:)))
blink.frame = NSRect(x: 180, y: content.bounds.height - 56, width: 80, height: 28)
content.addSubview(blink)
let spin = NSButton(title: "Spin", target: controller, action: #selector(PreviewController.spinAll(_:)))
spin.frame = NSRect(x: 270, y: content.bounds.height - 56, width: 80, height: 28)
content.addSubview(spin)

let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Saathi mascot — \(MascotExpression.allCases.count) expressions"
window.contentView = content
window.center()
window.makeKeyAndOrderFront(nil)

// Eyes follow the pointer anywhere in the window.
_ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
    for m in controller.mascots {
        m.lookAt(m.convert(event.locationInWindow, from: nil))
    }
    return event
}
window.acceptsMouseMovedEvents = true

app.activate(ignoringOtherApps: true)
app.run()
