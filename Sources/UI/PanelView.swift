// PanelView.swift – Hauptpanel im Menueleisten-Fenster (P5).
import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var controller: DeviceController
    @State private var showSettings = false
    @ObservedObject private var updater = Updater.shared

    private var isUnresponsive: Bool { controller.connection == .unresponsive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(controller.profile == .id14mk2 ? "Audient ID14" : "Audient \(controller.profile.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                // Status nur bei Abweichungen vom Normalfall (verbunden)
                if controller.connection == .disconnected || controller.connection == .passive || betaReadOnlyShown {
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
                    .disabled(isUnresponsive || controller.readOnlyBeta)
                Divider()
                InputsSection(controller: controller, meters: controller.meters)
                if controller.profile.showsCueMix {
                    Divider()
                    // Sperre sitzt IN der Sektion: das Aufklappen muss auch bei nicht geprueften Geraeten gehen
                    CueMixSection(controller: controller, locked: isUnresponsive || controller.readOnlyBeta)
                }
            }
            footer
        }
        // Unten 7,5 pt: Symbole der Fußzeile haben 6,5 pt Luft im Button, also 14 pt zum Rand
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 7.5)
        .frame(width: 320)
        // Nach dem Schliessen der Settings (SwiftUI baut den Inhalt selbst ab) freien Speicher zurueckgeben;
        // ~1 s Verzoegerung, damit die Schliessen-Animation fertig ist
        .onAppear { updater.checkIfDue() }
        .onChange(of: showSettings) { _, isShown in
            if !isShown { MemoryRelief.relieve(after: 1) }
        }
    }

    /// Nicht geprueftes Geraet verbunden: Status-Zeile "iD24 · unverified (read-only)" bzw. "iD44 · beta (read-only)". Passiv (Original-iD) hat Vorrang.
    private var betaReadOnlyShown: Bool { controller.connection == .connected && controller.readOnlyBeta }

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
        case .connected: return betaReadOnlyShown ? "\(controller.profile.name) · \(controller.profile.statusLabel ?? "beta") (read-only)" : "Connected"
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
                if case .available = updater.status {
                    Button { showSettings = true } label: {
                        Text("Update available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help("A new version of Level iD is available. Opens Settings.")
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
