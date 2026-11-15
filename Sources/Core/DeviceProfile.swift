// DeviceProfile.swift – unterstuetzte Audient-Modelle (Fakten aus der Original-iD-App, per Ghidra).
// ANNAHME (unbelegt): Die Unit-IDs, Controls und das Mixer-Layout (Protocol.swift, enum ID14) der anderen
// Modelle sind GLEICH denen des iD14 MkII. Weil das nicht verifiziert ist, laufen iD24/iD44 nur lesend
// (SupportLevel.unverified / .readOnlyBeta): Die App sendet dort KEIN SET (harter Schutz im USBWorker).
// Der iD4 MkII (PID 0x0009) wird bewusst NICHT unterstuetzt.
import Foundation

enum SupportLevel: Sendable {
    /// Am echten Geraet getestet: voller Funktionsumfang.
    case verified
    /// Wie das iD14 aufgebaut (2 Preamps, 1 Kopfhoerer-Mix), aber noch nicht am Geraet bestaetigt: nur lesen, nie ein SET.
    case unverified
    /// Abweichender Aufbau (4 Preamps, 2 Kopfhoerer), Mixer-Layout unbekannt: nur lesen, nie ein SET, minimale UI.
    case readOnlyBeta
}

struct DeviceProfile: Sendable, Equatable {
    let id: String
    let name: String
    let productID: UInt16
    /// Mikrofon-Vorverstaerker = Anzahl Eingangsmeter
    let preampCount: Int
    /// Unabhaengige Kopfhoerer-Ausgaenge (iD24: zwei Buchsen, aber ein Mix = 1)
    let headphoneCount: Int
    let opticalInputs: Int
    let supportLevel: SupportLevel
    /// Anzahl programmierbarer Funktionstasten (iD14: die eine iD-Taste; iD24/iD44: F1-F3)
    let functionKeyCount: Int
    /// Waehlbare Belegungen je Taste (Fakten aus der Original-iD-App)
    let functionKeyModes: [IDKeyFunction]
    /// Anzeigenamen der Tasten bei mehreren Tasten
    var functionKeyNames: [String] { functionKeyCount == 1 ? ["iD button"] : (1...functionKeyCount).map { "F\($0)" } }

    var allowsWrites: Bool { supportLevel == .verified }
    /// Kurzer Status fuer Panel und Settings ("unverified" / "beta"); nil = geprueft.
    var statusLabel: String? {
        switch supportLevel {
        case .verified: return nil
        case .unverified: return "unverified"
        case .readOnlyBeta: return "beta"
        }
    }
    /// Cue-Mix nur, wo das Layout dem iD14 entspricht (2 Eingaenge, 1 Kopfhoerer-Mix). iD44: ausgeblendet.
    var showsCueMix: Bool { preampCount == 2 && headphoneCount == 1 }

    static let id14mk2 = DeviceProfile(id: "id14mk2", name: "iD14 MkII", productID: 0x0008, preampCount: 2,
                                       headphoneCount: 1, opticalInputs: 1, supportLevel: .verified,
                                       functionKeyCount: 1,
                                       functionKeyModes: [.none, .mono, .cut, .dim, .talkback, .altSpeaker])
    static let id24 = DeviceProfile(id: "id24", name: "iD24", productID: 0x000D, preampCount: 2,
                                    headphoneCount: 1, opticalInputs: 1, supportLevel: .unverified,
                                    functionKeyCount: 3,
                                    functionKeyModes: [.none, .mono, .polarity, .talkback, .altSpeaker])
    static let id44 = DeviceProfile(id: "id44", name: "iD44", productID: 0x0005, preampCount: 4,
                                    headphoneCount: 2, opticalInputs: 2, supportLevel: .readOnlyBeta,
                                    functionKeyCount: 3, functionKeyModes: [.none, .mono, .polarity, .altSpeaker])
    static let id44mk2 = DeviceProfile(id: "id44mk2", name: "iD44 MkII", productID: 0x000B, preampCount: 4,
                                       headphoneCount: 2, opticalInputs: 2, supportLevel: .readOnlyBeta,
                                    functionKeyCount: 3, functionKeyModes: [.none, .mono, .polarity, .altSpeaker])

    /// Reihenfolge: iD14 zuerst (haeufigster Fall, Matching bleibt dort wie bisher).
    static let all: [DeviceProfile] = [.id14mk2, .id24, .id44, .id44mk2]

    static func forProductID(_ pid: UInt16) -> DeviceProfile? { all.first { $0.productID == pid } }
}
