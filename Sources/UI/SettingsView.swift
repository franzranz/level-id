// SettingsView.swift – Einstellungen im Popover am Zahnrad (P5).
// Erklärungen stehen als Tooltips (.help) an den Bedienelementen.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DeviceController
    @State private var launchAtLogin = false

    var body: some View {
        let state = controller.state
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            group("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        SingleInstance.setLoginItem(on, controller: controller)
                        launchAtLogin = SingleInstance.loginEnabled
            MediaKeyStatus.shared.retry()
                    }))
                    .help("Starts the app at login and restarts it automatically after a crash.")
                Toggle("Hide icon when disconnected", isOn: Binding(
                    get: { state.ui.hideIconWhenDisconnected },
                    set: { controller.setHideIconWhenDisconnected($0) }))
                    .help("The menu bar icon only appears while an ID14 is plugged in. Off = icon always visible.")
            }

            group("Volume") {
                Toggle("Remember volume", isOn: Binding(
                    get: { state.restore.rememberVolume },
                    set: { controller.setRememberVolume($0) }))
                    .help(state.restore.rememberVolume
                          ? "After plugging in, the last used volume is faded back in."
                          : "After plugging in, monitor and headphones start muted.")
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Safe start level")
                            .help("Limits how loud monitor and headphones come back after plugging in. Protects your ears and speakers. “Off” = no limit.")
                        Spacer()
                        Text(capText(state.restore))
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { min(max(state.restore.monitorCapDB, RestorePreferences.capRange.lowerBound),
                                   RestorePreferences.capRange.upperBound) },
                        set: { controller.setRestoreCap(($0 / 5).rounded() * 5) }),
                           in: RestorePreferences.capRange, step: 5)
                        .help("Highest volume after plugging in, in 5 dB steps (−30 … −5 dB). Applies to monitor and headphones. Furthest right = Off, no limit.")
                    HStack {
                        Text("−30")
                        Spacer()
                        Text("Off")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .disabled(!state.restore.rememberVolume)
                .help(state.restore.rememberVolume ? "" : "Turn on “Remember volume” to use this.")
            }

            group("Device") {
                HStack {
                    Text("iD button")
                        .help("What the iD button on the interface does when pressed.")
                    Spacer()
                    Picker("iD button", selection: Binding(
                        get: { state.monitor.idKeyChoice },
                        set: { controller.setIDKeyChoice($0) })) {
                        ForEach(IDKeyChoice.selectable, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("What the iD button on the interface does. “Alt speakers” switches between monitor pair 1 (Output 1/2) and pair 2 (Output 3/4); the best choice if you switch often.")
                }
                if state.monitor.idKey == .cut {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mutes")
                            .help("What the iD button mutes when you press it.")
                        Picker("Mutes", selection: Binding(
                            get: { state.monitor.muteTarget },
                            set: { controller.setMuteTarget($0) })) {
                            Text("Monitor").tag(MuteTarget.monitor)
                            Text("Both").tag(MuteTarget.both)
                            Text("Headphones").tag(MuteTarget.headphones)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(muteTargetNote(state.monitor.muteTarget))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.monitor.idKey == .talkback {
                    Divider()
                    HStack {
                        Text("Talkback mic")
                        Spacer()
                        Picker("Talkback mic", selection: Binding(
                            get: { state.monitor.talkbackSource },
                            set: { controller.setTalkbackSource($0) })) {
                            ForEach(TalkbackSource.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .help(talkbackHelp(state.monitor.talkbackSource))
                    }
                }
            }
            .disabled(controller.connection == .passive || controller.connection == .unresponsive)
            .help(controller.connection == .passive ? "Not available while the original iD app is running."
                  : controller.connection == .unresponsive ? "Not available while the ID14 is not responding." : "")

            // Eigene Gruppe: Toggle und Berechtigung bleiben auch im Passiv-Modus bedienbar (reine App-Einstellung)
            group("Mac volume keys") {
                Toggle("Use Mac volume keys", isOn: Binding(
                    get: { state.ui.volumeKeys },
                    set: { controller.setVolumeKeys($0) }))
                    .help("Volume keys control the ID14 while it is the Mac's sound output. Shift = 0.1 dB steps.")
                if state.ui.volumeKeys {
                    HStack {
                        Text("Controls")
                        Spacer()
                        Picker("Controls", selection: Binding(
                            get: { state.ui.volumeKeysTarget },
                            set: { controller.setVolumeKeysTarget($0) })) {
                            Text("Monitor").tag(UInt8(0))
                            Text("Headphones").tag(UInt8(1))
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    VolumeKeysPermissionRow()
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            launchAtLogin = SingleInstance.loginEnabled
        }
    }

    /// Hinweis auf fehlende Bedienungshilfen-Berechtigung (nur sichtbar, solange der Tap nicht angelegt werden kann)
    private struct VolumeKeysPermissionRow: View {
        @ObservedObject private var tap = MediaKeyStatus.shared

        var body: some View {
            if tap.needsPermission {
                HStack {
                    Text("Needs Accessibility permission")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Kategorie: heading in capitals, content in a box.
    @ViewBuilder private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternarySystemFill)))
        }
    }

    private func muteTargetNote(_ t: MuteTarget) -> String {
        switch t {
        case .monitor: return "The button mutes the monitor speakers."
        case .both: return "The button mutes monitor and headphones together."
        case .headphones: return "The button mutes the headphones only. The monitor may click briefly."
        }
    }

    /// Tooltip für den Talkback-Picker: beide Hinweise zusammen
    private func talkbackHelp(_ source: TalkbackSource) -> String {
        let base = "Press the button = talkback on, press again = off. Headphones only."
        return source == .mac
            ? base + "\nThe first time, macOS asks for microphone access."
            : base
    }

    /// „−30 dB“ … „−1 dB“, if capIsOff: “Off”
    private func capText(_ r: RestorePreferences) -> String {
        if r.capIsOff { return "Off" }
        return "\(Int(r.monitorCapDB.rounded()))".replacingOccurrences(of: "-", with: "−") + " dB"
    }
}
