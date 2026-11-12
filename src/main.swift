import AppKit
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var reapplyWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        updateIcon()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(externalChange),
            name: .spegniMSIChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async {
                AppDelegate.shared?.scheduleReapply()
            }
        }, nil)

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reapplyIfHolding()
            self?.updateIcon()
        }

        scheduleReapply()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func externalChange() {
        UserDefaults.standard.synchronize()
        scheduleReapply()
    }

    @objc private func screenChanged() {
        scheduleReapply()
    }

    private func scheduleReapply() {
        reapplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reapplyIfHolding()
            self?.updateIcon()
        }
        reapplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func reapplyIfHolding() {
        Displays.reapplyHold()
    }

    @objc private func turnOff(_ sender: Any?) {
        do {
            _ = try Displays.turnMSIOff()
        } catch {
            present(error)
        }
        updateIcon()
    }

    @objc private func turnOn(_ sender: Any?) {
        let notes = Displays.turnMSIOn()
        updateIcon()
        if let problem = notes.first(where: { $0.hasPrefix("Non riesco") }) {
            present(message: problem)
        }
    }

    @objc private func toggleHold(_ sender: Any?) {
        if Settings.holdMSIOff {
            Settings.holdMSIOff = false
            Displays.notifyChanged()
        } else {
            turnOff(sender)
        }
        updateIcon()
    }

    @objc private func toggleLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(error)
        }
        if SMAppService.mainApp.status == .requiresApproval {
            present(message: "macOS vuole una conferma. Aprilo da Impostazioni di Sistema → Generali → Elementi di accesso e abilita SpegniMSI.")
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let displays = Displays.visible()
        let msiActive = displays.contains { $0.isMSI && $0.isActive }

        if msiActive {
            let warning = NSMenuItem(title: "L'MSI è acceso: le finestre possono finirci", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if displays.isEmpty {
            let empty = NSMenuItem(title: "Nessun monitor", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in displays {
                let item = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.subtitle = display.statusText
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let off = NSMenuItem(title: "Spegni MSI", action: #selector(turnOff(_:)), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        let on = NSMenuItem(title: "Accendi MSI", action: #selector(turnOn(_:)), keyEquivalent: "")
        on.target = self
        on.subtitle = "Solo quando l'ingresso del monitor è su questo Mac"
        menu.addItem(on)

        menu.addItem(.separator())

        let hold = NSMenuItem(title: "Tieni l'MSI spento se ricompare", action: #selector(toggleHold(_:)), keyEquivalent: "")
        hold.target = self
        hold.state = Settings.holdMSIOff ? .on : .off
        menu.addItem(hold)

        let login = NSMenuItem(title: "Apri al login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Esci", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateIcon() {
        let displays = Displays.visible()
        let msiActive = displays.contains { $0.isMSI && $0.isActive }
        let style: MenuIcon.Style
        let tip: String
        if Settings.holdMSIOff {
            style = .heldOff
            tip = "Spegni MSI — l'MSI resta spento"
        } else if msiActive {
            style = .msiOn
            tip = "Spegni MSI — l'MSI è acceso"
        } else {
            style = .idle
            tip = "Spegni MSI"
        }
        statusItem.button?.image = MenuIcon.image(style)
        statusItem.button?.toolTip = tip
    }

    private func present(_ error: Error) {
        present(message: error.localizedDescription)
    }

    private func present(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spegni MSI"
        alert.informativeText = message
        alert.runModal()
    }

    static weak var shared: AppDelegate?
}

enum MenuIcon {
    enum Style { case idle, msiOn, heldOff }

    static func image(_ style: Style) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5, width: 15, height: 10), xRadius: 1.6, yRadius: 1.6)
            body.lineWidth = 1.3
            if style == .msiOn {
                body.fill()
            } else {
                body.stroke()
            }
            let stand = NSBezierPath()
            stand.lineWidth = 1.3
            stand.move(to: NSPoint(x: 9, y: 5))
            stand.line(to: NSPoint(x: 9, y: 2.5))
            stand.move(to: NSPoint(x: 6, y: 2.5))
            stand.line(to: NSPoint(x: 12, y: 2.5))
            stand.stroke()
            if style == .heldOff {
                let slash = NSBezierPath()
                slash.lineWidth = 1.5
                slash.move(to: NSPoint(x: 2, y: 3.5))
                slash.line(to: NSPoint(x: 16, y: 15))
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

private func launchMenuApp() {
    let delegate = AppDelegate()
    AppDelegate.shared = delegate
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}

let arguments = Array(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") })
if arguments.isEmpty {
    launchMenuApp()
} else {
    CLI.run(arguments)
}
