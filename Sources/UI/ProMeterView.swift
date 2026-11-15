// ProMeterView.swift – Pegelmeter fuer Mic 1/2: zwei gleich breite Spalten. Je Spalte Name, darunter links das
// vertikale Meter (IEC-Skala, RMS-Balken mit Peak-Balken darin, Peak-Hold) mit eigener Skala und rechts ein
// Info-Bereich (Clip-LED, Spitzen-Zahl, RMS).
// macOS-Look: Systemfarben, keine eigenen Rahmen oder Schatten.
// Zeichentakt 30 fps nur, solange Messwerte eintreffen (meters.live); sonst statisch ohne Timer.
import SwiftUI

// MARK: - Ballistik (ohne Allokation pro Frame)

private struct MeterSnap {
    var peak = DB.minimum        // angezeigte Spitze (schneller Anstieg, ruhiger Fall)
    var rms = DB.minimum
    var hold = DB.minimum        // Peak-Hold-Strich
    var maxPeak = DB.minimum     // Zahl
}

@MainActor
private final class MeterBallistics {
    static let fallDBPerSecond = 11.8
    static let riseTau = 0.025           // Anstieg wird sehr schnell geglaettet, Spitzen bleiben im Hold erhalten

    private var peak = [Double](repeating: DB.minimum, count: 2)
    private var rms = [Double](repeating: DB.minimum, count: 2)
    private var hold = [Double](repeating: DB.minimum, count: 2)
    private var stamp = [Double](repeating: 0, count: 2)
    private var last: Double?

    /// Arrays an die Kanalzahl anpassen (2 beim iD14/iD24, 4 beim iD44)
    private func resize(_ n: Int) {
        guard peak.count != n else { return }
        peak = [Double](repeating: DB.minimum, count: n)
        rms = peak; hold = peak
        stamp = [Double](repeating: 0, count: n)
    }

    private func follow(_ disp: Double, target: Double, fall: Double, k: Double) -> Double {
        target > disp ? disp + (target - disp) * k : max(target, disp - fall)
    }

    /// `holdSeconds`: Haltezeit des Peak-Strichs (wie die Zahl; unendlich = .infinity)
    func step(now: Double, channels: [MeterModel.Channel], holdSeconds: Double, ppm: Bool) -> [MeterSnap] {
        resize(channels.count)
        let dt = last.map { min(max(now - $0, 0), 0.25) } ?? 0
        last = now
        let fall = Self.fallDBPerSecond * dt
        let k = dt == 0 ? 1 : 1 - exp(-dt / Self.riseTau)
        var out = [MeterSnap](repeating: MeterSnap(), count: channels.count)
        for i in channels.indices {
            let c = channels[i]
            peak[i] = follow(peak[i], target: c.levelDB, fall: fall, k: k)
            rms[i] = follow(rms[i], target: ppm ? c.ppmDB : c.rmsDB, fall: fall, k: k)
            // Peak-Hold auf dem echten Maximalwert der Messung
            if c.levelDB >= hold[i] {
                hold[i] = c.levelDB; stamp[i] = now
            } else if now - stamp[i] > holdSeconds {
                hold[i] = max(c.levelDB, hold[i] - fall)
            }
            out[i] = MeterSnap(peak: peak[i], rms: rms[i], hold: hold[i], maxPeak: c.maxPeakDB)
        }
        return out
    }

    /// Ruhezustand ohne Messwerte: Ballistik leeren, Zahl bleibt.
    func rest(channels: [MeterModel.Channel]) -> [MeterSnap] {
        resize(channels.count)
        for i in channels.indices { peak[i] = DB.minimum; rms[i] = DB.minimum; hold[i] = DB.minimum }
        last = nil
        return channels.map { MeterSnap(peak: DB.minimum, rms: DB.minimum, hold: DB.minimum, maxPeak: $0.maxPeakDB) }
    }
}

// MARK: - Farben (Systemfarben, folgen Hell/Dunkel)

private enum ProColor {
    static func zone(_ z: MeterScale.Zone) -> Color {
        switch z {
        case .below: return Color.green.opacity(0.6)
        case .target: return Color.green
        case .hot: return Color.orange
        case .danger: return Color.red
        }
    }
}

