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
        if let i = args.firstIndex(of: ReadmeImages.flag) {
            let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory())
            exit(ReadmeImages.renderAll(to: dir) ? 0 : 1)
        }
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

// MARK: - README-Bilder (--render-readme <Ordner>)

/// Rendert Panel, Einstellungen und ein Hero-Bild aus den echten Views (hell/dunkel). Kein USB, kein Zugriff auf die
/// echte state.json (temporaerer Speicherpfad, wird nie geschrieben), kein Netzwerk.
@MainActor
enum ReadmeImages {
    static let flag = "--render-readme"

    static func renderAll(to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        var ok = true
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let panelC = demoController(autoUpdate: false)
            let settingsC = demoController(autoUpdate: true)
            Updater.shared.setPreviewStatus(.upToDate)
            // Echte AppKit-Controls (Slider, Picker, Toggle) rendert nur ein NSHostingView, nicht ImageRenderer.
            let panel = snapshot(PopoverCard(content: PanelView(controller: panelC), arrowX: nil).padding(margin), scheme, appearance)
            let panelArrow = snapshot(PopoverCard(content: PanelView(controller: panelC), arrowX: heroArrowX).padding(margin), scheme, appearance)
            let settings = snapshot(PopoverCard(content: SettingsView(controller: settingsC), arrowX: nil).padding(margin), scheme, appearance)
            guard let panel, let panelArrow, let settings else { return false }
            ok = save(panel, dir, "panel-\(suffix).png") && ok
            ok = save(settings, dir, "settings-\(suffix).png") && ok
            let hero = Hero(scheme: scheme, panel: panelArrow, settings: settings)
            let renderer = ImageRenderer(content: hero.environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return false }
            // Hero ist vollflaechig deckend: ohne Alphakanal speichern (deutlich kleinere Datei)
            guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let flat = ctx.makeImage() else { return false }
            ok = save(NSBitmapImageRep(cgImage: flat), dir, "hero-\(suffix).png") && ok
        }
        return ok
    }

    static let margin: CGFloat = 56
    /// Panel-Breite 320 pt; Panel rechts mit 70 pt Rand. Pfeilmitte = Mitte des Menueleisten-Symbols.
    static let panelLeft: CGFloat = 800 - 70 - 320
    /// Direkt links neben dem Akku: Breite rechte Gruppe = 40+36+36+6+64+16 = 198 -> Akku beginnt bei 602; Symbol 34 breit, 4 pt Abstand
    static let iconX: CGFloat = 800 - 198 - 4 - 17
    static var heroArrowX: CGFloat { iconX - panelLeft }
    static let heroW: CGFloat = 800
    static let heroH: CGFloat = 720

    /// Rendert eine View in einem unsichtbaren Fenster (2x, transparenter Hintergrund).
    private static func snapshot<V: View>(_ view: V, _ scheme: ColorScheme, _ appearance: NSAppearance?) -> NSBitmapImageRep? {
        // .palette: ohne diesen Modus zeichnet cacheDisplay manche Symbole (z.B. speaker.2) unabhaengig von foregroundStyle weiss
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, scheme).environment(\.controlActiveState, .key).symbolRenderingMode(.palette)))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        // Fenster als key/main melden (Zustand wie im echten, geoeffneten Popover)
        let win = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.setFrameOrigin(CGPoint(x: -20000, y: -20000))   // ausserhalb des sichtbaren Bereichs
        win.isOpaque = false
        win.backgroundColor = .clear
        win.appearance = appearance
        win.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { win.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))   // SwiftUI baut native Controls asynchron auf
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep, _ dir: URL, _ name: String) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return false }
        print("\(name): \(rep.pixelsWide)x\(rep.pixelsHigh) px")
        return true
    }

    /// Controller mit Fake-Transport und temporaerem Speicherpfad; wird nie gestartet.
    private static func demoController(autoUpdate: Bool) -> DeviceController {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("levelid-readme-\(UUID().uuidString)/state.json")
        let c = DeviceController(transport: RecordingTransport(), store: StateStore(url: tmp),
                                 watch: { _ in }, originalAppProbe: { false })
        var s = DeviceState()
        s.monitor.volumeDB = -20
        s.phonesVolumeDB = -24
        s.monitor.idKey = .cut
        s.restore.rememberVolume = true
        s.ui.autoUpdateCheckStored = autoUpdate
        let mics = [
            MeterModel.Channel(levelDB: -10, rmsDB: -18, maxPeakDB: -8, lastClipAt: nil),
            MeterModel.Channel(levelDB: -38, rmsDB: -45, maxPeakDB: -34, lastClipAt: nil),
        ]
        c.applyPreview(state: s, connection: .connected, meters: mics)
        return c
    }

}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private struct PopoverShape: Shape {
    var radius: CGFloat = 12
    var arrowW: CGFloat = 24
    var arrowH: CGFloat = 12
    /// Mitte des Pfeils vom linken Rand; nil = kein Pfeil
    var arrowX: CGFloat?

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + (arrowX == nil ? 0 : arrowH)
        let r = radius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        if let ax = arrowX {
            let cx = rect.minX + ax
            p.addLine(to: CGPoint(x: cx - arrowW / 2, y: top))
            p.addLine(to: CGPoint(x: cx - 2.5, y: rect.minY + 1.2))
            p.addQuadCurve(to: CGPoint(x: cx + 2.5, y: rect.minY + 1.2), control: CGPoint(x: cx, y: rect.minY - 0.8))
            p.addLine(to: CGPoint(x: cx + arrowW / 2, y: top))
        }
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: top + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}

