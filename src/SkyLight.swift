import CoreGraphics
import Darwin
import Foundation

// SLSConfigureDisplayEnabled is the private WindowServer call that adds or
// removes a display from the desktop while the cable stays plugged in.
// CoreGraphics re-exports it as CGSConfigureDisplayEnabled. Resolved at
// runtime so a missing symbol fails clearly instead of failing to link.

typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias GetDisplayListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias CopyDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> UnsafeMutableRawPointer?

enum SkyLight {
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    static func configureDisplayEnabled() -> ConfigureDisplayEnabledFn? {
        load("SLSConfigureDisplayEnabled")
    }

    static func getDisplayList() -> GetDisplayListFn? {
        load("SLSGetDisplayList")
    }

    static func copyDisplayInfo() -> CopyDisplayInfoFn? {
        load("SLSCopyDisplayInfoDictionary")
    }

    static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) throws {
        guard let configure = configureDisplayEnabled() else {
            throw DisplayOffError.symbolMissing("SLSConfigureDisplayEnabled")
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayOffError.failed("CGBeginDisplayConfiguration")
        }

        let configured = configure(config, id, enabled)
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayOffError.rejected("SLSConfigureDisplayEnabled", configured)
        }

        // forSession reverts at logout, so a stuck display comes back on its own.
        let completed = CGCompleteDisplayConfiguration(config, .forSession)
        guard completed == .success else {
            throw DisplayOffError.rejected("CGCompleteDisplayConfiguration", completed)
        }
    }

    private static func load<T>(_ name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

enum DisplayOffError: Error, LocalizedError, CustomStringConvertible {
    case symbolMissing(String)
    case failed(String)
    case rejected(String, CGError)
    case lastDisplay

    var description: String { errorDescription ?? "Errore sconosciuto." }

    var errorDescription: String? {
        switch self {
        case let .symbolMissing(name):
            return "\(name) non è più disponibile. Un aggiornamento di macOS può aver spostato l'API."
        case let .failed(call):
            return "\(call) non è riuscita."
        case let .rejected(call, error):
            return "\(call) ha restituito l'errore \(error.rawValue)."
        case .lastDisplay:
            return "Non spengo l'unico monitor acceso."
        }
    }
}
