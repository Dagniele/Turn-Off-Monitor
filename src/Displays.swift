import AppKit
import CoreGraphics
import Foundation

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let vendor: String
    let vendorID: UInt32
    let width: Int
    let height: Int
    let isActive: Bool
    let isOnline: Bool
    let isMain: Bool

    var isMSI: Bool { vendor == "MSI" }

    /// Macs keep a vendor-less placeholder in the display list. It is not a monitor.
    var isPlaceholder: Bool { vendorID == 0 && !isOnline && !isActive }

    var hasPicture: Bool { width > 1 && height > 1 }

    var statusText: String {
        if isActive {
            var parts = ["acceso"]
            if isMain { parts.append("principale") }
            if hasPicture { parts.append("\(width)×\(height)") }
            return parts.joined(separator: " · ")
        }
        if isMSI { return "spento · non in uso" }
        return "spento"
    }
}

enum Settings {
    private static let holdKey = "holdMSIOff"

    static var holdMSIOff: Bool {
        get { UserDefaults.standard.bool(forKey: holdKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: holdKey)
            UserDefaults.standard.synchronize()
        }
    }
}

extension Notification.Name {
    static let spegniMSIChanged = Notification.Name("com.danielepagano.spegnimsi.changed")
}

enum Displays {
    static func visible() -> [Display] {
        all().filter { !$0.isPlaceholder }.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func msiDisplays() -> [Display] {
        all().filter(\.isMSI)
    }

    static func all() -> [Display] {
        guard let getList = SkyLight.getDisplayList() else { return onlineFallback() }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard getList(16, &ids, &count) == .success else { return onlineFallback() }

        let screens = screenNames()
        return ids.prefix(Int(count)).map { id in
            let vendorID = CGDisplayVendorNumber(id)
            let vendor = vendorCode(vendorID)
            let width = Int(CGDisplayPixelsWide(id))
            let height = Int(CGDisplayPixelsHigh(id))
            let product = productName(id)
            let name = screens[id] ?? product ?? (vendor == "MSI" ? "MSI" : "Monitor \(id)")
            return Display(
                id: id,
                name: name,
                vendor: vendor,
                vendorID: vendorID,
                width: width,
                height: height,
                isActive: CGDisplayIsActive(id) != 0,
                isOnline: CGDisplayIsOnline(id) != 0,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    /// Turns every active MSI off and keeps it off if it reconnects.
    /// Refuses if that would leave the Mac with no picture.
    @discardableResult
    static func turnMSIOff() throws -> Int {
        let turnedOff = try disableActiveMSI()
        Settings.holdMSIOff = true
        notifyChanged()
        return turnedOff
    }

    /// Stops forcing the MSI off, then tries to bring it back onto the desktop.
    /// A monitor whose input is on the other Mac has no signal: clearing the hold
    /// is still the useful part, because the panel comes back on its own later.
    @discardableResult
    static func turnMSIOn() -> [String] {
        Settings.holdMSIOff = false
        notifyChanged()

        let msis = msiDisplays()
        if msis.isEmpty {
            return ["Nessun monitor MSI trovato. Non lo terrò spento."]
        }

        var notes: [String] = []
        for display in msis where !display.isActive {
            // A panel with no link is 1×1 and offline. Forcing it on would
            // give macOS a desktop you cannot see. Clearing the hold is enough:
            // the monitor joins the desktop on its own when its input comes back.
            if !display.isOnline && !display.hasPicture {
                notes.append("\(display.name) non ha segnale. Appena l'ingresso torna su questo Mac resta acceso.")
                continue
            }
            do {
                try SkyLight.setEnabled(display.id, true)
                notes.append("\(display.name) acceso.")
            } catch {
                notes.append("Non riesco a riaccendere \(display.name): \(error)")
            }
        }
        if notes.isEmpty {
            notes.append("MSI già acceso. Non lo spengo più da solo.")
        }
        return notes
    }

    /// If the user asked to keep the MSI off and it came back (input switch, wake),
    /// remove it from the desktop again. Does not rewrite preferences.
    static func reapplyHold() {
        guard Settings.holdMSIOff else { return }
        _ = try? disableActiveMSI()
    }

    private static func disableActiveMSI() throws -> Int {
        let displays = all()
        let activeMSI = displays.filter { $0.isMSI && $0.isActive }
        if activeMSI.isEmpty { return 0 }

        let activeCount = displays.filter(\.isActive).count
        if activeCount - activeMSI.count < 1 {
            throw DisplayOffError.lastDisplay
        }

        for display in activeMSI {
            try SkyLight.setEnabled(display.id, false)
        }
        return activeMSI.count
    }

    static func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .spegniMSIChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func onlineFallback() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let screens = screenNames()
        return ids.prefix(Int(count)).map { id in
            let vendorID = CGDisplayVendorNumber(id)
            let vendor = vendorCode(vendorID)
            return Display(
                id: id,
                name: screens[id] ?? (vendor == "MSI" ? "MSI" : "Monitor \(id)"),
                vendor: vendor,
                vendorID: vendorID,
                width: Int(CGDisplayPixelsWide(id)),
                height: Int(CGDisplayPixelsHigh(id)),
                isActive: CGDisplayIsActive(id) != 0,
                isOnline: true,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[number.uint32Value] = name }
        }
        return names
    }

    private static func productName(_ id: CGDirectDisplayID) -> String? {
        guard let copy = SkyLight.copyDisplayInfo(), let pointer = copy(id) else { return nil }
        let info = Unmanaged<CFDictionary>.fromOpaque(pointer).takeRetainedValue() as NSDictionary
        guard let names = info["DisplayProductName"] as? NSDictionary else { return nil }
        let order = [Locale.current.identifier, "it_IT", "en_US", "en_GB"]
        for key in order {
            if let name = names[key] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        for value in names.allValues {
            guard let name = value as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// EDID manufacturer id is three letters packed into 16 bits. MSI is 13929, Samsung is 19501.
    private static func vendorCode(_ vendorID: UInt32) -> String {
        func letter(_ value: UInt32) -> Character? {
            let index = value & 0x1F
            guard index > 0, let scalar = UnicodeScalar(index + 64) else { return nil }
            return Character(scalar)
        }
        let chars = [letter(vendorID >> 10), letter(vendorID >> 5), letter(vendorID)].compactMap { $0 }
        guard chars.count == 3 else { return vendorID == 0 ? "" : String(vendorID) }
        return String(chars)
    }
}
