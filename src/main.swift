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
            name: .turnOffMonitorChanged,
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

    @objc private func turnOffItem(_ sender: NSMenuItem) {
        guard let storage = sender.representedObject as? String else { return }
        do {
            _ = try Displays.turnOff(key: storage)
        } catch {
            present(error)
        }
        updateIcon()
    }

    @objc private func turnOnItem(_ sender: NSMenuItem) {
        guard let storage = sender.representedObject as? String else { return }
        do {
            _ = try Displays.turnOn(key: storage)
        } catch {
            present(error)
        }
        updateIcon()
    }

    @objc private func toggleHold(_ sender: NSMenuItem) {
        guard let storage = sender.representedObject as? String else { return }
        if Displays.isHeld(key: storage) {
            Displays.releaseHold(key: storage)
        } else {
            do {
                _ = try Displays.turnOff(key: storage)
            } catch {
                present(error)
            }
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
            present(message: "macOS is asking for confirmation. System Settings → General → Login Items → allow Turn Off Monitor.")
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let displays = Displays.visible()

        let stray = displays.filter { Displays.isHeld(key: $0.key.storage) && $0.isActive }
        if !stray.isEmpty {
            let warning = NSMenuItem(
                title: "\(stray.map(\.name).joined(separator: ", ")) is on and can take windows",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if displays.isEmpty {
            let empty = NSMenuItem(title: "No monitors", action: nil, keyEquivalent: "")
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
        menu.addItem(submenuItem("Turn off", displays: displays, action: #selector(turnOffItem(_:)), requireCanTurnOff: true))
        let turnOn = submenuItem("Turn on", displays: displays, action: #selector(turnOnItem(_:)), requireCanTurnOff: false)
        turnOn.subtitle = "Only when that monitor's input is on this Mac"
        menu.addItem(turnOn)
        menu.addItem(submenuItem("Keep off", displays: displays, action: #selector(toggleHold(_:)), requireCanTurnOff: false, showHoldState: true))

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func submenuItem(
        _ title: String,
        displays: [Display],
        action: Selector,
        requireCanTurnOff: Bool,
        showHoldState: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if displays.isEmpty {
            let empty = NSMenuItem(title: "No monitors", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for display in displays {
                let child = NSMenuItem(title: display.name, action: action, keyEquivalent: "")
                child.target = self
                child.representedObject = display.key.storage
                child.subtitle = display.statusText
                if requireCanTurnOff {
                    child.isEnabled = Displays.canTurnOff(display)
                }
                if showHoldState {
                    child.state = Displays.isHeld(key: display.key.storage) ? .on : .off
                }
                submenu.addItem(child)
            }
        }
        item.submenu = submenu
        return item
    }

    private func updateIcon() {
        let displays = Displays.visible()
        let heldActive = displays.contains { Displays.isHeld(key: $0.key.storage) && $0.isActive }
        let anyHeld = !Settings.held.isEmpty
        let style: MenuIcon.Style
        let tip: String
        if heldActive {
            style = .warning
            tip = "Turn Off Monitor — a kept-off monitor is on"
        } else if anyHeld {
            style = .heldOff
            tip = "Turn Off Monitor — keeping a monitor off"
        } else {
            style = .idle
            tip = "Turn Off Monitor"
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
        alert.messageText = "Turn Off Monitor"
        alert.informativeText = message
        alert.runModal()
    }

    static weak var shared: AppDelegate?
}

enum MenuIcon {
    enum Style { case idle, warning, heldOff }

    static func image(_ style: Style) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5, width: 15, height: 10), xRadius: 1.6, yRadius: 1.6)
            body.lineWidth = 1.3
            if style == .warning {
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
