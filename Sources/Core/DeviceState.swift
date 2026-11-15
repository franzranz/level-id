// DeviceState.swift – Fundament (Opus). Das komplette, persistierte Modell.
// Wird als JSON in ~/Library/Application Support/ID14Control/state.json gespeichert.
import Foundation

/// Ein Send eines Mixer-Eingangs in einen Mix (wie <mix> in iD state.xml)
struct MixSend: Codable, Equatable {
    var volumeDB: Double = DB.minimum
    /// 0.0 = links, 0.5 = Mitte, 1.0 = rechts
    var pan: Double = 0.5
}

struct InputChannel: Codable, Equatable, Identifiable {
    var id: Int                   // Mixer-Eingangsindex 0-15
    var name: String
    /// iD-Modus: 0 = mono, 1 = Stereo links (Partner = id+1), 2 = Stereo rechts, 3 = sonstiges
    var mode: Int = 0
    var cut: Bool = false         // Host-Logik: alle Sends -128 dB
    var solo: Bool = false        // Host-Logik (vorerst nicht im UI)
    var mixes: [MixSend] = Array(repeating: MixSend(), count: ID14.mixCount)
}

struct MonitorState: Codable, Equatable {
    var volumeDB: Double = DB.minimum        // Unit 0x36 CS 0x12 (Hardware-Regler)
    var dim: Bool = false
    var dimAttenuationDB: Double = -15.0
    var cut: Bool = false
    var mono: Bool = false
    var polarity: Bool = false
    var speakerSelect: UInt8 = 0             // 0 Main, 1 Alt
    var talkbackInput: UInt8 = 5
    var altMonTrimDB: Double = 0.0
    var functionKeyMode: [UInt8] = [0xFF, 0xFF]
    var phonesCut: Bool = false              // FU 0x0A Mute Kanal 5/6

    /// Belegung der iD-Taste (gespeichert als functionKeyMode-Bytes)
    var idKey: IDKeyFunction {
        get { IDKeyFunction(bytes: functionKeyMode) }
        set { functionKeyMode = newValue.bytes }
    }

    /// Talkback-Quelle (Opus). Optional fuer Kompatibilitaet; Standard Mic 1.
    var talkbackSourceStored: TalkbackSource?
    var talkbackSource: TalkbackSource {
        get { talkbackSourceStored ?? .mic1 }
        set { talkbackSourceStored = newValue }
    }
    /// Laufzeit: Talkback gerade aktiv (vom Geraet gemeldet, 0x36 CS 0x07). Wird mitgespeichert, aber beim
    /// Anstecken immer auf false gesetzt (PushPlan sendet Talkback aus).
    var talkback: Bool = false

    /// Was die iD-Taste in der Belegung "Stumm" stummschaltet: 0 Monitor, 1 beide, 2 nur Kopfhoerer.
    /// Optional fuer Kompatibilitaet mit aelteren state.json (fehlender Schluessel = Monitor).
    var muteTargetStored: UInt8?
    var muteTarget: MuteTarget {
        get { MuteTarget(rawValue: muteTargetStored ?? 0) ?? .monitor }
        set { muteTargetStored = newValue.rawValue }
    }
    /// Braucht die iD-Taste schnelles Notify-Polling (100 ms)? Talkback, oder Stumm mit Kopfhoerer-Beteiligung.
    var needsFastNotify: Bool { idKey == .talkback || (idKey == .cut && muteTarget != .monitor) }

    /// Veraltet (Mix-Regler wurde entfernt): nur noch fuer alte state.json lesbar, ohne Wirkung.
    /// sanitized() setzt beide auf nil.
    var idKeyMixKnobStored: Bool?
    var mixKnobTargetStored: Int?

    /// Was der Nutzer fuer die iD-Taste gewaehlt hat (UI-Sicht)
    var idKeyChoice: IDKeyChoice { IDKeyChoice(device: idKey) }
}

