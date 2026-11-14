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
    static let holdSeconds = 2.0
    static let riseTau = 0.025           // Anstieg wird sehr schnell geglaettet, Spitzen bleiben im Hold erhalten

    private var peak = [Double](repeating: DB.minimum, count: 2)
    private var rms = [Double](repeating: DB.minimum, count: 2)
    private var hold = [Double](repeating: DB.minimum, count: 2)
    private var stamp = [Double](repeating: 0, count: 2)
    private var last: Double?

    private func follow(_ disp: Double, target: Double, fall: Double, k: Double) -> Double {
        target > disp ? disp + (target - disp) * k : max(target, disp - fall)
    }

    func step(now: Double, channels: [MeterModel.Channel]) -> [MeterSnap] {
        let dt = last.map { min(max(now - $0, 0), 0.25) } ?? 0
        last = now
        let fall = Self.fallDBPerSecond * dt
        let k = dt == 0 ? 1 : 1 - exp(-dt / Self.riseTau)
        var out = [MeterSnap](repeating: MeterSnap(), count: 2)
        for i in 0..<2 {
            let c = channels[i]
            peak[i] = follow(peak[i], target: c.levelDB, fall: fall, k: k)
            rms[i] = follow(rms[i], target: c.rmsDB, fall: fall, k: k)
            // Peak-Hold auf dem echten Maximalwert der Messung
            if c.levelDB >= hold[i] {
                hold[i] = c.levelDB; stamp[i] = now
            } else if now - stamp[i] > Self.holdSeconds {
                hold[i] = max(c.levelDB, hold[i] - fall)
            }
            out[i] = MeterSnap(peak: peak[i], rms: rms[i], hold: hold[i], maxPeak: c.maxPeakDB)
        }
        return out
    }

    /// Ruhezustand ohne Messwerte: Ballistik leeren, Zahl bleibt.
    func rest(channels: [MeterModel.Channel]) -> [MeterSnap] {
        for i in 0..<2 { peak[i] = DB.minimum; rms[i] = DB.minimum; hold[i] = DB.minimum }
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
            .frame(width: 20, height: 20)
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
    let onReset: (Int) -> Void

    @State private var ballistics = MeterBallistics()

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            column(0)
            column(1)
        }
    }

    private func column(_ mic: Int) -> some View {
        let c = channels[mic]
        let numberColor: Color = c.maxPeakDB <= -80 ? .secondary : ProColor.zone(MeterScale.zone(c.maxPeakDB))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Mic \(mic + 1)")
                .font(.subheadline)
                .help("Input level of Mic/Line input \(mic + 1)\(mic == 0 ? " (or the Hi-Z instrument input, which uses Input 1)" : ""), measured by the interface before your computer.")
            HStack(alignment: .top, spacing: 6) {
                meterRow(mic)
                    .help("Input level meter. When setting the gain, aim for roughly −18 dB RMS on average (the light bar), with peaks staying well below 0 dB. This leaves enough headroom for loud moments.")
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
                    .help("Highest peak since the panel was opened. The red dot lights up at clipping (digital 0 dBFS = distortion). Click to reset.")
                    .accessibilityLabel("Mic \(mic + 1) level")
                    .accessibilityValue("Peak \(Self.numText(c.maxPeakDB)) dB, RMS \(Self.numText(c.rmsDB)) dB")
                    Text("Peak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Peak: the loudest instantaneous level reached. Keep it below 0 dB to avoid clipping; around −12 to −6 dB is a good recording level.")
                    Spacer().frame(height: 14)
                    Text(Self.numText(c.rmsDB))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("RMS: the average level over about 0.3 s, closer to perceived loudness than the peak. Aim for roughly −18 dB RMS when setting the gain.")
                    Text("RMS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("RMS: the average level over about 0.3 s, closer to perceived loudness than the peak. Aim for roughly −18 dB RMS when setting the gain.")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func meterRow(_ mic: Int) -> some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                let snaps = ballistics.step(now: ProcessInfo.processInfo.systemUptime, channels: channels)
                meter(snaps[mic])
            }
        } else if preview {
            let c = channels[mic]
            meter(MeterSnap(peak: c.levelDB, rms: c.rmsDB, hold: min(0, c.levelDB + 1.5), maxPeak: c.maxPeakDB))
        } else {
            meter(ballistics.rest(channels: channels)[mic])
        }
    }

    static func numText(_ v: Double) -> String {
        v <= -80 ? "−∞" : decimalText(v, digits: 1)
    }

    // MARK: Meter + eigene Skala (Canvas)

    private func meter(_ s: MeterSnap) -> some View {
        let track = Color(nsColor: .tertiarySystemFill)
        let totalW = Geo.meterW + Geo.gap + Geo.scaleW
        return Canvas { ctx, size in
            let h = size.height
            func y(_ db: Double) -> CGFloat { Geo.pad + (h - 2 * Geo.pad) * CGFloat(1 - MeterScale.fraction(db)) }
            let bottom = h - Geo.pad
            func rect(_ from: Double, _ to: Double, inset: CGFloat = 0) -> CGRect {
                CGRect(x: inset, y: y(to), width: Geo.meterW - 2 * inset, height: y(from) - y(to))
            }

            let trackRect = CGRect(x: 0, y: Geo.pad, width: Geo.meterW, height: bottom - Geo.pad)
            var c = ctx
            c.clip(to: Path(roundedRect: trackRect, cornerRadius: 4))
            c.fill(Path(trackRect), with: .color(track))
            // RMS breit und gedeckt, Peak schmal und voll, jeweils in Zonenstuecken
            let bands: [(Double, Double, MeterScale.Zone)] = [(-70, -18, .below), (-18, -6, .target),
                                                              (-6, -3, .hot), (-3, 0.0001, .danger)]
            for (lo, hi, zone) in bands {
                let color = ProColor.zone(zone)
                if s.rms > lo { c.fill(Path(rect(lo, min(s.rms, hi))), with: .color(color.opacity(0.30))) }
                if s.peak > lo { c.fill(Path(rect(lo, min(s.peak, hi), inset: Geo.meterW * 0.275)), with: .color(color)) }
            }
            // feine Segmentierung: 1-pt-Luecke alle 3 pt in der Spurfarbe (erst ausstanzen, dann Spur einsetzen)
            var gaps = Path()
            var yy = trackRect.minY + 2
            while yy < bottom { gaps.addRect(CGRect(x: 0, y: yy, width: Geo.meterW, height: 1)); yy += 3 }
            c.blendMode = .destinationOut
            c.fill(gaps, with: .color(.black))
            c.blendMode = .normal
            c.fill(gaps, with: .color(track))
            // Peak-Hold-Strich
            if s.hold > -70 {
                c.fill(Path(CGRect(x: 0, y: y(s.hold) - 1, width: Geo.meterW, height: 2)),
                       with: .color(Color.primary.opacity(0.8)))
            }

            // Zielzone als duenne Linie zwischen Meter und Teilstrichen
            let zoneX = Geo.meterW + 2
            for (lo, hi, color) in [(-18.0, -6.0, Color.green), (-6.0, -3.0, Color.orange), (-3.0, 0.0, Color.red)] {
                let r = CGRect(x: zoneX, y: y(hi), width: 2, height: y(lo) - y(hi))
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(color.opacity(0.7)))
            }

            // Skala: Nebenteilstriche (kurz, ohne Zahl), Hauptteilstriche mit Beschriftung
            let x0 = Geo.meterW + Geo.gap
            for db in Geo.minorTicks {
                var t = Path()
                t.move(to: CGPoint(x: x0, y: y(db))); t.addLine(to: CGPoint(x: x0 + 2.5, y: y(db)))
                ctx.stroke(t, with: .color(Color.secondary.opacity(0.6)), lineWidth: 0.5)
            }
            for db in Geo.majorTicks {
                let yt = y(db)
                let strong = db == -18
                var t = Path()
                t.move(to: CGPoint(x: x0, y: yt)); t.addLine(to: CGPoint(x: x0 + (strong ? 5 : 4), y: yt))
                ctx.stroke(t, with: .color(Color.secondary.opacity(strong ? 0.9 : 0.6)), lineWidth: strong ? 1.25 : 0.75)
                let label = db == 0 ? "0" : "−\(Int(-db))"
                ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x0 + 7, y: yt), anchor: .leading)
            }
        }
        .frame(width: totalW, height: Geo.height)
        .accessibilityHidden(true)
    }
}
