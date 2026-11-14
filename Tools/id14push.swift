// id14push – Opus-Testwerkzeug: sendet den gespeicherten Zustand (state.json) Befehl fuer Befehl,
// mit Pause und Kontroll-Lesen nach jedem SET. Bricht beim ersten nicht antwortenden Geraet ab.
//   id14push [gapMS] [--wait-ready]
import Foundation

@main
struct ID14Push {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let gapMS = UInt32(args.first.flatMap { Int($0) } ?? 20)
        let waitReady = args.contains("--wait-ready")

        guard let state = StateStore.default.load() else { print("kein state.json"); exit(1) }
        let t = USBTransport()
        guard t.open() else { print("Geraet nicht gefunden"); exit(1) }
        defer { t.close() }

        if waitReady {
            // Bereitschaft: 5x hintereinander erfolgreich lesen
            var ok = 0, tries = 0
            while ok < 5 && tries < 100 {
                ok = t.getCur(ID14.Monitor.volume) != nil ? ok + 1 : 0
                tries += 1; usleep(100_000)
            }
            print("bereit nach \(tries) Versuchen")
        }

        let vol = t.getCur(ID14.Monitor.volume).map(DB.decode)
        print("Monitor vorher: \(vol.map { String($0) } ?? "?") dB")
        let plan = PushPlan.fullState(state, monitorVolumeDB: nil, phonesLevelDB: nil)
        let t0 = Date()
        for (i, cmd) in plan.enumerated() {
            let ok = t.set(cmd)
            usleep(gapMS * 1000)
            let alive = t.getCur(ID14.Monitor.volume) != nil
            if !ok || !alive {
                print(String(format: "ABBRUCH bei #%d %@  set=%@ alive=%@", i + 1, cmd.description, ok ? "ok" : "FEHLER", alive ? "ja" : "NEIN"))
                exit(2)
            }
        }
        print(String(format: "%d Befehle ok in %.2f s", plan.count, Date().timeIntervalSince(t0)))
    }
}
