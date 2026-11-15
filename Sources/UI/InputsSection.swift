// InputsSection.swift – Mic 1/2 mit Pegelmeter (ProMeterView).
// Keine Gain- und 48V-Regler: diese gibt es am Geraet nur analog.
// Beobachtet nur MeterModel, damit Controller-Updates dieses Panel nicht neu rendern.
import SwiftUI

struct InputsSection: View {
    let controller: DeviceController
    @ObservedObject var meters: MeterModel

    var body: some View {
        InputsContent(channels: meters.mics, live: meters.live, preview: false,
                      holdSeconds: meters.peakHoldSeconds,
                      readout: meters.levelReadout,
                      onReset: { meters.resetPeak(mic: $0) },
                      onToggleReadout: { controller.setLevelReadout($0 == .rms ? .ppm : .rms) })
    }
}

/// Reine Darstellung (auch fuer den Vorschau-Modus mit festen Werten)
struct InputsContent: View {
    let channels: [MeterModel.Channel]
    let live: Bool
    var preview = false
    var holdSeconds: Double = UIPreferences.peakHoldDefault
    var readout: UIPreferences.LevelReadout = .rms
    let onReset: (Int) -> Void
    var onToggleReadout: (UIPreferences.LevelReadout) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input levels")
                .font(.headline)
                .help(channels.count == 4
                      ? "Level meters for Mic/Line inputs 1 to 4, for setting the gain on the interface."
                      : "Level meters for Mic/Line inputs 1 and 2 (or the Hi-Z instrument input, which uses Input 1), for setting the gain on the interface.")
            ProMeterView(channels: channels, live: live, preview: preview, holdSeconds: holdSeconds,
                         readout: readout, onReset: onReset, onToggleReadout: onToggleReadout)
        }
    }
}
