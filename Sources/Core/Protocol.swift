// Protocol.swift – Fundament (Opus). Alle Geraete-Konstanten und Kodierungen an EINER Stelle.
// Quelle: docs/PROTOCOL.md. Aenderungen hier nur nach Abgleich mit der Protokoll-Doku.
import Foundation

enum ID14 {
    static let vendorID: UInt16 = 0x2708
    static let productID: UInt16 = 0x0008
    /// Bundle-ID der Original-App. Laeuft sie, schreibt unsere App nichts ans Geraet.
    static let originalAppBundleID = "com.audient.id"

    // UAC2-Requests (Interface 0, Endpoint 0)
    enum Request: UInt8 {
        case cur = 0x01    // GET_CUR / SET_CUR
        case range = 0x02  // nur GET
        case mem = 0x03    // nur GET (Meter)
    }

    enum Unit: UInt8 {
        case system = 0x01        // optischer Eingangsmodus
        case phonesFU = 0x0A      // Kopfhoerer-Feature-Unit (Mute = Kopfhoerer-Cut)
        case inputFU = 0x0B       // Eingaenge: Polaritaet
        case mixOutFU = 0x0C      // Ausgangspegel der Mixe, Kanal 1-6
        case routeOut = 0x33      // Routing physische Ausgaenge
        case routeHost = 0x34     // Routing USB-Eingaenge zum Mac
        case monitor = 0x36       // Audient Monitor-Controller (XU)
        case mixer = 0x3C         // Mixer-Unit 16 x 6
        case notify = 0x3E        // Aenderungsmeldungen
    }

    /// Adresse eines Controls: wValue = cs<<8 | ch, wIndex = unit<<8 | 0
    struct Control: Hashable, CustomStringConvertible {
        let unit: UInt8
        let cs: UInt8
        let ch: UInt8
        /// Datenlaenge in Bytes fuer GET/SET_CUR
        let length: Int
        var wValue: UInt16 { UInt16(cs) << 8 | UInt16(ch) }
        var wIndex: UInt16 { UInt16(unit) << 8 }
        var description: String { String(format: "unit=0x%02x cs=0x%02x ch=0x%02x", unit, cs, ch) }
    }

    // MARK: Monitor-Controller (Unit 0x36)
    enum Monitor {
        static let mono          = Control(unit: 0x36, cs: 0x00, ch: 0, length: 1)
        static let polarity      = Control(unit: 0x36, cs: 0x03, ch: 0, length: 1)
        static let cut           = Control(unit: 0x36, cs: 0x04, ch: 0, length: 1)
        static let dim           = Control(unit: 0x36, cs: 0x05, ch: 0, length: 1)
        static let dimAttenuation = Control(unit: 0x36, cs: 0x06, ch: 0, length: 2) // dB
        static let talkback      = Control(unit: 0x36, cs: 0x07, ch: 0, length: 1)
        static let talkbackInput = Control(unit: 0x36, cs: 0x08, ch: 0, length: 1)
        static let speakerSelect = Control(unit: 0x36, cs: 0x0C, ch: 0, length: 1) // 0 Main, 1 Alt
        static let functionKeys  = Control(unit: 0x36, cs: 0x10, ch: 0, length: 2)
        static let volume        = Control(unit: 0x36, cs: 0x12, ch: 0, length: 2) // dB, Hardware-Regler
        static let altMonTrim    = Control(unit: 0x36, cs: 0x17, ch: 1, length: 2) // dB
    }

    // MARK: Mixer-Ausgaenge (FU 0x0C, CS 0x02 Volume), Kanal 1-6
    static func mixOutputVolume(channel: UInt8) -> Control { Control(unit: 0x0C, cs: 0x02, ch: channel, length: 2) }
    /// Kopfhoerer-Mixausgang (Mix 2 = Mixer-Ausgaenge 2/3 = FU-Kanal 3/4)
    static let phonesLevelChannels: [UInt8] = [3, 4]

    // MARK: Kopfhoerer-Cut (FU 0x0A, CS 0x01 Mute, Kanal 5/6)
    static func phonesMute(channel: UInt8) -> Control { Control(unit: 0x0A, cs: 0x01, ch: channel, length: 1) }
    static let phonesMuteChannels: [UInt8] = [5, 6]

    // MARK: Kopfhoerer-Lautstaerke (FU 0x0A, CS 0x02, Kanal 5/6) – wie iD setHeadphoneVolume.
    // Der Geraeteregler (Kopfhoerer-Modus) wirkt auf dieselbe Stufe, meldet aber nur "geaendert"
    // (Notify cs 0x02, Kanal 0-basiert 4/5). Der Wert ist per GET NICHT lesbar (liefert letzten Host-Wert).
    static func phonesVolume(channel: UInt8) -> Control { Control(unit: 0x0A, cs: 0x02, ch: channel, length: 2) }
    static let phonesVolumeChannels: [UInt8] = [5, 6]

    // MARK: Eingaenge (FU 0x0B, CS 0x0D Phase Inverter), Kanal 1 = Mic 1, 2 = Mic 2
    static func inputPolarity(mic: Int) -> Control { Control(unit: 0x0B, cs: 0x0D, ch: UInt8(mic), length: 1) }