private struct PopoverCard<V: View>: View {
    let content: V
    var arrowX: CGFloat?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = PopoverShape(arrowX: arrowX)
        content
            .padding(.top, arrowX == nil ? 0 : 12)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(shape.stroke(Color.primary.opacity(scheme == .dark ? 0.16 : 0.12), lineWidth: 0.75))
            .clipShape(shape)
            .background(
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 22, x: 0, y: 12)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 3, x: 0, y: 1))
            .fixedSize()
    }
}

private struct Hero: View {
    let scheme: ColorScheme
    let panel: NSBitmapImageRep
    let settings: NSBitmapImageRep

    private func image(_ rep: NSBitmapImageRep, scale: CGFloat = 1) -> some View {
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return Image(nsImage: img).resizable().interpolation(.high)
            .frame(width: rep.size.width * scale, height: rep.size.height * scale)
    }

    private var dark: Bool { scheme == .dark }
    private var iconX: CGFloat { ReadmeImages.iconX }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            // Einstellungen: links, kleiner, leicht nach hinten versetzt
            image(settings, scale: 0.76)
                .offset(x: 178 - ReadmeImages.margin * 0.76, y: 100 - ReadmeImages.margin * 0.76)
            // Panel: der Star, mit Pfeil unter dem Symbol
            image(panel)
                .offset(x: ReadmeImages.panelLeft - ReadmeImages.margin, y: 30 - ReadmeImages.margin)
            menuBar
        }
        .frame(width: ReadmeImages.heroW, height: ReadmeImages.heroH, alignment: .topLeading)
        .clipped()
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: dark
                ? [Color(red: 0.07, green: 0.09, blue: 0.14), Color(red: 0.11, green: 0.13, blue: 0.20), Color(red: 0.09, green: 0.10, blue: 0.15)]
                : [Color(red: 0.86, green: 0.88, blue: 0.92), Color(red: 0.93, green: 0.92, blue: 0.91), Color(red: 0.84, green: 0.87, blue: 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [dark ? Color(red: 0.25, green: 0.33, blue: 0.55).opacity(0.45) : Color.white.opacity(0.65), .clear],
                           center: UnitPoint(x: 0.82, y: 0.15), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [dark ? Color(red: 0.35, green: 0.25, blue: 0.50).opacity(0.25) : Color(red: 0.80, green: 0.85, blue: 0.95).opacity(0.7), .clear],
                           center: UnitPoint(x: 0.15, y: 0.95), startRadius: 0, endRadius: 560)
        }
    }

    private var menuBar: some View {
        HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 0) {
                Image(systemName: "battery.75").font(.system(size: 15)).frame(width: 40)
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium)).frame(width: 36)
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).frame(width: 36)
                Text("Mon 9:41").font(.system(size: 13)).frame(width: 64, alignment: .leading).padding(.leading, 6).padding(.trailing, 16)
            }
        }
        .foregroundStyle(Color.primary.opacity(0.88))
        .frame(width: ReadmeImages.heroW, height: 30)
        .overlay(alignment: .topLeading) {
            // Symbol exakt bei iconX zentriert; der Popover-Pfeil nutzt dieselbe Konstante
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 14, weight: .regular))
                .frame(width: 34, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(dark ? 0.22 : 0.16)))
                .foregroundStyle(Color.primary.opacity(0.88))
                .position(x: iconX, y: 15)
        }
        .background(
            Rectangle().fill(dark ? Color.black.opacity(0.34) : Color.white.opacity(0.50))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5) })
    }
}
