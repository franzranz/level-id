// InputsSection.swift – Mic 1/2 mit Pegelmeter (ProMeterView).
// Keine Gain- und 48V-Regler: diese gibt es am Geraet nur analog.
// Beobachtet nur MeterModel, damit Controller-Updates dieses Panel nicht neu rendern.
import SwiftUI

struct InputsSection: View {
    let controller: DeviceController
    @ObservedObject var meters: MeterModel

    var body: some View {
        InputsContent(channels: meters.mics, live: meters.live, preview: false,
                      onReset: { meters.resetPeak(mic: $0) })
    }
}

/// Reine Darstellung (auch fuer den Vorschau-Modus mit festen Werten)
struct InputsContent: View {
    let channels: [MeterModel.Channel]
    let live: Bool
    var preview = false
    let onReset: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input levels")
                .font(.headline)
                .help("Level meters for Mic/Line inputs 1 and 2 (or the Hi-Z instrument input, which uses Input 1), for setting the gain on the interface.")
            ProMeterView(channels: channels, live: live, preview: preview, onReset: onReset)
        }
    }
}
