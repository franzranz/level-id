// MeterTests.swift – Skala, Zonen und Messwert-Logik des Gain-Meters (offline).
import Foundation

@MainActor func runMeterTests() {
    print("\n-- Meter --")
    check("MeterScale: -20 dB = 0,5", abs(MeterScale.fraction(-20) - 0.5) < 1e-9)
    check("MeterScale: 0 dB = 1", MeterScale.fraction(0) == 1)
    check("MeterScale: -70 dB = 0, darunter 0", MeterScale.fraction(-70) == 0 && MeterScale.fraction(-90) == 0 && MeterScale.fraction(-.infinity) == 0)
    check("MeterScale: ueber 0 dB begrenzt", MeterScale.fraction(6) == 1)
    let pts = stride(from: -80.0, through: 3.0, by: 0.25).map { MeterScale.fraction($0) }
    check("MeterScale: monoton steigend", zip(pts, pts.dropFirst()).allSatisfy { $0 <= $1 })
    check("MeterScale: Stuetzpunkte IEC", abs(MeterScale.fraction(-30) - 0.30) < 1e-9 && abs(MeterScale.fraction(-40) - 0.15) < 1e-9
          && abs(MeterScale.fraction(-50) - 0.075) < 1e-9 && abs(MeterScale.fraction(-60) - 0.025) < 1e-9)
    check("Zonen PPM: Grenzen", MeterScale.zone(-13, ppm: true) == .below && MeterScale.zone(-12, ppm: true) == .target
          && MeterScale.zone(-6.5, ppm: true) == .target && MeterScale.zone(-5, ppm: true) == .hot && MeterScale.zone(-2, ppm: true) == .danger)
    check("Zonen RMS unveraendert", MeterScale.zone(-13) == .target && MeterScale.zone(-13, ppm: false) == .target && MeterScale.zone(-19) == .below)
    check("MeterScale: targetFloor/marker", MeterScale.targetFloor(ppm: false) == -18 && MeterScale.targetFloor(ppm: true) == -12
          && MeterScale.marker(ppm: false) == -18 && MeterScale.marker(ppm: true) == -10)
    check("Zonen: Grenzen", MeterScale.zone(-18.01) == .below && MeterScale.zone(-18) == .target
          && MeterScale.zone(-6.01) == .target && MeterScale.zone(-6) == .hot && MeterScale.zone(-3) == .hot
          && MeterScale.zone(-2.99) == .danger && MeterScale.zone(0) == .danger && MeterScale.zone(-60) == .below)

    // RMS konvergiert auf den Pegel eines konstanten Signals (20 Hz, 3 s)
    let m = MeterModel(rampSeconds: 0)
    var t = 100.0
    for _ in 0..<60 { m.update(inputs: [-20, -12] + [Double](repeating: -128, count: 14), now: t); t += 0.05 }
    check("RMS: konstantes Signal konvergiert (-20 dB)", abs(m.mics[0].rmsDB + 20) < 0.1, "\(m.mics[0].rmsDB)")
    check("RMS: Mic 2 unabhaengig (-12 dB)", abs(m.mics[1].rmsDB + 12) < 0.1, "\(m.mics[1].rmsDB)")
    // RMS faellt mit tau ~ 300 ms: nach Stille nach 0,3 s auf 1/e der Leistung (-4,34 dB)
    let m2 = MeterModel(rampSeconds: 0)
    var t2 = 0.0
    for _ in 0..<100 { m2.update(inputs: [-20, -128] + [Double](repeating: -128, count: 14), now: t2); t2 += 0.05 }
    for _ in 0..<6 { m2.update(inputs: [Double](repeating: -128, count: 16), now: t2); t2 += 0.05 }
    check("RMS: Abfall mit tau 300 ms (ca. -24,3 dB nach 0,3 s)", abs(m2.mics[0].rmsDB + 24.34) < 0.3, "\(m2.mics[0].rmsDB)")

    // LED-Helligkeit: 1 -> 0,5 nach 1 s -> 0 nach 2 s
    let t0 = 50.0
    check("clipOpacity: 1 direkt nach dem Clip, 0,5 nach 1 s, 0 nach 2 s",
          MeterModel.clipOpacity(lastClipAt: t0, now: t0) == 1 && abs(MeterModel.clipOpacity(lastClipAt: t0, now: t0 + 1) - 0.5) < 1e-9
          && MeterModel.clipOpacity(lastClipAt: t0, now: t0 + 2) == 0 && MeterModel.clipOpacity(lastClipAt: t0, now: t0 + 9) == 0)
    check("clipOpacity: ohne Clip aus, neuer Clip sofort wieder voll",
          MeterModel.clipOpacity(lastClipAt: nil, now: 5) == 0 && MeterModel.clipOpacity(lastClipAt: t0 + 1.9, now: t0 + 1.9) == 1)

    // Spitzenwert und Clip, resetPeak setzt zurueck
    // Hochfahren: Obergrenze steigt in 0,5 s (Ease-in) von -60 auf 0 dB; Ausreisser am Anfang werden nicht Spitze/Clip
    let w = MeterModel(rampSeconds: 0.5)
    w.update(inputs: [0, -90] + [Double](repeating: -128, count: 14), now: 10)
    check("Hochfahren: Vollausschlag beim Start wird auf -60 dB begrenzt, kein Clip, Meter sofort live",
          w.mics[0].levelDB == -60 && w.mics[0].maxPeakDB == DB.minimum && w.mics[0].lastClipAt == nil && w.live)
    check("Hochfahren: leise Werte bleiben unveraendert und zaehlen als Spitze", w.mics[1].levelDB == -90 && w.mics[1].maxPeakDB == -90)
    w.update(inputs: [0, 0] + [Double](repeating: -128, count: 14), now: 10.25)
    check("Hochfahren: nach halber Zeit Obergrenze -45 dB (Ease-in)", abs(w.mics[0].levelDB - (-45)) < 1e-9 && w.mics[0].lastClipAt == nil)
    w.update(inputs: [-20, -30] + [Double](repeating: -128, count: 14), now: 10.6)
    check("Hochfahren: danach normale Messung, Spitze ohne Ausreisser", w.mics[0].levelDB == -20 && w.mics[0].maxPeakDB == -20)
    w.reset()
    w.update(inputs: [0, 0] + [Double](repeating: -128, count: 14), now: 20)
    check("Hochfahren: nach reset() erneut aktiv", w.mics[0].maxPeakDB == DB.minimum && w.mics[0].levelDB == -60)
    // Haltezeit 3 s: Spitze bleibt stehen, faellt danach auf den aktuellen Wert, neue Spitze sofort
    let h = MeterModel(rampSeconds: 0)
    h.peakHoldSeconds = 3
    h.update(inputs: [-6, -128] + [Double](repeating: -128, count: 14), now: 30)
    h.update(inputs: [-40, -128] + [Double](repeating: -128, count: 14), now: 32.9)
    check("Haltezeit: Spitze haelt innerhalb von 3 s", h.mics[0].maxPeakDB == -6)
    h.update(inputs: [-40, -128] + [Double](repeating: -128, count: 14), now: 33.1)
    check("Haltezeit: nach 3 s auf den aktuellen Wert", h.mics[0].maxPeakDB == -40)
    h.update(inputs: [-10, -128] + [Double](repeating: -128, count: 14), now: 33.2)
    check("Haltezeit: neue hoehere Spitze sofort", h.mics[0].maxPeakDB == -10)
    let inf = MeterModel(rampSeconds: 0)
    inf.peakHoldSeconds = .infinity
    inf.update(inputs: [-6, -128] + [Double](repeating: -128, count: 14), now: 40)
    inf.update(inputs: [-40, -128] + [Double](repeating: -128, count: 14), now: 400)
    check("Haltezeit unendlich: Spitze bleibt bis zum Reset", inf.mics[0].maxPeakDB == -6)
    inf.resetPeak(mic: 0)
    inf.update(inputs: [-40, -128] + [Double](repeating: -128, count: 14), now: 401)
    check("Haltezeit unendlich: nach Reset aktueller Wert", inf.mics[0].maxPeakDB == -40)
    // PPM: sofortiger Anstieg, 24 dB in 2,8 s Rueckgang, reset loescht
    let q = MeterModel(rampSeconds: 0)
    let quiet = [Double](repeating: -128, count: 14)
    q.update(inputs: [-30, -128] + quiet, now: 100)
    q.update(inputs: [-10, -128] + quiet, now: 100.05)
    check("PPM steigt sofort auf neue Spitze", q.mics[0].ppmDB == -10)
    for k in 1...20 { q.update(inputs: [-128, -128] + quiet, now: 100.05 + 0.05 * Double(k)) }
    check("PPM faellt nach 1 s um ca. 8,6 dB", abs(q.mics[0].ppmDB - (-10 - 24.0 / 2.8)) < 0.3)
    q.update(inputs: [-5, -128] + quiet, now: 101.2)
    check("PPM steigt wieder sofort", q.mics[0].ppmDB == -5)
    q.reset()
    check("PPM reset() -> Minimum", q.mics[0].ppmDB == DB.minimum)
    let p = MeterModel(rampSeconds: 0)
    p.update(inputs: [-30, -40] + [Double](repeating: -128, count: 14), now: 1)
    p.update(inputs: [-6, -40] + [Double](repeating: -128, count: 14), now: 1.05)
    p.update(inputs: [-50, -40] + [Double](repeating: -128, count: 14), now: 1.10)
    check("maxPeak rastet ein (-6 dB)", p.mics[0].maxPeakDB == -6 && p.mics[1].maxPeakDB == -40)
    check("Kein Clip bei -6 dB", p.mics[0].lastClipAt == nil)
    p.update(inputs: [-0.05, -40] + [Double](repeating: -128, count: 14), now: 1.15)
    p.update(inputs: [-60, -40] + [Double](repeating: -128, count: 14), now: 1.20)
    check("lastClipAt wird ab -0,1 dBFS gesetzt und bleibt beim naechsten leisen Wert", p.mics[0].lastClipAt == 1.15 && p.mics[1].lastClipAt == nil && p.mics[0].maxPeakDB == -0.05)
    p.resetPeak(mic: 0)
    check("resetPeak(mic:) setzt maxPeak und Clip zurueck, anderes Mic unberuehrt",
          p.mics[0].maxPeakDB == DB.minimum && p.mics[0].lastClipAt == nil && p.mics[1].maxPeakDB == -40)
    p.reset()
    check("reset() (Meter aus): Pegel -128, live aus, Spitze und Clip zurueckgesetzt", p.mics[0].levelDB == DB.minimum && !p.live && p.mics[1].maxPeakDB == DB.minimum && p.mics[0].lastClipAt == nil)
}
