// SettingsView.swift – Einstellungen im Popover am Zahnrad (P5).
// Erklärungen stehen als Tooltips (.help) an den Bedienelementen.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DeviceController
    @State private var launchAtLogin = false
    @State private var showVerify = false

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

            group("Input meters") {
                HStack {
                    Text("Peak hold")
                    Spacer()
                    Picker("Peak hold", selection: Binding(
                        get: { state.ui.peakHold },
                        set: { controller.setPeakHold($0) })) {
                        Text("2 s").tag(2.0)
                        Text("4 s").tag(4.0)
                        Text("6 s").tag(6.0)
                        Text("∞").tag(0.0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .help("How long the peak value and peak line stay up before they follow the level again. ∞ keeps the highest peak until you click the number.")
            }

            if controller.profile.functionKeyCount > 1 {
                // Mehrtasten-Geraete (iD24/iD44): Belegung nur lokal gespeichert, kein USB-Befehl (Protokoll unbekannt)
                group("Function keys") {
                    ForEach(0..<controller.profile.functionKeyCount, id: \.self) { i in
                        HStack {
                            Text(controller.profile.functionKeyNames[i])
                            Spacer()
                            Picker(controller.profile.functionKeyNames[i], selection: Binding(
                                get: { state.monitor.functionKey(i) },
                                set: { controller.setFunctionKey(i, $0) })) {
                                ForEach(controller.profile.functionKeyModes, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    Text("Saved in the app only for now; not sent to the interface.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
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
            .disabled(controller.connection == .passive || controller.connection == .unresponsive || controller.readOnlyBeta)
            .help(controller.connection == .passive ? "Not available while the original iD app is running."
                  : controller.readOnlyBeta ? "Not available until this device is verified (read-only)."
                  : controller.connection == .unresponsive ? "Not available while the ID14 is not responding." : "")
            }

            // Nur bei Beta-Geraeten (readOnlyBeta): Hinweis und Pruefliste fuer die Rueckmeldung
            if controller.readOnlyBeta {
                group("Device support") {
                    Text(controller.profile.supportLevel == .unverified
                         ? "This \(controller.profile.name) is unverified and runs read-only until an owner confirms it."
                         : "This \(controller.profile.name) runs in read-only beta.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Help verify this device…") { showVerify = true }
                        .help("Checks the controls you use and prepares a report you can paste into a GitHub issue. Nothing is sent automatically.")
                }
            }

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

            group("Updates") {
                UpdatesRows(controller: controller)
            }

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text("Level iD \(Updater.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/franzranz/level-id")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            launchAtLogin = SingleInstance.loginEnabled
        }
        .sheet(isPresented: $showVerify) {
            DeviceVerifyView(controller: controller)
        }
    }

    /// Update-Gruppe: optionale Pruefung, "Check now", Status, Installation bzw. Release-Seite
    private struct UpdatesRows: View {
        @ObservedObject var controller: DeviceController
        @ObservedObject private var updater = Updater.shared

        private var statusText: String? {
            switch updater.status {
            case .idle: return nil
            case .checking: return "Checking…"
            case .upToDate: return "Up to date"
            case .available(let v, _): return "Version \(v) is available"
            case .downloading: return "Downloading…"
            case .installing: return "Installing…"
            case .failed(let why): return "Update failed: \(why)"
            }
        }

        var body: some View {
            HStack {
                Toggle("Check automatically", isOn: Binding(
                    get: { controller.state.ui.autoUpdateCheck },
                    set: { on in
                        controller.setAutoUpdateCheck(on)
                        if on { updater.checkIfDue() }
                    }))
                    .toggleStyle(.checkbox)
                    .help("Asks GitHub once a day whether a new version exists. Off by default. Nothing but the request itself is sent.")
                Spacer()
                Button("Check now") { updater.check() }
                    .controlSize(.small)
                    .disabled(updater.isBusy)
            }
            if case .available(let v, let url) = updater.status {
                HStack(spacing: 6) {
                    Text("Version \(v) is available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Notes", destination: url)
                        .font(.caption)
                    Spacer()
                    if updater.installNote == nil {
                        Button("Install") { updater.install() }
                            .controlSize(.small)
                            .help("Downloads the update, checks checksum and signature, replaces the app and restarts it.")
                    } else {
                        Button("Open release page") { updater.openReleasePage() }
                            .controlSize(.small)
                    }
                }
                if let note = updater.installNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if let t = statusText {
                    Text(t)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed = updater.status, updater.releaseURL != nil {
                    Button("Open release page") { updater.openReleasePage() }
                        .controlSize(.small)
                }
            }
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
