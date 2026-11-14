// PanelView.swift – Hauptpanel im Menueleisten-Fenster (P5).
import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var controller: DeviceController
    @State private var showSettings = false

    private var isUnresponsive: Bool { controller.connection == .unresponsive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audient ID14")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Status nur bei Abweichungen vom Normalfall (verbunden)
                if controller.connection == .disconnected || controller.connection == .passive {
                    statusLine
                }
            }
            if isUnresponsive {
                Text("ID14 is not responding – please unplug it and plug it back in.")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            if controller.connection != .disconnected {
                MonitorSection(controller: controller, onOpenSettings: { showSettings = true })
                    .disabled(isUnresponsive)
                Divider()
                InputsSection(controller: controller, meters: controller.meters)
                Divider()
                CueMixSection(controller: controller)
                    .disabled(isUnresponsive)
            }
            footer
        }
        // Unten 7,5 pt: Symbole der Fußzeile haben 6,5 pt Luft im Button, also 14 pt zum Rand
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 7.5)
        .frame(width: 320)
    }

    private var statusLine: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Connection status of the Audient ID14.")
    }

    private var statusIcon: String {
        switch controller.connection {
        case .disconnected: return "bolt.slash"
        case .connected, .passive: return "bolt.fill"
        case .unresponsive: return "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch controller.connection {
        case .disconnected: return "ID14 not connected"
        case .connected: return "Connected"
        case .passive: return "Original iD is running – read-only"
        case .unresponsive: return "Not responding"
        }
    }

    /// Fußzeile: Zahnrad (Settings) links, Ausschalten rechts, gleiche Größe und Höhe.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .center) {
                FooterIconButton(systemName: "gearshape", size: 17, help: "Settings") {
                    showSettings.toggle()
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsView(controller: controller)
                }
                Spacer()
                FooterIconButton(systemName: "power", size: 18, help: "Quit the app") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .frame(height: 30)
            // Symbol-Luft von 6,5 pt pro Seite nach außen ziehen, damit Symbole 14 pt vom Rand stehen
            .padding(.horizontal, -6.5)
        }
        // Abstand zum Inhalt darüber: 12 pt aus der VStack minus 4 pt = 8 pt bis zum Divider
        .padding(.top, -4)
    }
}

/// Symbol-Button der Fußzeile mit dezentem Hover-Hintergrund.
private struct FooterIconButton: View {
    let systemName: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
