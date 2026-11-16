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
        /// PPM (EBU Type IIa Ballistik): steigt sofort auf neue Spitzen, faellt mit 24 dB in 2,8 s
        var ppmDB: Double = DB.minimum
        /// Hoechste Spitze innerhalb der Haltezeit (fuer die Zahl; Klick setzt sofort zurueck)
        var maxPeakDB: Double
        /// Uptime-Sekunden des letzten Clips (>= -0,1 dBFS); die UI blendet die LED darueber aus
        var lastClipAt: TimeInterval?
    }

    /// Ein Eintrag je Vorverstaerker (iD14/iD24: 2, iD44: 4), Reihenfolge Mic 1...n
    @Published private(set) var mics: [Channel]
    /// Anzahl Kanaele (Profil.preampCount)
    private(set) var channelCount: Int
    /// true, solange Messwerte eintreffen (steuert in der UI den 30-fps-Zeichentakt)
    @Published private(set) var live = false
    /// Nur Vorschau-Modus (README-Bilder): feste Werte, keine Ballistik/Startrampe
    @Published private(set) var isPreview = false
    /// Anzeige der kleinen Zahl unter "Peak" (App-Einstellung, vom Controller gesetzt)
    @Published var levelReadout: UIPreferences.LevelReadout = .rms

    private static let silent = Channel(levelDB: DB.minimum, rmsDB: DB.minimum, ppmDB: DB.minimum, maxPeakDB: DB.minimum, lastClipAt: nil)
    static let rmsTau = 0.300
    /// PPM-Rueckgang in dB/s: 24 dB in 2,8 s (EBU Type IIa)
    nonisolated static let ppmFallDBPerSecond = 24.0 / 2.8
    static let clipThresholdDB = -0.1
    nonisolated static let clipFadeSeconds = 2.0

    /// LED-Helligkeit 1 -> 0, linear ueber 2 s nach dem letzten Clip.
    nonisolated static func clipOpacity(lastClipAt: TimeInterval?, now: TimeInterval) -> Double {
        guard let t = lastClipAt else { return 0 }
        return min(1, max(0, 1 - (now - t) / clipFadeSeconds))
    }

    // Interner Zustand: mittlere Leistung (linear) und Zeitstempel
    private var power: [Double]
    /// Zeitpunkt der zuletzt gehaltenen Spitze je Mikrofon (fuer die Haltezeit)
    private var peakAt: [Double]
    /// Haltezeit der Spitzen-Zahl und des Peak-Strichs (Settings: 2, 4, 6 s oder unendlich = .infinity)
    var peakHoldSeconds: Double = UIPreferences.peakHoldDefault
    private var lastUpdate: Double?

    /// Hochfahren: Die ersten Messwerte nach dem Start der Meter bzw. nach dem Anstecken sind teils Unsinn
    /// (Vollausschlag 0 dB), obwohl nichts anliegt. Statt sie zu verwerfen, steigt eine Obergrenze nach dem
    /// Start in `rampSeconds` von -60 dB auf 0 dB (Ease-in: erst langsam, dann schneller). Messwerte werden bis dahin darauf
    /// begrenzt: Das Meter reagiert sofort, aber ein Ausreisser am Anfang wird weder Spitze noch Clip.
    static let rampFloorDB = -60.0
    private let rampSeconds: Double
    private var rampStart: Double?

    init(rampSeconds: Double = 0.5, channelCount: Int = 2) {
        self.rampSeconds = rampSeconds
        let n = Self.clampCount(channelCount)
        self.channelCount = n
        mics = [Channel](repeating: Self.silent, count: n)
        power = [Double](repeating: 0, count: n)
        peakAt = [Double](repeating: 0, count: n)
    }

    private static func clampCount(_ n: Int) -> Int { min(max(n, 1), 16) }

    /// Kanalzahl umstellen (anderes Geraet): alles zurueck auf Stille in neuer Groesse.
    func configure(channelCount n: Int) {
        let n = Self.clampCount(n)
        guard n != channelCount else { return }
        channelCount = n
        reset()
    }

    /// Obergrenze zum Zeitpunkt `now` (0 dB nach Ablauf der Hochfahrzeit)
    private func rampCapDB(now: Double) -> Double {
        guard let start = rampStart, rampSeconds > 0 else { return 0 }
        let t = min(max((now - start) / rampSeconds, 0), 1)
        let eased = t * t   // Ease-in (quadratisch)
        return Self.rampFloorDB * (1 - eased)
    }

    /// 16 Eingangswerte vom Geraet (Mic-Kanaele = die ersten `channelCount`). Fehlende Werte (weniger Werte als
    /// Kanaele) bleiben still (ANNAHME fuer 4-Kanal-Geraete: die Mics liegen im selben Block auf Index 0-3).
    /// Jeder Messwert wird veroeffentlicht (Meter laufen nur bei offenem Panel).
    func update(inputs values: [Double], now: Double = ProcessInfo.processInfo.systemUptime) {
        guard values.count >= min(2, channelCount) else { return }
        if rampStart == nil { rampStart = now }
        let cap = rampCapDB(now: now)
        let prevUpdate = lastUpdate
        let dt = lastUpdate.map { min(max(now - $0, 0), 1.0) } ?? 0.05
        lastUpdate = now
        let a = 1 - exp(-dt / Self.rmsTau)
        let ppmDt = prevUpdate.map { min(max(now - $0, 0), 0.25) } ?? 0
        let ppmFall = Self.ppmFallDBPerSecond * ppmDt
        var next = mics
        for i in 0..<channelCount {
            let rawIn = i < values.count ? values[i] : DB.minimum
            let raw = rawIn.isFinite ? rawIn : DB.minimum
            let v = min(raw, cap)
            // Von der Obergrenze gekappte Werte (Ausreisser beim Hochfahren) zaehlen nicht als Spitze/Clip
            let trusted = raw <= cap
            let lin = pow(10, v / 20)
            power[i] += a * (lin * lin - power[i])
            let rms = power[i] > 1e-13 ? max(DB.minimum, 10 * log10(power[i])) : DB.minimum
            var ch = mics[i]
            ch.levelDB = v
            ch.rmsDB = rms
            // PPM: Anstieg nur mit vertrauenswuerdigen Werten (wie maxPeak), Rueckgang immer
            ch.ppmDB = max(DB.minimum, ch.ppmDB - ppmFall)
            if trusted {
                ch.ppmDB = max(ch.ppmDB, v)
                // Haltezeit: neue Spitze sofort, sonst nach Ablauf auf den aktuellen Wert zurueck (unendlich = halten)
                if v >= ch.maxPeakDB || now - peakAt[i] > peakHoldSeconds {
                    ch.maxPeakDB = v
                    peakAt[i] = now
                }
                if v >= Self.clipThresholdDB { ch.lastClipAt = now }
            }
            next[i] = ch
        }
        if next != mics { mics = next }
        if !live { live = true }
    }

    /// Nur fuer den Vorschau-Modus: feste Kanalwerte setzen (Standbild, kein Live-Takt).
    func setPreview(_ channels: [Channel]) {
        channelCount = Self.clampCount(channels.count)
        mics = channels
        isPreview = true
        live = false
    }

    /// Hoechste Spitze und Clip-LED eines Mikrofons zuruecksetzen (mic 0 = Mic 1, 1 = Mic 2).
    func resetPeak(mic: Int) {
        guard mics.indices.contains(mic) else { return }
        var next = mics
        next[mic].maxPeakDB = DB.minimum
        peakAt[mic] = 0
        next[mic].lastClipAt = nil
        mics = next
    }

    /// Nur Clip loeschen (alle Mikrofone).
    func clearClip() {
        guard mics.contains(where: { $0.lastClipAt != nil }) else { return }
        mics = mics.map { var c = $0; c.lastClipAt = nil; return c }
    }

    /// Beim Abschalten der Meter (Panel zu): alles zurueck auf -128 dB, auch hoechste Spitze und Clip.
    func reset() {
        power = [Double](repeating: 0, count: channelCount)
        lastUpdate = nil
        rampStart = nil
        peakAt = [Double](repeating: 0, count: channelCount)
        let next = [Channel](repeating: Self.silent, count: channelCount)
        if next != mics { mics = next }
        if live { live = false }
    }
}
