// VolumeStep.swift – Schrittlogik fuer Lautstaerke per Taste/Scrollrad/Mac-Lautstaerketaste (rein, testbar).
import Foundation

enum VolumeStep {
    /// Anzeigeanteil 0...1 fuer −80...0 dB (HUD und Schieber). Aus/darunter = 0, ueber 0 dB = 1.
    static func fraction(_ dB: Double) -> Double {
        let off = DB.offThreshold
        return (max(off, min(0, dB)) - off) / -off
    }

    /// Naechster Wert: 1 dB, mit `fine` 0,1 dB. Ohne `fine` rastet der Wert auf ganze dB ein.
    /// Aus (<= DB.offThreshold): nach oben die erste hoerbare Stufe, nach unten bleibt es aus.
    /// Unter die Schwelle gerechnet ergibt DB.minimum, Obergrenze 0 dB.
    static func next(current value: Double, up: Bool, fine: Bool) -> Double {
        let off = DB.offThreshold
        if value <= off {
            return up ? off + (fine ? 0.1 : 1) : DB.minimum
        }
        let dir: Double = up ? 1 : -1
        let target: Double
        if fine {
            target = (value * 10).rounded() / 10 + dir * 0.1
        } else {
            target = up ? floor(value + 1e-6) + 1 : ceil(value - 1e-6) - 1
        }
        return target <= off ? DB.minimum : min(0, target)
    }
}
