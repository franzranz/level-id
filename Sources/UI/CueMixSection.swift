// CueMixSection.swift – Cue-Blend Mikrofon <-> PC je Mix, eingeklappt (P5).
import SwiftUI

struct CueMixSection: View {
    @ObservedObject var controller: DeviceController
    /// Blend-Regler gesperrt (nicht ansprechbar / Beta nur lesend). Das Aufklappen bleibt immer moeglich.
    var locked = false
    /// Inhalt sichtbar? Umschalten ohne Animation, damit oberhalb nichts springt.
    @State private var expanded = false
    /// Nur für das Chevron: dreht sich mit kurzer Animation.
    @State private var chevronOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { chevronOpen.toggle() }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Cue-Mix")
                        .font(.headline)
                        .help("Cue mix: what you hear while recording. Blend your live microphone with the computer playback for the monitors and the headphones.")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(chevronOpen ? 90 : 0))
                        .animation(.easeOut(duration: 0.15), value: chevronOpen)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    CueBlendRow(controller: controller, mix: 0, title: "Monitor")
                    CueBlendRow(controller: controller, mix: 1, title: "Headphones")
                }
                .disabled(locked)
                .padding(.top, 2)
            }
        }
    }
}

/// Eine Zeile je Mix: Titel, Mix-Prozent und Regler Mikrofon (0) <-> PC (1).
private struct CueBlendRow: View {
    @ObservedObject var controller: DeviceController
    let mix: Int
    let title: String

    var body: some View {
        let b = controller.state.cueBlend(mix: mix)
        let pc = Int((b * 100).rounded())
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text("Mic \(100 - pc) % · Computer \(pc) %")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Current blend: share of the live microphone and of the computer playback. The overall loudness stays constant.")
            }
            BlendSlider(value: b,
                        onSet: { controller.setCueBlend(mix: mix, $0) },
                        onReset: { controller.setCueBlend(mix: mix, DeviceState.cueBlendDefault) })
                .help("Blend between live microphone (left) and computer playback (right). Double-click: back to 100 % Computer.")
        }
    }
}

/// Kapsel-Regler im Stil der Lautstaerke-Schieber (ohne Fuellung, da es ein Mischverhaeltnis ist). Links Mikrofon, rechts Computer.
private struct BlendSlider: View {
    let value: Double          // 0 = nur Mikrofon ... 1 = nur Computer
    let onSet: (Double) -> Void
    let onReset: () -> Void

    private let height: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knobX = min(max(w * value, height / 2), w - height / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .tertiarySystemFill))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: height - 2, height: height - 2)
                    .offset(x: knobX - height / 2 + 1)
            }
            .frame(width: w, height: height)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onSet(min(max(g.location.x / w, 0), 1))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        }
        .frame(height: height)
        .focusable(true)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            nudge(press.key == .rightArrow ? 0.05 : -0.05)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cue mix blend")
        .accessibilityValue(Text("Mic \(100 - Int((value * 100).rounded())) percent, Computer \(Int((value * 100).rounded())) percent"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: nudge(0.05)
            case .decrement: nudge(-0.05)
            default: break
            }
        }
    }

    private func nudge(_ d: Double) { onSet(min(max(value + d, 0), 1)) }
}
