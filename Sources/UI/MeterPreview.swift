// MeterPreview.swift – Vorschau-Modus: rendert die Eingangs-Meter mit Beispielwerten als PNG (hell und dunkel).
// Aufruf: ID14Control --render-meter-preview <Ausgabeordner>. Kein USB, keine Sperre, danach exit(0).
import AppKit
import SwiftUI

@MainActor
enum MeterPreview {
    static let flag = "--render-meter-preview"

    /// Ganz am Anfang aufrufen (vor Einzelinstanz-Pruefung und Controller). Kehrt nur zurueck, wenn der Modus nicht aktiv ist.
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag) else { return }
        let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failed = false
        for (name, scheme) in [("meter-light.png", ColorScheme.light), ("meter-dark.png", ColorScheme.dark)] {
            if !render(scheme: scheme, to: dir.appendingPathComponent(name)) { failed = true }
        }
        exit(failed ? 1 : 0)
    }

    private static let sample = [
        MeterModel.Channel(levelDB: -9, rmsDB: -19, maxPeakDB: -7.8, lastClipAt: nil),
        // gerade erfolgter Clip = volle Helligkeit
        MeterModel.Channel(levelDB: -2, rmsDB: -8, maxPeakDB: -0.2, lastClipAt: ProcessInfo.processInfo.systemUptime),
    ]

    private static func render(scheme: ColorScheme, to url: URL) -> Bool {
        // Breite wie im Panel: 320 pt, 14 pt Innenabstand
        let view = ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            InputsContent(channels: sample, live: false, preview: true, onReset: { _ in })
                .padding(14)
        }
        .frame(width: 320)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