    // MARK: Mixer (Unit 0x3C, CS 0x01), Kanal = Eingang*6 + Ausgang
    static let mixerInputs = 16
    static let mixerOutputs = 6
    /// Kein precondition mehr (Zuverlaessigkeit): Werte werden begrenzt. Aufrufer arbeiten ohnehin
    /// nur mit sanitized()-Zustand (16 Eingaenge, 6 Ausgaenge).
    static func mixerSend(input: Int, output: Int) -> Control {
        let i = min(max(input, 0), mixerInputs - 1)
        let o = min(max(output, 0), mixerOutputs - 1)
        return Control(unit: 0x3C, cs: 0x01, ch: UInt8(i * mixerOutputs + o), length: 2)
    }

    // MARK: Routing (CS 0x06, Kanal = Ziel, 1 Byte = Quelle)
    static func routeHost(channel: UInt8) -> Control { Control(unit: 0x34, cs: 0x06, ch: channel, length: 1) }
    static func routeOut(channel: UInt8) -> Control { Control(unit: 0x33, cs: 0x06, ch: channel, length: 1) }
    static let opticalInputMode = Control(unit: 0x01, cs: 0x00, ch: 0, length: 4)

    // MARK: Meldungen & Meter
    static let notify = Control(unit: 0x3E, cs: 0x06, ch: 0, length: 4)
    /// GET_MEM auf Unit 0x3C: wValue 0 = 16 Eingangs-Meter (uint16 LE), wValue 1 = 6 Ausgangs-Meter
    static let meterInputsOffset: UInt16 = 0x0000
    static let meterInputsLength = 32
    static let meterOutputsOffset: UInt16 = 0x0001
    static let meterOutputsLength = 12

    // MARK: Mixer-Eingangsindizes (aus iD state.xml)
    enum Input {
        static let mic1 = 0, mic2 = 1
        static let digital = 2...9
        static let daw1 = 10, daw2 = 11
        static let daw3 = 12, daw4 = 13
        static let daw5 = 14, daw6 = 15
    }
    /// Mixe: 0 = Monitore (Ausg. 0/1), 1 = Kopfhoerer (Ausg. 2/3), 2 = Cue (Ausg. 4/5)
    static let mixCount = 3

    // MARK: Sicherheits-Whitelist fuer SET_CUR
    /// Nur Controls, die iD nachweislich selbst so setzt. Alles andere verweigert der Transport.
    static func isWritable(_ c: Control) -> Bool {
        switch c.unit {
        case 0x36: return [0x00, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0C, 0x10, 0x12, 0x15, 0x17].contains(c.cs)
        case 0x0C: return c.cs == 0x02 && (1...6).contains(c.ch)
        case 0x0A: return (c.cs == 0x01 || c.cs == 0x02) && phonesMuteChannels.contains(c.ch)
        case 0x0B: return c.cs == 0x0D && (1...2).contains(c.ch)
        case 0x3C: return c.cs == 0x01 && Int(c.ch) < mixerInputs * mixerOutputs
        case 0x33: return c.cs == 0x06 && c.ch < 6
        case 0x34: return c.cs == 0x06 && c.ch < 12
        case 0x01: return c.cs == 0x00 && c.ch == 0
        default: return false
        }
    }
}

// MARK: - Kodierungen

enum DB {
    static let minimum: Double = -128.0
    /// Ab diesem Wert gilt ein Pegel in der Bedienung als „aus“ (UI: offThresholdDB)
    static let offThreshold: Double = -80.0

    /// dB -> int16 LE in 1/256 dB. Begrenzt auf [-128, maxDB]. <= -128 ergibt 0x8000.
    /// Abschneiden Richtung 0 (wie iD, verifiziert: -0.6 dB -> 0xFF67).
    static func encode(_ db: Double, maxDB: Double = 0.0) -> [UInt8] {
        let clamped = min(max(db, minimum), maxDB)
        let raw: Int16 = clamped <= minimum ? Int16.min : Int16(clamping: Int(clamped * 256.0))
        let u = UInt16(bitPattern: raw)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    static func decode(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 2 else { return minimum }
        let raw = Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        return raw == Int16.min ? minimum : Double(raw) / 256.0
    }

    /// Meterwert (uint16) -> dB, wie DecibelConversions::meterIntToDB in iD.
    static func meter(_ v: UInt16) -> Double {
        guard v > 0 else { return minimum }
        return max(minimum, 20.0 * log10(Double(v) / 65535.0))
    }

    /// Lineare Verstaerkung -> dB (0 -> -128)
    static func fromGain(_ g: Double) -> Double { g <= 0 ? minimum : max(minimum, 20.0 * log10(g)) }
}

/// Eine Aenderungsmeldung von Unit 0x3E: Bytes [cs, kanal(0-basiert), 00, unit]
struct ChangeNotification: Equatable {
    let unit: UInt8
    let cs: UInt8
    let channelZeroBased: UInt8

    init?(bytes: [UInt8]) {
        guard bytes.count == 4, bytes[0] != 0xFF, bytes[3] != 0xFF else { return nil }
        cs = bytes[0]; channelZeroBased = bytes[1]; unit = bytes[3]
    }
}
