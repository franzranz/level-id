// StatusItemController.swift – Menueleisten-Symbol mit NSPopover (ersetzt MenuBarExtra(.window), das im
// Vollbildmodus beim Wegfahren der Menueleiste springt und flackert).
import AppKit
import Combine
import Dispatch
import SwiftUI

/// Uebergabe des Controllers vom App-Einstieg an den AppDelegate
@MainActor
enum AppContext {
    static var controller: DeviceController?
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let controller: DeviceController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    /// Einmaliger Timer nach dem Schliessen: baut den Panel-Inhalt nach 60 s ab (kein Dauer-Timer)
    private var teardownTimer: DispatchSourceTimer?
    private static let teardownDelay: TimeInterval = 60

    init(controller: DeviceController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        updateIcon(for: controller.connection)
        statusItem.isVisible = !(controller.connection == .disconnected && controller.state.ui.hideIconWhenDisconnected)

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Panel-Inhalt wird erst beim Oeffnen erzeugt (togglePopover) und nach dem Schliessen verzoegert abgebaut

        // Symbol: immer sichtbar, ausser die Einstellung blendet es bei getrenntem Geraet aus
        controller.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] connection in self?.connectionChanged(connection) }
            .store(in: &cancellables)
        // Einstellung wirkt sofort, ohne Neustart
        controller.$state
            .map(\.ui.hideIconWhenDisconnected)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.connectionChanged(self.controller.connection)
            }
            .store(in: &cancellables)
    }

    private func connectionChanged(_ connection: DeviceController.Connection) {
        updateIcon(for: connection)
        // .unresponsive bleibt immer sichtbar; getrennt nur ausgeblendet, wenn die Einstellung an ist
        let visible = !(connection == .disconnected && controller.state.ui.hideIconWhenDisconnected)
        if !visible, popover.isShown { popover.performClose(nil) }
        statusItem.isVisible = visible
    }

    private func updateIcon(for connection: DeviceController.Connection) {
        // Ohne Geraet: Umriss-Symbol, ausgegraut. Reagiert nicht: Warndreieck.
        let name: String
        switch connection {
        case .unresponsive: name = "exclamationmark.triangle.fill"
        case .disconnected: name = "hifispeaker"
        default: name = "hifispeaker.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Level iD")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = connection == .disconnected
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            let t0 = DispatchTime.now().uptimeNanoseconds
            cancelTeardownTimer()
            let rebuilt = popover.contentViewController == nil
            if rebuilt {
                let host = NSHostingController(rootView: PanelView(controller: controller))
                host.sizingOptions = .preferredContentSize     // Groesse folgt dem SwiftUI-Inhalt, auch beim Aufklappen
                popover.contentViewController = host
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()   // Tastatur/Scroll fuer die Regler
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            Diag.event("Panel geoeffnet in \(Int(ms.rounded())) ms (\(rebuilt ? "neu aufgebaut" : "wiederverwendet"))")
        }
    }

    // MARK: Verzoegerter Abbau des Panel-Inhalts

    private func startTeardownTimer() {
        cancelTeardownTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.teardownDelay)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.teardownTimerFired() }
        }
        teardownTimer = timer
        timer.resume()
    }

    private func cancelTeardownTimer() {
        teardownTimer?.cancel()
        teardownTimer = nil
    }

    private func teardownTimerFired() {
        teardownTimer = nil
        tearDownContentIfClosed()
        MemoryRelief.relieve()
    }

    /// Baut den Panel-Inhalt ab, falls das Popover zu ist. Gibt zurueck, ob abgebaut wurde.
    @discardableResult
    private func tearDownContentIfClosed() -> Bool {
        guard !popover.isShown, popover.contentViewController != nil else { return false }
        popover.contentViewController = nil
        Diag.event("Panel-Inhalt abgebaut")
        return true
    }

    // MARK: NSPopoverDelegate – Meter laufen nur, solange das Popover offen ist

    func popoverDidShow(_ notification: Notification) {
        controller.meteringEnabled = true
    }

    func popoverDidClose(_ notification: Notification) {
        controller.meteringEnabled = false
        startTeardownTimer()
    }
}
