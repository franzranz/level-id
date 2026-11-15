// MonitorSection.swift – Monitor- und Kopfhoerer-Lautstaerke (P5).
// Enthaelt auch die gemeinsamen Helfer dbText und ScrollWheelCatcher.
import SwiftUI
import AppKit

/// Ab diesem Wert gilt ein Pegel als „aus“ (wird beim Ziehen zu -128).
let offThresholdDB: Double = DB.offThreshold

/// Anzeige eines dB-Wertes, z.B. „−23 dB“ (ganze dB; der Schieber bleibt fein). Werte <= offAt erscheinen als „aus“ (nil = nie).
func dbText(_ v: Double, offAt: Double? = offThresholdDB, fine: Bool = false) -> String {
    if let o = offAt, v <= o { return "off" }
    if fine {
        let t = (v * 10).rounded() / 10
        return decimalText(t, digits: 1) + "\u{00A0}dB"
    }
    let r = Int(v.rounded())
    return (r < 0 ? "−\(-r)" : "\(r)") + "\u{00A0}dB"
}

/// Zahl mit Dezimaltrenner des Systems und typografischem Minus, z.B. „−19,5“ oder „−19.5“.
func decimalText(_ v: Double, digits: Int) -> String {
    let s = String(format: "%.\(digits)f", v)
        .replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
        .replacingOccurrences(of: "-", with: "−")
    return s.hasPrefix("−0") && Double(s.dropFirst().replacingOccurrences(of: ",", with: ".")) == 0
        ? String(s.dropFirst()) : s
}

/// Merkt, ob gerade Shift gedrueckt ist (fuer die Feinanzeige). Ein einziger lokaler Monitor, nur bei Tasten-Ereignissen aktiv.
@MainActor
final class ShiftKeyState: ObservableObject {
    static let shared = ShiftKeyState()
    @Published private(set) var down = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let d = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated { self?.update(d) }
            return event
        }
    }

    private func update(_ d: Bool) { if d != down { down = d } }
}

struct MonitorSection: View {
    @ObservedObject var controller: DeviceController
    /// Oeffnet die Einstellungen (Link im Speaker-Paar-Menue)
    var onOpenSettings: () -> Void = {}

    var body: some View {
        let state = controller.state
        let dual = controller.profile.headphoneCount == 2
        VStack(alignment: .leading, spacing: 14) {
            LevelRow(title: "Monitor",
                     value: state.monitor.volumeDB,
                     onSet: { controller.setMonitorVolume($0) },
                     isMuted: state.monitor.cut,
                     onToggleMute: { controller.setCut(!state.monitor.cut) },
                     badges: [
                         state.monitor.dim ? Badge(text: "Dim", color: Color.secondary.opacity(0.2)) : nil,
                         state.monitor.mono ? Badge(text: "Mono", color: Color.secondary.opacity(0.2)) : nil,
                         state.monitor.speakerSelect == 1 ? Badge(text: "Pair 2", color: Color.secondary.opacity(0.2)) : nil,
                     ].compactMap { $0 },
                     accessory: AnyView(SpeakerPairButton(controller: controller, onOpenSettings: onOpenSettings)),
                     titleHelp: state.monitor.speakerSelect == 1
                        ? "Volume of monitor speaker pair 2: Output 3 (left) and Output 4 (right) on the rear of the interface. Scroll to change in 1 dB steps; hold Shift for 0.1 dB steps."
                        : "Volume of monitor speaker pair 1: Output 1 (left) and Output 2 (right) on the rear of the interface. Scroll to change in 1 dB steps; hold Shift for 0.1 dB steps.")
            LevelRow(title: dual ? "Headphones 1" : "Headphones",
                     value: state.phonesVolumeDB,
                     onSet: { controller.setPhonesVolume($0) },
                     isMuted: state.monitor.phonesCut,
                     onToggleMute: { controller.setPhonesCut(!state.monitor.phonesCut) },
                     overrideText: controller.phonesChangedOnDevice ? "set on device" : nil,
                     badges: [
                         state.monitor.talkback ? Badge(text: "Talkback", color: Color.orange.opacity(0.25)) : nil,
                     ].compactMap { $0 },
                     accessory: dual ? nil : AnyView(HeadphonesInfoButton()),
                     titleHelp: dual
                        ? "Volume of headphone output 1. Scroll to change in 1 dB steps; hold Shift for 0.1 dB steps."
                        : "Volume of the headphone output. Both headphone jacks share this volume and cannot be controlled separately. Scroll to change in 1 dB steps; hold Shift for 0.1 dB steps.")
            if dual {
                LevelRow(title: "Headphones 2",
                         value: state.phones2VolumeDB,
                         onSet: { controller.setPhones2Volume($0) },
                         isMuted: state.monitor.phones2Cut,
                         onToggleMute: { controller.setPhones2Cut(!state.monitor.phones2Cut) },
                         titleHelp: "Second headphone output (iD44). Control is local only until this device is verified.")
            }
        }
    }
}

/// Kleines Status-Badge in der Kopfzeile einer Pegelzeile.
struct Badge: Identifiable {
    let text: String
    let color: Color
    var id: String { text }
}