/// Ziel der iD-Taste in der Belegung "Stumm".
enum MuteTarget: UInt8, CaseIterable {
    case monitor = 0, both = 1, headphones = 2
}

/// Auswahl der iD-Taste im UI: Geraetefunktionen plus App-Funktion Mix-Regler.
enum IDKeyChoice: String, CaseIterable, Codable {
    case none, cut, dim, mono, altSpeaker, talkback, mixKnob
    /// Im UI waehlbar (Nutzerwunsch: Dim entfernt, weil der Modus am Geraet nicht erkennbar ist)
    static let selectable: [IDKeyChoice] = [.none, .cut, .mono, .altSpeaker, .talkback]
    init(device f: IDKeyFunction) {
        switch f {
        case .none: self = .none
        case .cut: self = .cut
        case .dim: self = .dim
        case .mono: self = .mono
        case .altSpeaker: self = .altSpeaker
        case .talkback: self = .talkback
        }
    }
    /// Geraetebelegung, die gesendet wird (Mix-Regler: Taste im Geraet auf Aus, das ScrollControl liefert Wheel-Ereignisse)
    var deviceFunction: IDKeyFunction {
        switch self {
        case .none: return .none
        case .cut: return .cut
        case .dim: return .dim
        case .mono: return .mono
        case .mixKnob: return .none
        case .altSpeaker: return .altSpeaker
        case .talkback: return .talkback
        }
    }
    var title: String {
        self == .mixKnob ? "Mix knob" : deviceFunction == .none && self == .none ? "Off" : IDKeyFunction(choice: self).title
    }
}

private extension IDKeyFunction {
    init(choice: IDKeyChoice) { self = choice.deviceFunction }
}

/// Talkback-Mikrofon (Nutzerwunsch). Firmware mischt NICHT selbst (live getestet 2026-11-12):
/// Mic 1/2 -> die App hebt waehrend Talkback die Sends dieser Eingaenge NUR im Kopfhoerer-Mix (Mix 1) auf 0 dB.
/// Mac   -> die App leitet das eingebaute Mac-Mikrofon auf DAW 6 (Mixer-Eingang 15), das nur im
///          Kopfhoerer-Mix liegt (wie iD "External Talkback"); Audio-Bruecke laeuft nur waehrend Talkback.
enum TalkbackSource: String, Codable, CaseIterable {
    case mic1, mic2, both, mac
    var title: String {
        switch self {
        case .mic1: return "Mic 1"
        case .mic2: return "Mic 2"
        case .both: return "Mic 1 + 2"
        case .mac: return "Mac microphone"
        }
    }
    /// Mixer-Eingaenge, deren Kopfhoerer-Send waehrend Talkback angehoben wird
    var mixerInputs: [Int] {
        switch self {
        case .mic1: return [ID14.Input.mic1]
        case .mic2: return [ID14.Input.mic2]
        case .both: return [ID14.Input.mic1, ID14.Input.mic2]
        case .mac: return [ID14.Input.daw6]
        }
    }
}

struct RestorePreferences: Codable, Equatable {
    /// Obergrenze fuer die wiederhergestellte Lautstaerke (-30...0, Standard -25). 0 = "Aus" (keine Begrenzung).
    var monitorCapDB: Double = -25.0
    /// Dauer des Einblendens (Nutzerwunsch: Standard 0,3 s)
    var fadeSeconds: Double = 0.3
    /// Kopfhoerer ebenfalls begrenzen
    var capPhonesToo: Bool = true
    /// "Lautstaerke merken". Aus = nach dem Einstecken starten Monitor und Kopfhoerer stumm.
    /// Optional fuer Kompatibilitaet mit aelteren state.json (fehlender Schluessel = an).
    var rememberVolumeStored: Bool?
    var rememberVolume: Bool {
        get { rememberVolumeStored ?? true }
        set { rememberVolumeStored = newValue }
    }
    /// Bereich des Max-Schiebers
    static let capRange: ClosedRange<Double> = -30...0
    var capIsOff: Bool { monitorCapDB >= 0 }
}

