// main.swift – Offline-Tests (P3). Aufruf: offline-tests <Pfad zum Tests-Ordner>. Kein Geraetezugriff.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)\(detail.isEmpty ? "" : "\n      " + detail)")
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

let testsDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests")

// MARK: Golden-Zeilen parsen: "unit=0x34 cs=0x06 ch=0x00 data=[06]"
struct GoldenLine {
    let unit: UInt8
    let cs: UInt8
    let ch: UInt8
    let data: [UInt8]
    let raw: String
}

func parseGoldenLine(_ line: String) -> GoldenLine? {
    let halves = line.components(separatedBy: " data=[")
    guard halves.count == 2 else { return nil }
    var unit: UInt8 = 0, cs: UInt8 = 0, ch: UInt8 = 0
    for token in halves[0].split(separator: " ") {
        let kv = token.split(separator: "=")
        guard kv.count == 2, let v = UInt8(kv[1].dropFirst(2), radix: 16) else { return nil }
        switch kv[0] {
        case "unit": unit = v
        case "cs": cs = v
        case "ch": ch = v
        default: return nil
        }
    }
    var data: [UInt8] = []
    for h in halves[1].replacingOccurrences(of: "]", with: "").split(separator: " ") {
        guard let b = UInt8(h, radix: 16) else { return nil }
        data.append(b)
    }
    return GoldenLine(unit: unit, cs: cs, ch: ch, data: data, raw: line)
}

// MARK: 1. DB-Kodierung
check("DB.encode(-128) -> 00 80", DB.encode(-128) == [0x00, 0x80])
check("DB.encode(0) -> 00 00", DB.encode(0) == [0x00, 0x00])
check("DB.encode(-0.6) -> 67 ff", DB.encode(-0.6) == [0x67, 0xFF], "erzeugt: \(hex(DB.encode(-0.6)))")
check("DB.encode(-22.72728748626261) -> 46 e9",
      DB.encode(-22.72728748626261) == [0x46, 0xE9], "erzeugt: \(hex(DB.encode(-22.72728748626261)))")
check("DB.encode(+3) -> 00 00 (Begrenzung)", DB.encode(3) == [0x00, 0x00], "erzeugt: \(hex(DB.encode(3)))")
let decoded = DB.decode([0x46, 0xE9])
check("DB.decode(46 e9) ~ -22.7266", abs(decoded - (-22.7266)) < 0.001, "erzeugt: \(decoded)")

// MARK: 2. Golden-Test: Importierter Zustand -> PushPlan.fullState
let goldenURL = testsDir.appendingPathComponent("startup-golden.txt")
let refURL = testsDir.appendingPathComponent("state-referenz.xml")

if let goldenText = try? String(contentsOf: goldenURL, encoding: .utf8),
   let state = try? IDStateImporter.load(from: refURL) {
    let goldenLines = goldenText.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let parsed = goldenLines.compactMap(parseGoldenLine)
    check("Golden: alle \(goldenLines.count) Zeilen lesbar", parsed.count == goldenLines.count)

    let plan = PushPlan.fullState(state)
    var mismatches: [String] = []
    for g in parsed {
        let matches = plan.filter {
            $0.control.unit == g.unit && $0.control.cs == g.cs && $0.control.ch == g.ch
        }
        if matches.count == 1 && matches[0].data == g.data { continue }
        if matches.isEmpty {
            mismatches.append("erwartet: \(g.raw)\n        erzeugt: <kein Kommando>")
        } else {
            let got = matches.map { "data=[\(hex($0.data))]" }.joined(separator: ", ")
            mismatches.append("erwartet: \(g.raw)\n        erzeugt: \(got) (Anzahl \(matches.count))")
        }
    }
    check("Golden: jede Zeile genau einmal im Plan mit identischen Bytes", mismatches.isEmpty,
          mismatches.prefix(10).joined(separator: "\n      "))

    // Zusaetzliche Kommandos nur anzeigen (kein Fehler)
    let goldenKeys = Set(parsed.map { "\($0.unit)-\($0.cs)-\($0.ch)" })
    let extra = plan.filter { !goldenKeys.contains("\($0.control.unit)-\($0.control.cs)-\($0.control.ch)") }
    print("INFO  \(extra.count) zusaetzliche Kommandos im Plan (nicht im Golden):")
    for cmd in extra { print("      \(cmd)") }

    // Keine doppelten Controls im Plan
    let keys = plan.map { "\($0.control.unit)-\($0.control.cs)-\($0.control.ch)" }
    check("Plan enthaelt keine doppelten Controls", Set(keys).count == keys.count)
    check("Plan enthaelt 96 Mixer-Sends", plan.filter { $0.control.unit == 0x3C }.count == 96)

    // Stichproben der Importwerte
    check("Import: Eingang 10 heisst 'Computer'", state.inputs[10].name == "Computer")
    check("Import: Monitor dim-attenuation = -46 dB", state.monitor.dimAttenuationDB == -46)
    check("Import: Routing Monitor = 0x1B/0x1C", state.routeOut[0] == 0x1B && state.routeOut[1] == 0x1C)

    // Pan-Test: Mix-Send mit Pan 0 (links voll) liefert links 0 dB, rechts -128
    let (l, r) = MixerMath.sendDB(MixSend(volumeDB: 0, pan: 0), cut: false)
    check("MixerMath: Pan 0 -> links 0 dB, rechts -128 dB", abs(l) < 0.001 && r == DB.minimum)
} else {
    check("Golden: Dateien laden", false, "fehlt: \(goldenURL.path) oder \(refURL.path)")
}