/// Eine Pegelzeile: Kopfzeile (Titel, dB-Text) und darunter der VolumeSlider.
private struct LevelRow: View {
    let title: String
    let value: Double          // roher Wert, -128 = aus
    let onSet: (Double) -> Void
    let isMuted: Bool
    let onToggleMute: () -> Void
    /// Ersatztext statt dB-Wert (z.B. wenn der Geraeteregler verstellt wurde)
    var overrideText: String? = nil
    /// Status-Badges neben dem Titel (z.B. „Dim“, „Mono“, „Talkback“)
    var badges: [Badge] = []
    /// Optionales, leises Zusatzelement rechts neben den Badges (z.B. Speaker-Paar-Umschalter)
    var accessory: AnyView? = nil
    /// Tooltip der Ueberschrift (haengt beim Monitor vom aktiven Paar ab)
    var titleHelp: String = ""

    @ObservedObject private var shift = ShiftKeyState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                    .help(titleHelp)
                if let accessory { accessory }
                HStack(spacing: 4) {
                    ForEach(badges) { badge in
                        Text(badge.text)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(badge.color))
                            .help(Self.badgeHelp(badge.text))
                    }
                }
                Spacer()
                valueLabel
            }
            VolumeSlider(label: title,
                         value: value,
                         muted: isMuted,
                         valueText: isMuted ? "muted" : (overrideText ?? dbText(value)),
                         onSet: onSet,
                         onToggleMute: onToggleMute)
        }
    }

    private static func badgeHelp(_ text: String) -> String {
        switch text {
        case "Dim": return "Dim is on: the monitors are turned down temporarily."
        case "Mono": return "Mono is on: left and right are summed, for checking mono compatibility."
        case "Pair 2": return "Monitor speaker pair 2 (Output 3/4) is active."
        case "Talkback": return "Talkback is active: your microphone is routed to the headphones only."
        default: return text
        }
    }

    @ViewBuilder private var valueLabel: some View {
        if isMuted {
            Text("muted")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else if let text = overrideText {
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .help("Changed with the knob on the interface – the device does not report this value. Moving the slider sets it again.")
        } else {
            Text(dbText(value, fine: shift.down))
                .font(.title3)
                .monospacedDigit()
        }
    }
}

/// Fängt Scrollrad-Ereignisse über dem umgebenden Bereich ab (lokaler Event-Monitor).
struct ScrollWheelCatcher: NSViewRepresentable {
    /// (nach oben?, Shift gedrückt?)
    let onScroll: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.onScroll = onScroll
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            guard let coordinator, let v = coordinator.view, let window = v.window, event.window === window else {
                return event
            }
            guard v.bounds.contains(v.convert(event.locationInWindow, from: nil)) else { return event }
            coordinator.handle(event)
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onScroll: ((Bool, Bool) -> Void)?
        private var accumulated: CGFloat = 0

        /// Schrittweise: Trackpad-Deltas werden gesammelt, ein Schritt je Schwelle.
        func handle(_ event: NSEvent) {
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 1
            accumulated += event.scrollingDeltaY
            let shift = event.modifierFlags.contains(.shift)
            while abs(accumulated) >= threshold {
                let up = accumulated > 0
                accumulated -= up ? threshold : -threshold
                onScroll?(up, shift)
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                accumulated = 0
            }
        }
    }
}

/// Leiser Umschalter fuer das Monitor-Lautsprecherpaar (Main/Alt). Absichtlich dezent: kleines Symbol in der
/// Zweitfarbe, Menue mit Erklaerung. Haeufige Nutzer legen "Alt speakers" auf die iD-Taste (Settings).
private struct SpeakerPairButton: View {
    @ObservedObject var controller: DeviceController
    let onOpenSettings: () -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let alt = controller.state.monitor.speakerSelect == 1
        Button { open.toggle() } label: {
            Image(systemName: "speaker.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering || alt ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch monitor speaker pair. Pair 1 is Output 1/2, pair 2 is Output 3/4.")
        .accessibilityLabel("Switch monitor speaker pair")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                pairRow("Pair 1", detail: "Output 1/2", selected: !alt) { controller.setSpeakerAlt(false) }
                pairRow("Pair 2", detail: "Output 3/4", selected: alt) { controller.setSpeakerAlt(true) }
                Divider().padding(.vertical, 4)
                (Text("Switch faster: set the iD button to “Alt speakers” in ")
                 + Text("Settings").foregroundColor(.accentColor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .onTapGesture { open = false; onOpenSettings() }
            }
            .padding(6)
            .frame(width: 220)
        }
    }

    private func pairRow(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Leises Symbol neben „Headphones“: nur Anzeige mit Tooltip, nicht klickbar.
private struct HeadphonesInfoButton: View {
    var body: some View {
        Image(systemName: "headphones")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .help("The two headphone jacks cannot be controlled separately: they always share this volume and the same mix. Use the Cue-Mix below to set what you hear.")
            .accessibilityLabel("Both headphone jacks share one volume")
    }
}
