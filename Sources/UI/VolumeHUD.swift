// VolumeHUD.swift – kleines Overlay fuer die Mac-Lautstaerketasten (Balken + dB-Wert), nur kurz sichtbar.
import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    @Published var dB: Double = DB.minimum
    @Published var muted = false
    @Published var headphones = false
    @Published var fine = false
}

private struct VolumeHUDView: View {
    @ObservedObject var model: HUDModel

    private var fraction: Double {
        VolumeStep.fraction(model.dB)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.muted ? "speaker.slash.fill"
                  : (model.headphones ? "headphones" : "speaker.wave.2.fill"))
                .font(.title3)
                .frame(width: 26)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                GeometryReader { geo in
                    Capsule()
                        .fill(model.muted ? Color.secondary : Color.primary)
                        .frame(width: geo.size.width * (model.muted ? 0 : fraction))
                }
            }
            .frame(width: 130, height: 6)
            Text(model.muted ? "muted" : dbText(model.dB, fine: model.fine))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8)
    }
}

/// Randloses, nicht aktivierendes Panel. Es gibt keine Dauer-Timer: der Ausblend-Timer laeuft nur, solange es sichtbar ist.
@MainActor
final class VolumeHUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTimer: Timer?
    /// Zaehlt jedes show(); ein Ausblenden darf das Panel nur schliessen, wenn seitdem keine neue Taste kam
    private var generation = 0

    func show(dB: Double, muted: Bool, headphones: Bool, fine: Bool) {
        model.dB = dB
        model.muted = muted
        model.headphones = headphones
        model.fine = fine

        let p = panel ?? makePanel()
        panel = p
        position(p)
        generation += 1
        // Laufende Ausblend-Animation abbrechen (sonst faehrt Alpha weiter auf 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: VolumeHUDView(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }

    /// Unten mittig (ca. 15 % vom unteren Rand) auf dem Bildschirm mit der Maus
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                 y: f.minY + f.height * 0.15 - size.height / 2))
    }

    private func fadeOut() {
        hideTimer = nil
        guard let p = panel else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Nur ausblenden, wenn in der Zwischenzeit keine neue Taste kam
                if self.generation == gen { p.orderOut(nil) }
            }
        })
    }
}
