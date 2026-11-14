// DeviceController+USB.swift – Produktiv-Init mit echtem Hotplug, Talkback-Bruecke
// (nur im App-Build, nicht in den Offline-Tests: USBTransport.watch braucht cusb, die Bruecke CoreAudio).
import Foundation

extension DeviceController {
    convenience init(transport: DeviceTransport = USBTransport(), store: StateStore = .default) {
        self.init(transport: transport, store: store, watch: USBTransport.watch,
                  talkbackBridge: MacTalkbackBridge())
    }
}
