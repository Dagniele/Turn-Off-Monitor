import Foundation

enum CLI {
    static func run(_ arguments: [String]) -> Never {
        guard let first = arguments.first else {
            help()
            exit(0)
        }
        let command = first.lowercased()
        switch command {
        case "list", "status", "ls":
            list()
            exit(0)
        case "off", "spegni":
            turnOff(arguments.dropFirst().joined(separator: " "))
        case "on", "accendi":
            turnOn(arguments.dropFirst().joined(separator: " "))
        case "help", "-h", "--help":
            help()
            exit(0)
        default:
            turnOff(arguments.joined(separator: " "))
        }
    }

    private static func list() {
        let displays = Displays.visible()
        if displays.isEmpty {
            print("No monitors found.")
            return
        }
        for display in displays {
            let vendor = display.vendor.isEmpty ? "" : "\t\(display.vendor)"
            print("\(display.id)\t\(display.name)\t\(display.statusText)\(vendor)")
        }
        let held = Displays.heldNames()
        if held.isEmpty {
            print("\nNo monitor is kept off.")
        } else {
            print("\nKept off: \(held.joined(separator: ", "))")
        }
    }

    private static func turnOff(_ query: String) -> Never {
        guard !query.isEmpty else {
            fputs("Pass the monitor to turn off (name, vendor or id).\n\n", stderr)
            list()
            exit(1)
        }
        do {
            let display = try Displays.turnOff(query)
            if display.isActive {
                print("\(display.name) turned off.")
            } else {
                print("\(display.name) is already off. I'll turn it off again if it comes back.")
            }
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func turnOn(_ query: String) -> Never {
        guard !query.isEmpty else {
            fputs("Pass the monitor to turn on (name, vendor or id).\n\n", stderr)
            list()
            exit(1)
        }
        do {
            print(try Displays.turnOn(query))
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func help() {
        print("""
        Usage:
          turnoffmonitor list
          turnoffmonitor off <monitor>
          turnoffmonitor on <monitor>
          turnoffmonitor <monitor>

        <monitor> is a name, a vendor (MSI, SAM, …) or the id from list.
        A bare name turns that monitor off.

        off removes it from the desktop. While this app is open, it is turned
        off again if it comes back. on brings it back — only when that
        monitor's input is on this Mac.

        With no arguments, opens the menu bar icon.
        Turning a monitor off lasts until you log out.

        """)
    }
}
