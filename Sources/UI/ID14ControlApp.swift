// ID14ControlApp.swift – Einstieg (P5). Menueleiste: StatusItemController (NSStatusItem + NSPopover).
import SwiftUI

@MainActor
@main
struct ID14ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Hover-Tipps erst nach 2 s (Systemstandard ca. 0,5 s); gilt nur fuer diese App
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 2000])
        // Vorschau-Modus (rendert PNGs und beendet sich) greift vor allem anderen
        MeterPreview.renderIfRequested()
        // Zuerst Einzelinstanz pruefen (kann exit(0) ausloesen), erst danach Controller/USB.
        SingleInstance.guardStart()
        let c = DeviceController(transport: USBTransport())
        c.start()
        SingleInstance.installTermHandler(controller: c)
        AppContext.controller = c
        // Beim Beenden Geraet sauber abschliessen
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { c.prepareForTermination() }
        }
    }

    var body: some Scene {
        // Die Menueleiste uebernimmt StatusItemController (NSStatusItem + NSPopover), siehe AppDelegate.
        Settings { EmptyView() }
    }
}

/// Legt nach dem Start das Menueleisten-Symbol an (der Controller entsteht schon im App-Einstieg).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var mediaKeyTap: MediaKeyTap?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let c = AppContext.controller {
            statusController = StatusItemController(controller: c)
            // Standardmaessig aus: der Tap entsteht erst, wenn "Use Mac volume keys" an ist
            // Dev-Build: kein Medientasten-Tap (koennte die installierte App stoeren)
            mediaKeyTap = MediaKeyTap(controller: c, hud: VolumeHUD())
        }
    }
}