// MARK: 3. ChangeNotification
let note = ChangeNotification(bytes: [0x12, 0, 0, 0x36])
check("ChangeNotification [12,0,0,36] -> unit 0x36, cs 0x12", note?.unit == 0x36 && note?.cs == 0x12)
check("ChangeNotification [ff,1,0,ff] -> nil", ChangeNotification(bytes: [0xFF, 1, 0, 0xFF]) == nil)

// MARK: 4. RecordingTransport verweigert nicht erlaubte Schreibvorgaenge
let rec = RecordingTransport()
let denied1 = rec.set(SetCommand(control: ID14.Control(unit: 0x37, cs: 1, ch: 0, length: 1), data: [0]))
let denied2 = rec.set(SetCommand(control: ID14.Control(unit: 0x0A, cs: 0x02, ch: 4, length: 2), data: [0, 0]))
let allowed = rec.set(SetCommand(control: ID14.Monitor.cut, data: [1]))
check("RecordingTransport verweigert Unit 0x37", !denied1)
check("RecordingTransport verweigert Unit 0x0A CS 0x02 Kanal 4", !denied2)
check("RecordingTransport akzeptiert Monitor.cut", allowed && rec.sent.count == 1)

// MARK: 5. StateStore: Roundtrip und Debounce
let tmpURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("id14-test-\(UUID().uuidString)/state.json")
let store = StateStore(url: tmpURL)
var original = DeviceState()
original.monitor.volumeDB = -33.5
original.inputs[10].name = "Testname"
original.mixOutputDB[2] = -4.25
check("StateStore: Laden ohne Datei -> nil", store.load() == nil)
let saved = store.save(original)
check("StateStore: Speichern + Laden ergibt gleichen Zustand",
      saved && store.load() == original)

var newer = original
newer.monitor.volumeDB = -20
store.scheduleSave(newer)
newer.monitor.volumeDB = -21
store.scheduleSave(newer)
Thread.sleep(forTimeInterval: 2.6)
check("StateStore: Debounce speichert letzte Version", store.load()?.monitor.volumeDB == -21)
try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())


// MARK: 6. Kopfhoerer-Lautstaerke (Opus-Nachtrag)
do {
    let ok = rec.set(SetCommand(control: ID14.phonesVolume(channel: 5), data: DB.encode(-40)))
    check("RecordingTransport erlaubt Kopfhoerer-Lautstaerke 0x0A Kanal 5", ok)
    var s = DeviceState()
    check("Kopfhoerer-Lautstaerke Default -40 dB", s.phonesVolumeDB == -40)
    s.phonesVolumeDB = -25
    let data = try! JSONEncoder().encode(s)
    var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    json.removeValue(forKey: "phonesVolumeStoredDB")
    let old = try! JSONDecoder().decode(DeviceState.self, from: JSONSerialization.data(withJSONObject: json))
    check("Alte state.json ohne Kopfhoerer-Feld laedt (Default -40)", old.phonesVolumeDB == -40)
    let plan = PushPlan.fullState(s, phonesVolumeDB: s.phonesVolumeDB)
    check("PushPlan haengt 0x0A Kanal 5/6 an", plan.suffix(2).map { $0.control } == [ID14.phonesVolume(channel: 5), ID14.phonesVolume(channel: 6)])
}

// MARK: 7. Cue-Blend Equal Power (Opus)
do {
    let c = MixerMath.blendDB(0.5)
    check("Blend Mitte: beide ca. -3,01 dB", abs(c.mic + 3.0103) < 0.01 && abs(c.pc + 3.0103) < 0.01)
    check("Blend 0: nur Mikrofon", MixerMath.blendDB(0).mic == 0 && MixerMath.blendDB(0).pc == DB.minimum)
    check("Blend 1: nur PC", MixerMath.blendDB(1).pc == 0 && MixerMath.blendDB(1).mic <= -100)
    let pw = stride(from: 0.0, through: 1.0, by: 0.1).map { b -> Double in
        let d = MixerMath.blendDB(b); return pow(10, d.mic / 10) + pow(10, d.pc / 10) }
    check("Blend: Gesamtleistung konstant (Abweichung < 0,01 dB)", pw.allSatisfy { abs(10 * log10($0)) < 0.01 })
    var s = DeviceState(); s.setCueBlend(mix: 1, 0.2)
    check("cueBlend speichert je Mix (Default 100 % PC)", s.cueBlend(mix: 1) == 0.2 && s.cueBlend(mix: 0) == 1.0)
}

