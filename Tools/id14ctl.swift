// id14ctl – Diagnose-CLI, NUR LESEND (GET-Requests). Sendet nie ans Geraet.
//   id14ctl status | meters | plan
import Foundation

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func fmt(_ db: Double) -> String { String(format: "%7.2f dB", db) }

func openTransport() -> USBTransport {
    let t = USBTransport()
    guard t.open() else { fail("ID14 MkII nicht gefunden oder nicht zu öffnen") }
    return t
}

func readByte(_ t: USBTransport, _ c: ID14.Control) -> String {
    guard let b = t.getCur(c), let v = b.first else { return "?" }
    return String(v)
}

func readDB(_ t: USBTransport, _ c: ID14.Control) -> String {
    guard let b = t.getCur(c), b.count >= 2 else { return "     ?    " }
    return fmt(DB.decode(b))
}

func runStatus() {
    let t = openTransport()
    defer { t.close() }
    print("Monitor-Lautstärke: \(readDB(t, ID14.Monitor.volume))")
    for ch in 1...6 {
        print("FU 0x0C Kanal \(ch):   \(readDB(t, ID14.mixOutputVolume(channel: UInt8(ch))))")
    }
    print("Dim:     \(readByte(t, ID14.Monitor.dim))")
    print("Cut:     \(readByte(t, ID14.Monitor.cut))")
    print("Mono:    \(readByte(t, ID14.Monitor.mono))")
    print("Speaker: \(readByte(t, ID14.Monitor.speakerSelect)) (0 Main, 1 Alt)")
    if let n = t.getCur(ID14.notify) {
        print("Notify:  \(hex(n))")
    } else {
        print("Notify:  ?")
    }
}

func runMeters() {
    let t = openTransport()
    defer { t.close() }
    let start = Date()
    var peak = [DB.minimum, DB.minimum]
    var lastPrint = Date.distantPast
    while Date().timeIntervalSince(start) < 3.0 {
        if let b = t.get(.mem, unit: ID14.Unit.mixer.rawValue, wValue: ID14.meterInputsOffset,
                         length: ID14.meterInputsLength), b.count >= 4 {
            let v = (0..<2).map { DB.meter(UInt16(b[$0 * 2]) | UInt16(b[$0 * 2 + 1]) << 8) }
            for i in 0..<2 { peak[i] = max(peak[i], v[i]) }
            if Date().timeIntervalSince(lastPrint) >= 0.2 {
                print(String(format: "Mic 1 %7.1f dB   Mic 2 %7.1f dB", v[0], v[1]))
                lastPrint = Date()
            }
        } else {
            print("Meter-Lesefehler")
        }
        usleep(66_000)
    }
    print(String(format: "Peak: Mic 1 %.1f dB, Mic 2 %.1f dB", peak[0], peak[1]))
}

/// Liest alle 96 Mixer-Sends (nur GET). Zeigt, ob das Geraet sie liefert und welche nicht auf -128 dB stehen.
func runSends() {
    let t = openTransport()
    defer { t.close() }
    var silent = 0, loud = 0, failed = 0
    for i in 0..<ID14.mixerInputs {
        var row: [String] = []
        for o in 0..<6 {
            guard let b = t.getCur(ID14.mixerSend(input: i, output: o)), b.count >= 2 else { failed += 1; row.append("  ?  "); continue }
            let v = DB.decode(b)
            if v <= DB.minimum + 0.01 { silent += 1; row.append(" off ") } else { loud += 1; row.append(String(format: "%5.1f", v)) }
        }
        print(String(format: "In %2d: ", i) + row.joined(separator: " "))
    }
    print("stumm \(silent), nicht stumm \(loud), nicht lesbar \(failed)")
}

/// Nur lesend: vergleicht den Push-Plan aus dem App-Zustand mit den Geraetewerten.
func runDiff() {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ID14Control/state.json")
    guard let s = StateStore(url: url).load() else { fail("state.json nicht lesbar") }
    let plan = PushPlan.fullState(s)
    let t = openTransport()
    defer { t.close() }
    var diff = 0
    for c in plan {
        let b = t.getCur(c.control)
        if b != c.data {
            diff += 1
            let got = b.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil"
            print("\(c.description)  geraet=[\(got)]")
        }
    }
    print("\(diff) von \(plan.count) abweichend (nur gelesen, nichts gesendet)")
}

func runPlan() {
    do {
        let state = try IDStateImporter.load(from: IDStateImporter.defaultURL)
        let plan = PushPlan.fullState(state)
        for (i, c) in plan.enumerated() { print(String(format: "%3d  ", i + 1) + c.description) }
        print("\(plan.count) Kommandos (nur angezeigt, nichts gesendet)")
    } catch {
        fail("state.xml konnte nicht importiert werden: \(error)")
    }
}

// Top-Level-Code ist in swiftc nur in main.swift erlaubt (build.sh probe uebergibt mehrere Dateien), daher @main.
@main
struct ID14Ctl {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "status": runStatus()
        case "meters": runMeters()
        case "plan": runPlan()
        case "sends": runSends()
        case "diff": runDiff()
        default: fail("Aufruf: id14ctl status | meters | plan | sends", 2)
        }
    }
}
