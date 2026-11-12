import AppKit
import CoreGraphics
import Foundation

struct MonitorKey: Hashable, Equatable {
    var vendorID: UInt32
    var model: UInt32
    var serial: UInt32

    var storage: String { "\(vendorID)-\(model)-\(serial)" }

    init(vendorID: UInt32, model: UInt32, serial: UInt32) {
        self.vendorID = vendorID
        self.model = model
        self.serial = serial
    }

    init?(storage: String) {
        let parts = storage.split(separator: "-")
        guard parts.count == 3,
              let vendorID = UInt32(parts[0]),
              let model = UInt32(parts[1]),
              let serial = UInt32(parts[2]) else { return nil }
        self.vendorID = vendorID
        self.model = model
        self.serial = serial
    }
}

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let vendor: String
    let vendorID: UInt32
    let model: UInt32
    let serial: UInt32
    let width: Int
    let height: Int
    let isActive: Bool
    let isOnline: Bool
    let isMain: Bool

    var key: MonitorKey { MonitorKey(vendorID: vendorID, model: model, serial: serial) }

    /// Macs keep a vendor-less placeholder in the display list. It is not a monitor.
    var isPlaceholder: Bool { vendorID == 0 && !isOnline && !isActive }

    var hasPicture: Bool { width > 1 && height > 1 }

    var label: String { "\(id) \(name)" }

    var statusText: String {
        if isActive {
            var parts = ["on"]
            if isMain { parts.append("main") }
            if hasPicture { parts.append("\(width)×\(height)") }
            return parts.joined(separator: " · ")
        }
        if Settings.held.contains(key) { return "off · kept off" }
        return "off"
    }
}

enum Settings {
    private static let heldKey = "heldMonitors"

    static var held: Set<MonitorKey> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: heldKey) ?? []
            return Set(raw.compactMap(MonitorKey.init(storage:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.storage).sorted(), forKey: heldKey)
            UserDefaults.standard.synchronize()
        }
    }
}

extension Notification.Name {
    static let turnOffMonitorChanged = Notification.Name("com.danielepagano.turnoffmonitor.changed")
}

enum Displays {
    static func visible() -> [Display] {
        all().filter { !$0.isPlaceholder }.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func resolve(_ query: String) throws -> Display {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { throw DisplayOffError.noMatch(query) }
        let displays = visible()

        if q.allSatisfy(\.isNumber), let id = UInt32(q), let display = displays.first(where: { $0.id == id }) {
            return display
        }

        let needle = q.lowercased()
        let exactName = displays.filter { $0.name.lowercased() == needle }
        if exactName.count == 1 { return exactName[0] }
        if exactName.count > 1 { throw DisplayOffError.ambiguous(q, exactName.map(\.label)) }

        let exactVendor = displays.filter { $0.vendor.lowercased() == needle }
        if exactVendor.count == 1 { return exactVendor[0] }
        if exactVendor.count > 1 { throw DisplayOffError.ambiguous(q, exactVendor.map(\.label)) }

        let contains = displays.filter { $0.name.lowercased().contains(needle) }
        if contains.count == 1 { return contains[0] }
        if contains.isEmpty { throw DisplayOffError.noMatch(q) }
        throw DisplayOffError.ambiguous(q, contains.map(\.label))
    }

    /// Removes the monitor from the desktop and remembers it, so a later reconnect is turned off too.
    @discardableResult
    static func turnOff(_ query: String) throws -> Display {
        let display = try resolve(query)
        return try turnOff(display)
    }

    @discardableResult
    static func turnOff(key storage: String) throws -> Display {
        guard let display = find(storage) else { throw DisplayOffError.noMatch(storage) }
        return try turnOff(display)
    }

    /// Stops keeping this monitor off. Brings it back only when it still has a signal.
    static func turnOn(_ query: String) throws -> String {
        try turnOn(try resolve(query))
    }

    static func turnOn(key storage: String) throws -> String {
        guard let display = find(storage) else { throw DisplayOffError.noMatch(storage) }
        return try turnOn(display)
    }

    static func releaseHold(key storage: String) {
        guard let key = MonitorKey(storage: storage) else { return }
        var held = Settings.held
        held.remove(key)
        Settings.held = held
        notifyChanged()
    }

    static func isHeld(key storage: String) -> Bool {
        guard let key = MonitorKey(storage: storage) else { return false }
        return Settings.held.contains(key)
    }

    /// Turning a monitor off is safe when another monitor would still be on.
    static func canTurnOff(_ display: Display) -> Bool {
        if !display.isActive { return true }
        return all().filter(\.isActive).count > 1
    }

    static func reapplyHold() {
        let held = Settings.held
        guard !held.isEmpty else { return }
        for display in all() where held.contains(display.key) && display.isActive {
            try? disable(display)
        }
    }

    static func heldNames() -> [String] {
        let displays = visible()
        return Settings.held.compactMap { key in
            displays.first { $0.key == key }?.name
        }.sorted()
    }

    static func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .turnOffMonitorChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func turnOff(_ display: Display) throws -> Display {
        try disable(display)
        var held = Settings.held
        held.insert(display.key)
        Settings.held = held
        notifyChanged()
        return display
    }

    private static func turnOn(_ display: Display) throws -> String {
        var held = Settings.held
        held.remove(display.key)
        Settings.held = held
        notifyChanged()

        if display.isActive {
            return "\(display.name) is already on."
        }
        // A panel with no link is 1×1 and offline. Forcing it on would give
        // macOS a desktop you cannot see. Clearing the hold is enough.
        if !display.isOnline && !display.hasPicture {
            return "\(display.name) has no signal. It stays available when its input is on this Mac."
        }
        try SkyLight.setEnabled(display.id, true)
        return "\(display.name) turned on."
    }

    private static func disable(_ display: Display) throws {
        guard display.isActive else { return }
        if all().filter(\.isActive).count <= 1 {
            throw DisplayOffError.lastDisplay
        }
        try SkyLight.setEnabled(display.id, false)
    }

    private static func find(_ storage: String) -> Display? {
        guard let key = MonitorKey(storage: storage) else { return nil }
        return all().first { $0.key == key }
    }

    private static func all() -> [Display] {
        guard let getList = SkyLight.getDisplayList() else { return onlineFallback() }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard getList(16, &ids, &count) == .success else { return onlineFallback() }

        let screens = screenNames()
        return ids.prefix(Int(count)).map { id in
            makeDisplay(id, screens: screens, online: CGDisplayIsOnline(id) != 0)
        }
    }

    private static func onlineFallback() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let screens = screenNames()
        return ids.prefix(Int(count)).map { id in
            makeDisplay(id, screens: screens, online: true)
        }
    }

    private static func makeDisplay(_ id: CGDirectDisplayID, screens: [CGDirectDisplayID: String], online: Bool) -> Display {
        let vendorID = CGDisplayVendorNumber(id)
        let vendor = vendorCode(vendorID)
        let product = productName(id)
        let fallback = vendor.isEmpty ? "Monitor \(id)" : vendor
        let name = screens[id] ?? product ?? fallback
        return Display(
            id: id,
            name: name,
            vendor: vendor,
            vendorID: vendorID,
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            width: Int(CGDisplayPixelsWide(id)),
            height: Int(CGDisplayPixelsHigh(id)),
            isActive: CGDisplayIsActive(id) != 0,
            isOnline: online,
            isMain: CGDisplayIsMain(id) != 0
        )
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
        let order = [Locale.current.identifier, "en_US", "en_GB", "it_IT"]
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

    /// EDID manufacturer id is three letters packed into 16 bits.
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
