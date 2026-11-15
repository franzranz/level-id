// MeterModel.swift – Eingangsmeter als eigenes Objekt. Nur die Meter-Ansicht beobachtet es,
// damit Pegelaenderungen nicht das ganze Panel neu rendern.
import Foundation

@MainActor
final class MeterModel: ObservableObject {
    struct Channel: Equatable {
        /// Spitze laut Geraet (letzter Messwert)
        var levelDB: Double
        /// Effektivwert: exponentieller Mittelwert der Leistung, tau = 300 ms
        var rmsDB: Double
        /// Hoechste Spitze seit dem letzten Reset (fuer die Zahl)
        var maxPeakDB: Double
        /// Uptime-Sekunden des letzten Clips (>= -0,1 dBFS); die UI blendet die LED darueber aus
        var lastClipAt: TimeInterval?
    }

    /// Genau 2 Eintraege: Mic 1, Mic 2
    @Published private(set) var mics: [Channel]
    /// true, solange Messwerte eintreffen (steuert in der UI den 30-fps-Zeichentakt)
    @Published private(set) var live = false

    private static let silent = Channel(levelDB: DB.minimum, rmsDB: DB.minimum, maxPeakDB: DB.minimum, lastClipAt: nil)
    static let rmsTau = 0.300
    static let clipThresholdDB = -0.1
    nonisolated static let clipFadeSeconds = 2.0

    /// LED-Helligkeit 1 -> 0, linear ueber 2 s nach dem letzten Clip.
    nonisolated static func clipOpacity(lastClipAt: TimeInterval?, now: TimeInterval) -> Double {
        guard let t = lastClipAt else { return 0 }
        return min(1, max(0, 1 - (now - t) / clipFadeSeconds))
    }

    // Interner Zustand: mittlere Leistung (linear) und Zeitstempel
    private var power = [Double](repeating: 0, count: 2)
    private var lastUpdate: Double?

    /// Hochfahren: Die ersten Messwerte nach dem Start der Meter bzw. nach dem Anstecken sind teils Unsinn
    /// (Vollausschlag 0 dB), obwohl nichts anliegt. Statt sie zu verwerfen, steigt eine Obergrenze nach dem
    /// Start in `rampSeconds` von -60 dB auf 0 dB (Ease-in: erst langsam, dann schneller). Messwerte werden bis dahin darauf
    /// begrenzt: Das Meter reagiert sofort, aber ein Ausreisser am Anfang wird weder Spitze noch Clip.
    static let rampFloorDB = -60.0
    private let rampSeconds: Double
    private var rampStart: Double?

    init(rampSeconds: Double = 0.5) {
        self.rampSeconds = rampSeconds
        mics = [Self.silent, Self.silent]
    }

    /// Obergrenze zum Zeitpunkt `now` (0 dB nach Ablauf der Hochfahrzeit)
    private func rampCapDB(now: Double) -> Double {
        guard let start = rampStart, rampSeconds > 0 else { return 0 }
        let t = min(max((now - start) / rampSeconds, 0), 1)
        let eased = t * t   // Ease-in (quadratisch)
        return Self.rampFloorDB * (1 - eased)
    }

    /// 16 Eingangswerte vom Geraet. Jeder Messwert wird veroeffentlicht (Meter laufen nur bei offenem Panel).
    func update(inputs values: [Double], now: Double = ProcessInfo.processInfo.systemUptime) {
        guard values.count >= 2 else { return }
        if rampStart == nil { rampStart = now }
        let cap = rampCapDB(now: now)
        let dt = lastUpdate.map { min(max(now - $0, 0), 1.0) } ?? 0.05
        lastUpdate = now
        let a = 1 - exp(-dt / Self.rmsTau)
        var next = mics
        for i in 0..<2 {
            let raw = values[i].isFinite ? values[i] : DB.minimum
            let v = min(raw, cap)
            // Von der Obergrenze gekappte Werte (Ausreisser beim Hochfahren) zaehlen nicht als Spitze/Clip
            let trusted = raw <= cap
            let lin = pow(10, v / 20)
            power[i] += a * (lin * lin - power[i])
            let rms = power[i] > 1e-13 ? max(DB.minimum, 10 * log10(power[i])) : DB.minimum
            var ch = mics[i]
            ch.levelDB = v
            ch.rmsDB = rms
            if trusted {
                ch.maxPeakDB = max(ch.maxPeakDB, v)
                if v >= Self.clipThresholdDB { ch.lastClipAt = now }
            }
            next[i] = ch
        }
        if next != mics { mics = next }
        if !live { live = true }
    }

    /// Hoechste Spitze und Clip-LED eines Mikrofons zuruecksetzen (mic 0 = Mic 1, 1 = Mic 2).
    func resetPeak(mic: Int) {
        guard mics.indices.contains(mic) else { return }
        var next = mics
        next[mic].maxPeakDB = DB.minimum
        next[mic].lastClipAt = nil
        mics = next
    }

    /// Nur Clip loeschen (beide Mikrofone).
    func clearClip() {
        guard mics.contains(where: { $0.lastClipAt != nil }) else { return }
        mics = mics.map { var c = $0; c.lastClipAt = nil; return c }
    }

    /// Beim Abschalten der Meter (Panel zu): alles zurueck auf -128 dB, auch hoechste Spitze und Clip.
    func reset() {
        power = [0, 0]
        lastUpdate = nil
        rampStart = nil
        let next = [Self.silent, Self.silent]
        if next != mics { mics = next }
        if live { live = false }
    }
}
