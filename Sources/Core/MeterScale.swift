// MeterScale.swift – IEC-60268-18-Skala fuer die Pegelanzeige (rein, ohne UI, testbar).
import Foundation

enum MeterScale {
    enum Zone: Equatable { case below, target, hot, danger }

    /// dB -> Anteil 0...1 der Skalenhoehe (stueckweise linear, in Prozent nach IEC 60268-18).
    static func fraction(_ db: Double) -> Double {
        guard db.isFinite else { return db > 0 ? 1 : 0 }
        let pct: Double
        switch db {
        case ..<(-70): pct = 0
        case -70..<(-60): pct = (db + 70) * 0.25
        case -60..<(-50): pct = (db + 60) * 0.5 + 2.5
        case -50..<(-40): pct = (db + 50) * 0.75 + 7.5
        case -40..<(-30): pct = (db + 40) * 1.5 + 15
        case -30..<(-20): pct = (db + 30) * 2 + 30
        default: pct = (db + 20) * 2.5 + 50      // -20...0 und darueber (begrenzt)
        }
        return min(max(pct / 100, 0), 1)
    }

    /// Untergrenze der Zielzone: RMS-Modus -18, PPM-Modus (Podcast) -12.
    static func targetFloor(ppm: Bool) -> Double { ppm ? -12 : -18 }

    /// Bezugsmarke: RMS-Modus -18, PPM-Modus -10 (BBC: normale Sprachspitzen ca. PPM 6 = -10 dBFS).
    static func marker(ppm: Bool) -> Double { ppm ? -10 : -18 }

    /// Zielzonen: unter Zielgrenze (-18, PPM -12) unter Ziel, bis -6 Ziel, -6...-3 heiss, > -3 Gefahr.
    static func zone(_ db: Double, ppm: Bool = false) -> Zone {
        if db < targetFloor(ppm: ppm) { return .below }
        if db < -6 { return .target }
        if db <= -3 { return .hot }
        return .danger
    }
}