/// Belegung der iD-Taste am ID14 MkII (Unit 0x36, CS 0x10, Kanal 0, int16 LE).
/// Werte = CS-Nummer der jeweiligen Monitor-Funktion (aus iD MonitorControllerModel::functionKeyModeToString).
enum IDKeyFunction: Int16, CaseIterable, Codable {
    case none = -1, mono = 0x00, cut = 0x04, dim = 0x05, talkback = 0x07, altSpeaker = 0x0C

    var bytes: [UInt8] {
        let u = UInt16(bitPattern: rawValue)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }
    init(bytes: [UInt8]) {
        guard bytes.count >= 2 else { self = .none; return }
        let v = Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        self = IDKeyFunction(rawValue: v) ?? .none
    }
    var title: String {
        switch self {
        case .none: return "Off"
        case .cut: return "Mute"
        case .dim: return "Dim"
        case .mono: return "Mono"
        case .altSpeaker: return "Alt speakers"
        case .talkback: return "Talkback"
        }
    }
}

struct UIPreferences: Codable, Equatable {
    /// Menueleisten-Symbol ausblenden, solange kein ID14 verbunden ist. Standard: aus (Symbol immer sichtbar).
    /// Optional fuer Kompatibilitaet mit aelteren state.json (fehlender Schluessel = aus).
    var hideIconWhenDisconnectedStored: Bool?
    var hideIconWhenDisconnected: Bool {
        get { hideIconWhenDisconnectedStored ?? false }
        set { hideIconWhenDisconnectedStored = newValue }
    }
    /// Mac-Lautstaerketasten steuern das ID14. Standard: aus (kein Event-Tap, keine Berechtigungsabfrage).
    var volumeKeysStored: Bool?
    var volumeKeys: Bool {
        get { volumeKeysStored ?? false }
        set { volumeKeysStored = newValue }
    }
    /// Ziel der Lautstaerketasten: 0 = Monitor, 1 = Kopfhoerer. Standard: Monitor.
    var volumeKeysTargetStored: UInt8?
    var volumeKeysTarget: UInt8 {
        get { volumeKeysTargetStored ?? 0 }
        set { volumeKeysTargetStored = newValue }
    }
    /// Im Cue-Mix sichtbare Eingaenge (Nutzerwunsch: Mic 1, Mic 2, DAW 1/2)
    var visibleInputs: [Int] = [ID14.Input.mic1, ID14.Input.mic2, ID14.Input.daw1]
    /// Schrittweite fuer Lautstaerke per Pfeiltaste/Mausrad
    var volumeStepDB: Double = 0.5
    var fineStepDB: Double = 0.1
}

struct DeviceState: Codable, Equatable {
    var schemaVersion = 1
    var inputs: [InputChannel] = (0..<ID14.mixerInputs).map { InputChannel(id: $0, name: "In \($0 + 1)") }
    var inputPolarity: [Bool] = [false, false]          // Mic 1, Mic 2
    /// Ausgangspegel der Mixe, FU 0x0C Kanal 1-6 (Index 0 = Kanal 1). Kanal 3/4 = Kopfhoerer.
    var mixOutputDB: [Double] = [DB.minimum, DB.minimum, 0, 0, 0, 0]
    var monitor = MonitorState()
    /// Routing-Quellen (rohe Bytes wie von iD gesendet)
    var routeHost: [UInt8] = [0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x00, 0x01]
    var routeOut: [UInt8] = [0x1B, 0x1C, 0x1D, 0x1E, 0x14, 0x15]
    var opticalInputMode: [UInt8] = [0, 0, 0, 0]
    var restore = RestorePreferences()
    var ui = UIPreferences()

