// StatusItemController.swift – Menueleisten-Symbol mit NSPopover (ersetzt MenuBarExtra(.window), das im
// Vollbildmodus beim Wegfahren der Menueleiste springt und flackert).
import AppKit
import Combine
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
        let host = NSHostingController(rootView: PanelView(controller: controller))
        host.sizingOptions = .preferredContentSize     // Groesse folgt dem SwiftUI-Inhalt, auch beim Aufklappen
        popover.contentViewController = host

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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()   // Tastatur/Scroll fuer die Regler
        }
    }

    // MARK: NSPopoverDelegate – Meter laufen nur, solange das Popover offen ist

    func popoverDidShow(_ notification: Notification) {
        controller.meteringEnabled = true
    }

    func popoverDidClose(_ notification: Notification) {
        controller.meteringEnabled = false
    }
}