/// Geometrie (nicht main-isoliert, damit der Canvas-Zeichner sie nutzen kann)
private enum Geo {
    static let meterW: CGFloat = 24
    static let gap: CGFloat = 6
    static let scaleW: CGFloat = 26
    static let pad: CGFloat = 6
    static let meterH: CGFloat = 130
    static let height: CGFloat = 130 + 12
    static let majorTicks: [Double] = [0, -6, -12, -18, -24, -36, -48]
    static let minorTicks: [Double] = [-3, -9, -15, -21, -30, -42, -54, -60]
    static func y(_ db: Double, h: CGFloat) -> CGFloat { pad + (h - 2 * pad) * CGFloat(1 - MeterScale.fraction(db)) }

    // 4-Meter-Layout (iD44), Breitenbudget bei 292 pt Inhalt (320 - 2*14): 34 + 4*55 + 38 = 292
    static let quadMeterW: CGFloat = 18
    static let quadScaleW: CGFloat = 34
    static let quadColW: CGFloat = 55
    static let quadCapW: CGFloat = 38
    static let quadLabelH: CGFloat = 16
    static let quadPeakH: CGFloat = 20
    static let quadRmsH: CGFloat = 14
    static let quadSpacing: CGFloat = 6
}

/// Gemeinsame Zeichnung eines einzelnen Balkens (Spur, Zonen-Toenung, RMS/PPM breit, Peak schmal, Segmentierung, Hold).
/// Wird vom 2-Kanal-Meter (mit eigener Skala) und vom 4-Meter-Layout benutzt; nicht main-isoliert fuer den Canvas.
private enum MeterDraw {
    static func bar(_ ctx: GraphicsContext, height h: CGFloat, width w: CGFloat, xOffset: CGFloat = 0,
                    snap s: MeterSnap, floorDB: Double) {
        let track = Color(nsColor: .tertiarySystemFill)
        func y(_ db: Double) -> CGFloat { Geo.y(db, h: h) }
        let bottom = h - Geo.pad
        func rect(_ from: Double, _ to: Double, inset: CGFloat = 0) -> CGRect {
            CGRect(x: xOffset + inset, y: y(to), width: w - 2 * inset, height: y(from) - y(to))
        }

        let trackRect = CGRect(x: xOffset, y: Geo.pad, width: w, height: bottom - Geo.pad)
        var c = ctx
        c.clip(to: Path(roundedRect: trackRect, cornerRadius: 4))
        c.fill(Path(trackRect), with: .color(track))
        // Zonen-Toenung im unbeleuchteten Meter: zeigt schon im Ruhezustand, wo Gruen endet
        c.fill(Path(rect(floorDB, -6)), with: .color(Color.green.opacity(0.14)))
        c.fill(Path(rect(-6, -3)), with: .color(Color.orange.opacity(0.16)))
        c.fill(Path(rect(-3, 0)), with: .color(Color.red.opacity(0.16)))
        // RMS breit und gedeckt, Peak schmal und voll, jeweils in Zonenstuecken
        let bands: [(Double, Double, MeterScale.Zone)] = [(-70, floorDB, .below), (floorDB, -6, .target),
                                                          (-6, -3, .hot), (-3, 0.0001, .danger)]
        for (lo, hi, zone) in bands {
            let color = ProColor.zone(zone)
            if s.rms > lo { c.fill(Path(rect(lo, min(s.rms, hi))), with: .color(color.opacity(0.30))) }
            if s.peak > lo { c.fill(Path(rect(lo, min(s.peak, hi), inset: w * 0.275)), with: .color(color)) }
        }
        // feine Segmentierung: 1-pt-Luecke alle 3 pt in der Spurfarbe (erst ausstanzen, dann Spur einsetzen)
        var gaps = Path()
        var yy = trackRect.minY + 2
        while yy < bottom { gaps.addRect(CGRect(x: xOffset, y: yy, width: w, height: 1)); yy += 3 }
        c.blendMode = .destinationOut
        c.fill(gaps, with: .color(.black))
        c.blendMode = .normal
        c.fill(gaps, with: .color(track))
        // Peak-Hold-Strich
        if s.hold > -70 {
            c.fill(Path(CGRect(x: xOffset, y: y(s.hold) - 1, width: w, height: 2)),
                   with: .color(Color.primary.opacity(0.8)))
        }
    }