MainActor.assumeIsolated { runMeterTests() }
MainActor.assumeIsolated { runRobustnessTests() }

// MARK: 8. Cue-Blend rastet an den Enden ein (Opus)
do {
    var s = DeviceState()
    s.setCueBlend(mix: 1, 0.97); check("Blend 97 % rastet auf 100 % PC", s.cueBlend(mix: 1) == 1)
    s.setCueBlend(mix: 1, 0.03); check("Blend 3 % rastet auf 0 % (nur Mic)", s.cueBlend(mix: 1) == 0)
    s.setCueBlend(mix: 1, 0.93); check("Blend 93 % bleibt 93 %", abs(s.cueBlend(mix: 1) - 0.93) < 1e-9)
    s.setCueBlend(mix: 1, .nan); check("Blend NaN -> Default 100 % PC", s.cueBlend(mix: 1) == 1)
}

// MARK: 9. Einstellungen: iD-Taste, Merken, Max-Schieber (Opus)
do {
    check("iD-Taste Aus = ff ff", IDKeyFunction.none.bytes == [0xFF, 0xFF])
    check("iD-Taste Dim = 05 00", IDKeyFunction.dim.bytes == [0x05, 0x00])
    check("iD-Taste Alt = 0c 00", IDKeyFunction.altSpeaker.bytes == [0x0C, 0x00])
    check("iD-Taste unbekannt -> Aus", IDKeyFunction(bytes: [0x11, 0x00]) == .none)
    var s = DeviceState(); s.monitor.functionKeyMode = [0x42, 0x00]
    check("sanitized: unbekannte iD-Belegung -> Aus", s.sanitized().monitor.idKey == .none)
    check("Standard Einblenden 0,3 s", DeviceState().restore.fadeSeconds == 0.3)
    check("Lautstaerke merken Standard an", DeviceState().restore.rememberVolume)
    s.restore.monitorCapDB = -45
    check("Max-Schieber wird auf -30 begrenzt", s.sanitized().restore.monitorCapDB == -30)
    s.restore.monitorCapDB = 0
    check("Max 0 dB = Aus", s.sanitized().restore.capIsOff)
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    check("VolumeStep -23,4 hoch -> -23", near(VolumeStep.next(current: -23.4, up: true, fine: false), -23))
    check("VolumeStep -23,4 runter -> -24", near(VolumeStep.next(current: -23.4, up: false, fine: false), -24))
    check("VolumeStep -23,0 hoch -> -22", near(VolumeStep.next(current: -23.0, up: true, fine: false), -22))
    check("VolumeStep fein -23,4 hoch -> -23,3", near(VolumeStep.next(current: -23.4, up: true, fine: true), -23.3))
    check("VolumeStep aus hoch -> -79", near(VolumeStep.next(current: -128, up: true, fine: false), -79))
    check("VolumeStep aus fein hoch -> -79,9", near(VolumeStep.next(current: -128, up: true, fine: true), -79.9))
    check("VolumeStep -80 runter -> aus", VolumeStep.next(current: -80, up: false, fine: false) == DB.minimum)
    check("VolumeStep -0,5 hoch -> 0", near(VolumeStep.next(current: -0.5, up: true, fine: false), 0))
    check("VolumeStep.fraction -128 -> 0", near(VolumeStep.fraction(-128), 0))
    check("VolumeStep.fraction -80 -> 0", near(VolumeStep.fraction(-80), 0))
    check("VolumeStep.fraction -40 -> 0,5", near(VolumeStep.fraction(-40), 0.5))
    check("VolumeStep.fraction 0 -> 1", near(VolumeStep.fraction(0), 1))
    check("VolumeStep.fraction +3 -> 1", near(VolumeStep.fraction(3), 1))
    check("VolumeStep 0 hoch bleibt 0", near(VolumeStep.next(current: 0, up: true, fine: false), 0))
    check("Lautstaerketasten Standard aus, Ziel Monitor",
          !DeviceState().ui.volumeKeys && DeviceState().ui.volumeKeysTarget == 0)
    var vk = DeviceState(); vk.ui.volumeKeysTargetStored = 5
    check("sanitized: Tasten-Ziel 5 -> nil", vk.sanitized().ui.volumeKeysTargetStored == nil)
}

print(failures == 0 ? "\nALLE TESTS PASS" : "\n\(failures) TEST(S) FEHLGESCHLAGEN")
exit(failures == 0 ? 0 : 1)
