// DeviceVerifyView.swift – Sheet "Help verify this device" fuer Beta-Geraete (readOnlyBeta).
// Erkennt die Schritte NUR durch Beobachten bereits veroeffentlichter Werte. Keine Schreibzugriffe, keine neuen USB-Anfragen.
// Einzige Ausnahme: Das Metering wird waehrend des Sheets eingeschaltet (wie beim offenen Panel) und danach zurueckgesetzt.
import AppKit
import SwiftUI

/// Monitor-Schalter, die sich durch die iD-Taste aendern koennen
private struct MonitorFlags: Equatable {
    let dim: Bool
    let cut: Bool
    let mono: Bool
    let talkback: Bool
}

struct DeviceVerifyView: View {
    @ObservedObject var controller: DeviceController
    @ObservedObject private var meters: MeterModel
    @Environment(\.dismiss) private var dismiss

    /// Lautstaerke beim Oeffnen (nil, solange das Geraet noch keinen gueltigen Wert geliefert hat)
    @State private var startVolume: Double?
    @State private var volumeTurned = false
    /// Kopfhoerer-Regler: nicht lesbar, daher von Hand angehakt
    @State private var headphoneConfirmed = false
    @State private var buttonPressed = false
    /// Je Eingang: hat der Pegel einmal ueber -40 dB gelegen?
    @State private var inputSeen: [Bool]
    /// Hoechster beobachteter Pegel je Eingang (fuer den Bericht)
    @State private var peaks: [Double]
    @State private var sawDisconnect = false
    @State private var replugged = false
    @State private var wasMetering = false
    @State private var hint: String?

    private static let inputThresholdDB = -40.0

    init(controller: DeviceController) {
        _controller = ObservedObject(wrappedValue: controller)
        _meters = ObservedObject(wrappedValue: controller.meters)
        let n = max(controller.profile.preampCount, 1)
        _inputSeen = State(initialValue: Array(repeating: false, count: n))
        _peaks = State(initialValue: Array(repeating: DB.minimum, count: n))
    }

    // MARK: Schritte

    private var steps: [(String, Bool)] {
        [("Turn the volume knob", volumeTurned),
         ("Turn the headphone knob", headphoneConfirmed),
         ("Press the iD button", buttonPressed),
         ("Speak into each input", inputSeen.allSatisfy { $0 }),
         ("Unplug and plug in again", replugged)]
    }

    private var checkedCount: Int { steps.filter { $0.1 }.count }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private var reportText: String {
        DeviceReport.make(profileName: controller.profile.name, productID: controller.profile.productID,
                          appVersion: appVersion, macOSVersion: macOSVersion, steps: steps,
                          monitorVolumeDB: controller.state.monitor.volumeDB, meterPeaks: peaks)
    }

    var body: some View {
        let monitor = controller.state.monitor
        VStack(alignment: .leading, spacing: 12) {
            Text("Help verify this device")
                .font(.headline)
            Text("Try each control once. Steps tick by themselves, except the headphone knob.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                stepRow("Turn the volume knob", done: volumeTurned)
                manualStepRow("Turn the headphone knob", done: headphoneConfirmed) {
                    headphoneConfirmed.toggle()
                }
                stepRow("Press the iD button", done: buttonPressed)
                stepRow("Speak into each input", done: inputSeen.allSatisfy { $0 })
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(inputSeen.indices, id: \.self) { i in
                        stepRow("Input \(i + 1)", done: inputSeen[i], indented: true)
                    }
                }
                stepRow("Unplug and plug in again", done: replugged)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternarySystemFill)))

            HStack {
                Button("Copy report") { copyReport() }
                Button("Open GitHub issue") { openIssue() }
                    .disabled(checkedCount < 3)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            wasMetering = controller.meteringEnabled
            controller.meteringEnabled = true
            startVolume = monitor.volumeDB > DB.minimum + 0.01 ? monitor.volumeDB : nil
        }
        .onDisappear {
            controller.meteringEnabled = wasMetering
        }
        .onChange(of: controller.state.monitor.volumeDB) { _, new in
            volumeChanged(to: new)
        }
        .onChange(of: MonitorFlags(dim: monitor.dim, cut: monitor.cut, mono: monitor.mono,
                                   talkback: monitor.talkback)) { _, _ in
            buttonPressed = true
        }
        .onChange(of: meters.mics) { _, new in
            inputsChanged(new)
        }
        .onChange(of: controller.connection) { _, new in
            if new == .disconnected {
                sawDisconnect = true
            } else if new == .connected, sawDisconnect {
                replugged = true
            }
        }
    }

    // MARK: Beobachtung

    /// Lautstaerke: ab 1 dB Abweichung vom Wert beim Oeffnen gilt der Regler als gedreht.
    private func volumeChanged(to v: Double) {
        guard v > DB.minimum + 0.01 else { return }
        guard let start = startVolume else {
            startVolume = v
            return
        }
        if abs(v - start) >= 1 { volumeTurned = true }
    }

    private func inputsChanged(_ mics: [MeterModel.Channel]) {
        for i in inputSeen.indices where i < mics.count {
            let level = mics[i].levelDB
            guard level.isFinite else { continue }
            if level > peaks[i] { peaks[i] = level }
            if level > Self.inputThresholdDB { inputSeen[i] = true }
        }
    }

    // MARK: Aktionen

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        hint = "Report copied."
    }

    private func openIssue() {
        copyReport()
        guard let url = DeviceReport.issueURL(profileName: controller.profile.name) else { return }
        NSWorkspace.shared.open(url)
        hint = "Report copied – paste it into the issue."
    }

    // MARK: Zeilen

    private func stepRow(_ title: String, done: Bool, indented: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(title)
                .font(indented ? .caption : .body)
            Spacer()
        }
        .padding(.leading, indented ? 24 : 0)
    }

    private func manualStepRow(_ title: String, done: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            stepRow(title, done: done)
        }
        .buttonStyle(.plain)
        .help("Tick it yourself once the knob changes the headphone level audibly. The level cannot be read from the device.")
    }
}
