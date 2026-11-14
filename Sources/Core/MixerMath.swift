// MixerMath.swift – Pan- und Send-Berechnung (P3). Offline, ohne Geraetezugriff.
import Foundation

enum MixerMath {
    /// Konstante aus iD MixerNode::calculatePanAttenuation
    static let panK = 0.004748821258544922

    /// Lineare L/R-Verstaerkung (0.0 = links, 1.0 = rechts), wie iD.
    static func panGains(_ p: Double) -> (left: Double, right: Double) {
        let left = (1 - p) * ((1 - p) * -panK + 1 + panK)
        let right = p * (p * -panK + 1 + panK)
        return (left, right)
    }

    /// Cue-Blend (Opus): Equal-Power-Ueberblendung Mikrofon <-> PC-Sound fuer gleichbleibende
    /// Gesamtlautstaerke (unkorrelierte Quellen: Leistungen addieren sich, cos^2 + sin^2 = 1).
    /// b = 0 -> nur Mikrofon, 0.5 -> beide -3,01 dB, 1 -> nur PC. Rueckgabe Fader-dB (-128 = aus).
    static func blendDB(_ b: Double) -> (mic: Double, pc: Double) {
        let x = min(max(b, 0), 1) * Double.pi / 2
        return (DB.fromGain(cos(x)), DB.fromGain(sin(x)))
    }

    /// Send-Pegel in dB fuer links und rechts. cut oder Pegel <= -128 ergibt -128.
    static func sendDB(_ send: MixSend, cut: Bool) -> (left: Double, right: Double) {
        if cut || send.volumeDB <= DB.minimum {
            return (DB.minimum, DB.minimum)
        }
        let gains = panGains(send.pan)
        let left = max(DB.minimum, send.volumeDB + DB.fromGain(gains.left))
        let right = max(DB.minimum, send.volumeDB + DB.fromGain(gains.right))
        return (left, right)
    }
}
