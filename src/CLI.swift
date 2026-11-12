import Foundation

enum CLI {
    static func run(_ arguments: [String]) -> Never {
        let command = arguments.first?.lowercased() ?? "help"
        switch command {
        case "list", "status", "ls":
            list()
            exit(0)
        case "off", "spegni":
            spegni()
        case "on", "accendi":
            accendi()
        case "help", "-h", "--help":
            help()
            exit(0)
        default:
            fputs("Comando sconosciuto: \(command)\n\n", stderr)
            help()
            exit(1)
        }
    }

    private static func list() {
        let displays = Displays.visible()
        if displays.isEmpty {
            print("Nessun monitor trovato.")
            return
        }
        for display in displays {
            let mark = display.isMSI ? "  ← condiviso" : ""
            print("\(display.id)\t\(display.name)\t\(display.statusText)\(mark)")
        }
        if Settings.holdMSIOff {
            print("\nTengo l'MSI spento se ricompare.")
        } else {
            print("\nL'MSI può accendersi quando l'ingresso torna su questo Mac.")
        }
    }

    private static func spegni() -> Never {
        do {
            let turnedOff = try Displays.turnMSIOff()
            if turnedOff == 0 {
                if Displays.msiDisplays().isEmpty {
                    print("Nessun monitor MSI trovato. Se lo colleghi, lo tengo spento.")
                } else {
                    print("MSI già spento. Lo tengo spento se ricompare.")
                }
            } else {
                print("MSI spento. Le finestre restano sull'altro monitor.")
            }
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func accendi() -> Never {
        if Displays.msiDisplays().isEmpty {
            Settings.holdMSIOff = false
            Displays.notifyChanged()
            print("Nessun monitor MSI trovato. Non lo terrò spento.")
            exit(0)
        }
        for note in Displays.turnMSIOn() {
            print(note)
        }
        exit(0)
    }

    private static func help() {
        let text = """
        Uso:
          spegnimsi list      mostra i monitor
          spegnimsi off       stacca l'MSI da questo Mac
          spegnimsi on        riattacca l'MSI

        off toglie l'MSI dal desktop (le finestre tornano sul Samsung) e,
        finché l'app è aperta, lo stacca di nuovo se ricompare.
        on va usato quando l'ingresso del monitor è su questo Mac.

        Senza argomenti apre l'icona nella barra dei menu.
        Lo spegnimento dura fino al logout.

        """
        print(text)
    }
}