    /// Beschriftungstext einer Hauptmarke; hervorgehoben RMS -6/-12/-18, PPM -6/-12, uebrige gedaempft
    static func label(_ db: Double, ppm: Bool) -> Text {
        let text = Text(db == 0 ? "0" : "−\(Int(-db))").font(.caption2)
        return (db == -6 || db == -12 || (!ppm && db == -18))
            ? text.foregroundStyle(.primary)
            : text.foregroundStyle(.secondary.opacity(0.7))
    }
}

// MARK: - Clip-LED (schlichter Punkt)

/// Roter Punkt, `brightness` 0 (aus: secondary 0,3) ... 1 (rot).
struct ClipLEDDot: View {
    let brightness: Double
    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.3))
            Circle().fill(Color.red.opacity(min(max(brightness, 0), 1)))
        }
        .frame(width: 8, height: 8)
    }
}

/// Blendet ueber 2 s aus. Die Timeline laeuft nur bis zum Ende des Ausblendens (eigener Zeitplan, kein Dauer-Timer).
private struct ClipLED: View {
    let lastClipAt: TimeInterval?
    let animated: Bool
    var side: CGFloat = 20
    let onTap: () -> Void

    private struct FadeSchedule: TimelineSchedule {
        let end: Date
        func entries(from start: Date, mode: TimelineScheduleMode) -> [Date] {
            var out: [Date] = []
            var d = start
            while d < end { out.append(d); d = d.addingTimeInterval(1.0 / 30.0) }
            out.append(end)
            return out
        }
    }