    /// Cue-Blend Mikrofon <-> PC-Sound je Mix (Index 0 = Monitore, 1 = Kopfhoerer), 0...1.
    /// Optional fuer Kompatibilitaet mit aelteren state.json; Default 1.0 (= 100 % PC, Nutzerwunsch).
    var cueBlendStored: [Double]?
    static let cueBlendDefault: Double = 1.0
    func cueBlend(mix: Int) -> Double {
        guard let b = cueBlendStored, b.indices.contains(mix) else { return Self.cueBlendDefault }
        return b[mix]
    }
    mutating func setCueBlend(mix: Int, _ v: Double) {
        guard (0...1).contains(mix) else { return }
        var b = cueBlendStored ?? [Self.cueBlendDefault, Self.cueBlendDefault]
        while b.count <= mix { b.append(Self.cueBlendDefault) }
        b[mix] = Self.snapBlend(v)
        cueBlendStored = b
    }

    /// Einrastzone an den Enden (Nutzerwunsch): innerhalb 4 % vor 0 % bzw. 100 % auf exakt 0/1.
    static let cueBlendSnap: Double = 0.04
    static func snapBlend(_ v: Double) -> Double {
        guard v.isFinite else { return cueBlendDefault }
        let c = min(max(v, 0), 1)
        if c >= 1 - cueBlendSnap { return 1 }
        if c <= cueBlendSnap { return 0 }
        return c
    }

    /// Echte Kopfhoerer-Lautstaerke (FU 0x0A Kanal 5/6, dieselbe Stufe wie der Geraeteregler).
    /// Optional, damit aeltere state.json ohne dieses Feld weiter geladen werden. nil = noch nie gesetzt.
    var phonesVolumeStoredDB: Double?
    static let phonesVolumeDefaultDB: Double = -40.0
    var phonesVolumeDB: Double {
        get { phonesVolumeStoredDB ?? Self.phonesVolumeDefaultDB }
        set { phonesVolumeStoredDB = newValue }
    }

    /// Kopfhoerer-MIX-Ausgang (FU 0x0C Kanal 3/4). Im UI nicht mehr als Hauptregler, fest gespeichert.
    var phonesLevelDB: Double {
        get { mixOutputDB.indices.contains(2) ? mixOutputDB[2] : 0 }
        set {
            guard mixOutputDB.count >= 4 else { return }
            mixOutputDB[2] = newValue; mixOutputDB[3] = newValue
        }
    }
}

// MARK: - Validierung (Opus, Zuverlaessigkeit)

