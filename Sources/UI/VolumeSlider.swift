// VolumeSlider.swift – Lautstaerke-Schieber im macOS-Stil (P5).
// Kapsel mit Lautsprechersymbol links: Tippen darauf schaltet stumm.
import SwiftUI

struct VolumeSlider: View {
    let label: String
    /// Roher Wert, -128 = aus
    let value: Double
    let muted: Bool
    /// Text fuer VoiceOver, z.B. „−23 dB“
    let valueText: String
    let onSet: (Double) -> Void
    let onToggleMute: () -> Void

    private let height: CGFloat = 24
    /// Breite links, in der das Symbol liegt. Ziehen dort ändert nichts, Tippen schaltet stumm.
    private let iconZone: CGFloat = 32

    /// Angezeigter Anteil 0...1 (−80…0)
    private var fraction: Double {
        VolumeStep.fraction(value)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobX = min(max(w * fraction, height / 2), w - height / 2)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .tertiarySystemFill))
                Capsule()
                    .fill(muted ? Color.gray : Color.white)
                    .frame(width: fraction > 0 ? knobX + height / 2 : 0)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: height - 2, height: height - 2)
                    .offset(x: knobX - height / 2 + 1)
                // Weiss mit Differenz-Mischung: dunkel auf der hellen Fuellung, hell auf der Spur
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .blendMode(muted ? .normal : .difference)
                    .frame(width: iconZone, height: height)
                    .help(muted ? "Unmute" : "Mute")
            }
            .compositingGroup()
            .frame(width: w, height: height)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard g.startLocation.x >= iconZone else { return }
                        let f = min(max(g.location.x / w, 0), 1)
                        let raw = offThresholdDB + f * -offThresholdDB
                        // Normal: ganze dB. Mit Shift: Feinstellung in 0,1 dB.
                        let step = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
                        let db = (raw / step).rounded() * step
                        onSet(db <= offThresholdDB ? DB.minimum : min(0, db))
                    }
                    .onEnded { g in
                        if g.startLocation.x < iconZone && abs(g.translation.width) < 4 {
                            onToggleMute()
                        }
                    })
        }
        .frame(height: height)
        .focusable(true)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let dir: Double = press.key == .upArrow ? 1 : -1
            change(dir, fine: press.modifiers.contains(.shift))
            return .handled
        }
        .background(ScrollWheelCatcher { up, fine in change(up ? 1 : -1, fine: fine) })
        .accessibilityValue(Text(valueText))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: change(1, fine: false)
            case .decrement: change(-1, fine: false)
            default: break
            }
        }
        .accessibilityAction(named: muted ? "Unmute" : "Mute") {
            onToggleMute()
        }
    }

    /// Schritt per Taste oder Scrollrad: 1 dB, mit Shift 0,1 dB. Ohne Shift rastet der Wert auf ganze dB ein.
    /// Aus: nach oben die erste hoerbare Stufe, nach unten bleibt es aus.
    private func change(_ dir: Double, fine isFine: Bool) {
        let next = VolumeStep.next(current: value, up: dir > 0, fine: isFine)
        if next != value { onSet(next) }
    }
}