    var body: some View {
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = lastClipAt.map { $0 + MeterModel.clipFadeSeconds - now } ?? 0
        Button(action: onTap) {
            Group {
                if animated, remaining > 0 {
                    TimelineView(FadeSchedule(end: Date().addingTimeInterval(remaining))) { _ in
                        ClipLEDDot(brightness: MeterModel.clipOpacity(lastClipAt: lastClipAt,
                                                                      now: ProcessInfo.processInfo.systemUptime))
                    }
                } else {
                    ClipLEDDot(brightness: MeterModel.clipOpacity(lastClipAt: lastClipAt, now: now))
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

// MARK: - Ansicht

struct ProMeterView: View {
    let channels: [MeterModel.Channel]
    /// Messwerte treffen ein: 60-fps-Zeichentakt mit Ballistik
    let live: Bool
    /// Vorschau: feste Werte ohne Ballistik darstellen
    var preview = false
    /// Peak-Haltezeit (Settings), gilt fuer Strich und Zahl
    var holdSeconds: Double = UIPreferences.peakHoldDefault
    /// Anzeige der kleinen Zahl: RMS oder PPM (Klick wechselt)
    var readout: UIPreferences.LevelReadout = .rms
    let onReset: (Int) -> Void
    /// Bekommt die aktuelle Anzeige; der Aufrufer schaltet um
    var onToggleReadout: (UIPreferences.LevelReadout) -> Void = { _ in }

    @State private var ballistics = MeterBallistics()

    var body: some View {
        if channels.count == 4 {
            quadBody
        } else {
            HStack(alignment: .top, spacing: 20) {
                ForEach(0..<min(channels.count, 2), id: \.self) { column($0) }
            }
        }
    }

    // MARK: 4-Meter-Layout (iD44): eine gemeinsame Skala links, vier schmale Meter, Zahlen darunter, Beschriftung rechts

    private var quadBody: some View {
        let isPPM = readout == .ppm
        let sp = Geo.quadSpacing
        return VStack(alignment: .leading, spacing: sp) {
            // Namen
            quadRow(height: Geo.quadLabelH) { i in
                Text("Mic \(i + 1)")
                    .font(.subheadline)
                    .help("Input level of Mic/Line input \(i + 1), measured by the interface before your computer.")
            }
            // Skala + Meter
            HStack(alignment: .top, spacing: 0) {
                quadScale
                quadMeters
                Color.clear.frame(width: Geo.quadCapW, height: Geo.height)
            }
            .help(isPPM
                  ? "Input level meter in PPM mode. For podcasts, aim for normal speech peaks around −10 dB (the marker), inside the green range, with loud moments below −6 dB."
                  : "Input level meter. When setting the gain, aim for roughly −18 dB RMS on average (the light bar), with peaks staying well below 0 dB. This leaves enough headroom for loud moments.")
            // Spitzenwerte
            quadRow(height: Geo.quadPeakH, caption: AnyView(
                Text("Peak")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .help("Peak: the loudest instantaneous level reached. Keep it below 0 dB to avoid clipping; around −12 to −6 dB is a good recording level.")
            )) { i in quadPeak(i) }
            // RMS/PPM
            quadRow(height: Geo.quadRmsH, caption: AnyView(
                Button { onToggleReadout(readout) } label: {
                    Text(isPPM ? "PPM" : "RMS")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(readoutHelp)
                .accessibilityLabel("Level readout, \(isPPM ? "PPM" : "RMS"). Activate to switch to \(isPPM ? "RMS" : "PPM")")
            )) { i in
                Button { onToggleReadout(readout) } label: {
                    Text(Self.numText(isPPM ? channels[i].ppmDB : channels[i].rmsDB))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(readoutHelp)
                .accessibilityLabel("Mic \(i + 1) level readout, \(isPPM ? "PPM" : "RMS"). Activate to switch to \(isPPM ? "RMS" : "PPM")")
            }
        }
    }

    private var readoutHelp: String {
        readout == .ppm
            ? "PPM (peak programme meter): rises instantly and falls back slowly (24 dB in 2.8 s, EBU/BBC style), the broadcast standard for speech. For podcasts, aim for normal speech peaks around −12 to −8 dB and keep loud moments below −6 dB. Click to show RMS instead."
            : "RMS: the average level over about 0.3 s, closer to perceived loudness than the peak. Aim for roughly −18 dB RMS when setting the gain. Click to show PPM instead."
    }

    /// Eine Zeile: leere Skalenspalte, vier gleich breite Zellen, rechts optional die Zeilenbeschriftung.
    private func quadRow<Cell: View>(height: CGFloat, caption: AnyView? = nil,
                                     @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Geo.quadScaleW, height: height)
            ForEach(0..<4, id: \.self) { i in
                cell(i).frame(width: Geo.quadColW, height: height)
            }
            Group { if let caption { caption } else { Color.clear } }
                .frame(width: Geo.quadCapW, height: height, alignment: .leading)
        }
    }

    private func quadPeak(_ i: Int) -> some View {
        let c = channels[i]
        let numberColor: Color = c.maxPeakDB <= -80 ? .secondary : ProColor.zone(MeterScale.zone(c.maxPeakDB, ppm: readout == .ppm))
        return Button { onReset(i) } label: {
            HStack(spacing: 1) {
                ClipLED(lastClipAt: c.lastClipAt, animated: !preview, side: 10) { onReset(i) }
                Text(Self.numText(c.maxPeakDB))
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Highest peak within the peak hold time (Settings). The red dot lights up at clipping (digital 0 dBFS = distortion). Click to reset.")
        .accessibilityLabel("Mic \(i + 1) level")
        .accessibilityValue("Peak \(Self.numText(c.maxPeakDB)) dB, \(readout == .ppm ? "PPM" : "RMS") \(Self.numText(readout == .ppm ? c.ppmDB : c.rmsDB)) dB")
    }

    /// Vier Meter in einem Zeichentakt (ein Ballistik-Schritt je Frame)
    @ViewBuilder private var quadMeters: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                quadMeterStrip(ballistics.step(now: ProcessInfo.processInfo.systemUptime, channels: channels,
                                               holdSeconds: holdSeconds, ppm: readout == .ppm))
            }
        } else if preview {
            quadMeterStrip(channels.map {
                MeterSnap(peak: $0.levelDB, rms: readout == .ppm ? $0.ppmDB : $0.rmsDB,
                          hold: min(0, $0.levelDB + 1.5), maxPeak: $0.maxPeakDB)
            })
        } else {
            quadMeterStrip(ballistics.rest(channels: channels))
        }
    }

    /// Ein Canvas fuer alle vier Balken (je 18 pt breit, mittig in ihrer 55-pt-Spalte)
    private func quadMeterStrip(_ snaps: [MeterSnap]) -> some View {
        let floorDB = MeterScale.targetFloor(ppm: readout == .ppm)
        let inset = (Geo.quadColW - Geo.quadMeterW) / 2
        return Canvas { ctx, size in
            for i in 0..<min(snaps.count, 4) {
                MeterDraw.bar(ctx, height: size.height, width: Geo.quadMeterW,
                              xOffset: CGFloat(i) * Geo.quadColW + inset, snap: snaps[i], floorDB: floorDB)
            }
        }
        .frame(width: 4 * Geo.quadColW, height: Geo.height)
        .accessibilityHidden(true)
    }

    /// Gemeinsame Skala links: Beschriftung rechtsbuendig, Teilstriche, Bezugsmarke (Dreieck nach rechts)
    private var quadScale: some View {
        let ppm = readout == .ppm
        let markerDB = MeterScale.marker(ppm: ppm)
        return Canvas { ctx, size in
            func y(_ db: Double) -> CGFloat { Geo.y(db, h: size.height) }
            let w = Geo.quadScaleW
            let tickEnd = w - 6          // Striche enden hier, rechts davon die Marke
            for db in Geo.minorTicks {
                var t = Path()
                t.move(to: CGPoint(x: tickEnd - 2.5, y: y(db))); t.addLine(to: CGPoint(x: tickEnd, y: y(db)))
                ctx.stroke(t, with: .color(Color.secondary.opacity(0.6)), lineWidth: 0.5)
            }
            for db in Geo.majorTicks {
                let yt = y(db)
                let strong = db == markerDB
                let len: CGFloat = strong ? 5 : 4
                var t = Path()
                t.move(to: CGPoint(x: tickEnd - len, y: yt)); t.addLine(to: CGPoint(x: tickEnd, y: yt))
                ctx.stroke(t, with: .color(Color.secondary.opacity(strong ? 0.9 : 0.6)), lineWidth: strong ? 1.25 : 0.75)
                ctx.draw(MeterDraw.label(db, ppm: ppm), at: CGPoint(x: tickEnd - 7, y: yt), anchor: .trailing)
            }
            var marker = Path()
            marker.move(to: CGPoint(x: w - 1, y: y(markerDB)))
            marker.addLine(to: CGPoint(x: w - 5, y: y(markerDB) - 3))
            marker.addLine(to: CGPoint(x: w - 5, y: y(markerDB) + 3))
            marker.closeSubpath()
            ctx.fill(marker, with: .color(Color.green))
        }
        .frame(width: Geo.quadScaleW, height: Geo.height)
        .accessibilityHidden(true)
    }

    private func column(_ mic: Int) -> some View {
        let c = channels[mic]
        let numberColor: Color = c.maxPeakDB <= -80 ? .secondary : ProColor.zone(MeterScale.zone(c.maxPeakDB, ppm: readout == .ppm))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Mic \(mic + 1)")
                .font(.subheadline)
                .help("Input level of Mic/Line input \(mic + 1)\(mic == 0 ? " (or the Hi-Z instrument input, which uses Input 1)" : ""), measured by the interface before your computer.")
            HStack(alignment: .top, spacing: 6) {
                meterRow(mic)
                    .help(readout == .ppm
                          ? "Input level meter in PPM mode. For podcasts, aim for normal speech peaks around −10 dB (the marker), inside the green range, with loud moments below −6 dB."
                          : "Input level meter. When setting the gain, aim for roughly −18 dB RMS on average (the light bar), with peaks staying well below 0 dB. This leaves enough headroom for loud moments.")
                VStack(alignment: .trailing, spacing: 0) {
                    Button { onReset(mic) } label: {
                        HStack(spacing: 0) {
                            ClipLED(lastClipAt: c.lastClipAt, animated: !preview) { onReset(mic) }
                            Text(Self.numText(c.maxPeakDB))
                                .font(.title2)
                                .monospacedDigit()
                                .foregroundStyle(numberColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Highest peak within the peak hold time (Settings). The red dot lights up at clipping (digital 0 dBFS = distortion). Click to reset.")
                    .accessibilityLabel("Mic \(mic + 1) level")
                    .accessibilityValue("Peak \(Self.numText(c.maxPeakDB)) dB, \(readout == .ppm ? "PPM" : "RMS") \(Self.numText(readout == .ppm ? c.ppmDB : c.rmsDB)) dB")
                    Text("Peak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Peak: the loudest instantaneous level reached. Keep it below 0 dB to avoid clipping; around −12 to −6 dB is a good recording level.")
                    Spacer().frame(height: 14)
                    let isPPM = readout == .ppm
                    Button { onToggleReadout(readout) } label: {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(Self.numText(isPPM ? c.ppmDB : c.rmsDB))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(isPPM ? "PPM" : "RMS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isPPM
                          ? "PPM (peak programme meter): rises instantly and falls back slowly (24 dB in 2.8 s, EBU/BBC style), the broadcast standard for speech. For podcasts, aim for normal speech peaks around −12 to −8 dB and keep loud moments below −6 dB. Click to show RMS instead."
                          : "RMS: the average level over about 0.3 s, closer to perceived loudness than the peak. Aim for roughly −18 dB RMS when setting the gain. Click to show PPM instead.")
                    .accessibilityLabel("Level readout, \(isPPM ? "PPM" : "RMS"). Activate to switch to \(isPPM ? "RMS" : "PPM")")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func meterRow(_ mic: Int) -> some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                let snaps = ballistics.step(now: ProcessInfo.processInfo.systemUptime, channels: channels, holdSeconds: holdSeconds, ppm: readout == .ppm)
                meter(snaps[mic])
            }
        } else if preview {
            let c = channels[mic]
            meter(MeterSnap(peak: c.levelDB, rms: readout == .ppm ? c.ppmDB : c.rmsDB, hold: min(0, c.levelDB + 1.5), maxPeak: c.maxPeakDB))
        } else {
            meter(ballistics.rest(channels: channels)[mic])
        }
    }

    static func numText(_ v: Double) -> String {
        v <= -80 ? "−∞" : decimalText(v, digits: 1)
    }

    // MARK: Meter + eigene Skala (Canvas)

    private func meter(_ s: MeterSnap) -> some View {
        let totalW = Geo.meterW + Geo.gap + Geo.scaleW
        let ppm = readout == .ppm
        let floorDB = MeterScale.targetFloor(ppm: ppm)
        let markerDB = MeterScale.marker(ppm: ppm)
        return Canvas { ctx, size in
            let h = size.height
            func y(_ db: Double) -> CGFloat { Geo.y(db, h: h) }
            MeterDraw.bar(ctx, height: h, width: Geo.meterW, snap: s, floorDB: floorDB)

            // Bezugsmarke (RMS -18 dB, PPM -10 dB): kleines Dreieck zeigt links zum Meter (unbeschnitten auf ctx)
            var marker = Path()
            marker.move(to: CGPoint(x: Geo.meterW + 1, y: y(markerDB)))
            marker.addLine(to: CGPoint(x: Geo.meterW + 5, y: y(markerDB) - 3))
            marker.addLine(to: CGPoint(x: Geo.meterW + 5, y: y(markerDB) + 3))
            marker.closeSubpath()
            ctx.fill(marker, with: .color(Color.green))

            // Skala: Nebenteilstriche (kurz, ohne Zahl), Hauptteilstriche mit Beschriftung
            let x0 = Geo.meterW + Geo.gap
            for db in Geo.minorTicks {
                var t = Path()
                t.move(to: CGPoint(x: x0, y: y(db))); t.addLine(to: CGPoint(x: x0 + 2.5, y: y(db)))
                ctx.stroke(t, with: .color(Color.secondary.opacity(0.6)), lineWidth: 0.5)
            }
            for db in Geo.majorTicks {
                let yt = y(db)
                let strong = db == markerDB
                var t = Path()
                t.move(to: CGPoint(x: x0, y: yt)); t.addLine(to: CGPoint(x: x0 + (strong ? 5 : 4), y: yt))
                ctx.stroke(t, with: .color(Color.secondary.opacity(strong ? 0.9 : 0.6)), lineWidth: strong ? 1.25 : 0.75)
                let styled = MeterDraw.label(db, ppm: ppm)
                ctx.draw(styled, at: CGPoint(x: x0 + 7, y: yt), anchor: .leading)
            }
        }
        .frame(width: totalW, height: Geo.height)
        .accessibilityHidden(true)
    }
}