extension DeviceState {
    /// Erzwingt alle Laengen und Wertebereiche, die PushPlan/Controller voraussetzen.
    /// Danach kann kein Index-Zugriff mehr ausserhalb liegen und kein NaN/Inf ans Geraet gehen.
    func sanitized() -> DeviceState {
        let d = DeviceState()          // Referenz fuer Defaults
        var s = self

        func dbv(_ v: Double, _ lo: Double = DB.minimum, _ hi: Double = 6, def: Double) -> Double {
            v.isFinite ? min(max(v, lo), hi) : def
        }
        func unit(_ v: Double, _ def: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : def }
        func fixed<T>(_ a: [T], _ def: [T]) -> [T] {
            a.count == def.count ? a : Array((a + def.dropFirst(min(a.count, def.count))).prefix(def.count))
        }

        // Eingaenge: genau 16, IDs 0-15, je 3 Mixes
        var ins = d.inputs
        for i in ins.indices {
            if let src = s.inputs.first(where: { $0.id == i }) ?? (s.inputs.indices.contains(i) ? s.inputs[i] : nil) {
                var c = src
                c.id = i
                if !(0...3).contains(c.mode) { c.mode = 0 }
                c.mixes = fixed(c.mixes, d.inputs[i].mixes).map {
                    MixSend(volumeDB: dbv($0.volumeDB, def: DB.minimum), pan: unit($0.pan, 0.5))
                }
                ins[i] = c
            }
        }
        s.inputs = ins
        s.inputPolarity = fixed(s.inputPolarity, d.inputPolarity)
        s.mixOutputDB = fixed(s.mixOutputDB, d.mixOutputDB).map { dbv($0, DB.minimum, 0, def: 0) }
        s.routeHost = fixed(s.routeHost, d.routeHost)
        s.routeOut = fixed(s.routeOut, d.routeOut)
        s.opticalInputMode = fixed(s.opticalInputMode, d.opticalInputMode)

        if let t = s.ui.volumeKeysTargetStored, t > 1 { s.ui.volumeKeysTargetStored = nil }

        var m = s.monitor
        m.volumeDB = dbv(m.volumeDB, DB.minimum, 0, def: DB.minimum)
        m.dimAttenuationDB = dbv(m.dimAttenuationDB, DB.minimum, 0, def: d.monitor.dimAttenuationDB)
        m.altMonTrimDB = dbv(m.altMonTrimDB, -24, 24, def: 0)
        if m.speakerSelect > 1 { m.speakerSelect = 0 }
        if let t = m.muteTargetStored, t > 2 { m.muteTargetStored = nil }
        m.functionKeyMode = fixed(m.functionKeyMode, d.monitor.functionKeyMode)
        m.functionKeyMode = IDKeyFunction(bytes: m.functionKeyMode).bytes   // unbekannte Werte -> Aus
        // Mix-Regler entfernt: alte Wahl ohne Wirkung, die Geraetetaste faellt auf "Aus" zurueck
        if m.idKeyMixKnobStored == true { m.idKey = .none }
        m.idKeyMixKnobStored = nil
        m.mixKnobTargetStored = nil
        s.monitor = m

        s.restore.monitorCapDB = dbv(s.restore.monitorCapDB, RestorePreferences.capRange.lowerBound,
                                     RestorePreferences.capRange.upperBound, def: d.restore.monitorCapDB)
        s.restore.fadeSeconds = s.restore.fadeSeconds.isFinite ? min(max(s.restore.fadeSeconds, 0), 3) : d.restore.fadeSeconds
        s.ui.volumeStepDB = s.ui.volumeStepDB.isFinite ? min(max(s.ui.volumeStepDB, 0.1), 6) : d.ui.volumeStepDB
        s.ui.fineStepDB = s.ui.fineStepDB.isFinite ? min(max(s.ui.fineStepDB, 0.02), 6) : d.ui.fineStepDB
        s.ui.visibleInputs = s.ui.visibleInputs.filter { (0..<ID14.mixerInputs).contains($0) }

        if let b = s.cueBlendStored { s.cueBlendStored = Array(b.prefix(2)).map { unit($0, Self.cueBlendDefault) } }
        if let p = s.phonesVolumeStoredDB { s.phonesVolumeStoredDB = dbv(p, DB.minimum, 0, def: Self.phonesVolumeDefaultDB) }
        return s
    }
}

// MARK: - Schnittstellen zwischen den Paketen

/// Ein einzelner Schreibbefehl.
struct SetCommand: Equatable, CustomStringConvertible {
    let control: ID14.Control
    let data: [UInt8]
    var description: String { "\(control) data=[\(data.map { String(format: "%02x", $0) }.joined(separator: " "))]" }
}

/// Transport zum Geraet. Echte Implementierung: USBTransport (CUSB). Test: RecordingTransport.
/// Alle Methoden sind blockierend und werden NUR auf der seriellen Queue des DeviceController aufgerufen.
protocol DeviceTransport: AnyObject {
    var isOpen: Bool { get }
    func open() -> Bool
    func close()
    /// GET (CUR/RANGE/MEM). Rueckgabe nil bei Fehler.
    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]?
    /// SET_CUR. MUSS ID14.isWritable pruefen und andernfalls false liefern, ohne zu senden.
    func set(_ command: SetCommand) -> Bool
}

extension DeviceTransport {
    func getCur(_ c: ID14.Control) -> [UInt8]? { get(.cur, unit: c.unit, wValue: c.wValue, length: c.length) }
}
