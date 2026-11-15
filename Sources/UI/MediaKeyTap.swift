// MediaKeyTap.swift – faengt die Mac-Lautstaerketasten ab und steuert stattdessen das ID14.
// Standardmaessig AUS: ohne "Use Mac volume keys" gibt es keinen Event-Tap und keine Berechtigungsabfrage.
// Abgefangen wird nur, wenn die Funktion an ist, das ID14 verbunden ist und der macOS-Standardausgang das ID14 ist.
import ApplicationServices
import AppKit
import Combine
import CoreAudio

/// Fuer die Settings: Funktion ist an, aber der Tap konnte (noch) nicht angelegt werden (Bedienungshilfen fehlen).
@MainActor
final class MediaKeyStatus: ObservableObject {
    static let shared = MediaKeyStatus()
    @Published fileprivate(set) var needsPermission = false
    /// Wird von MediaKeyTap gesetzt: neuer stiller Versuch, den Tap anzulegen (nur wirksam, wenn an und Tap fehlt)
    fileprivate(set) var retryHandler: (@MainActor () -> Void)?
    fileprivate func setRetryHandler(_ h: (@MainActor () -> Void)?) { retryHandler = h }
    func retry() { retryHandler?() }
}

@MainActor
final class MediaKeyTap {
    private let status = MediaKeyStatus.shared
    private var needsPermission: Bool {
        get { status.needsPermission }
        set { if status.needsPermission != newValue { status.needsPermission = newValue } }
    }

    private let controller: DeviceController
    private let hud: VolumeHUD
    private var cancellables = Set<AnyCancellable>()
    private var wanted = false
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    /// Ende des Nachlauf-Zeitfensters fuer erneute Versuche nach dem Einschalten (hoechstens 60 s)
    private var retryDeadline = Date.distantPast
    /// Abfangen-Entscheidung je keyCode, gemerkt von Key-Down bis Key-Up
    private var intercepting: [Int: Bool] = [:]
    /// Zwischengespeicherte ID des iD14-Ausgabegeraets (nil = unbekannt/ungueltig)
    private var cachedID14: AudioDeviceID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private static let listenerSelectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    init(controller: DeviceController, hud: VolumeHUD) {
        self.controller = controller
        self.hud = hud
        status.setRetryHandler { [weak self] in self?.settingsOpened() }
        // Erste Emission = App-Start (gespeicherter Wert): nur still versuchen, kein Dialog
        var isStart = true
        controller.$state
            .map(\.ui.volumeKeys)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                let initial = isStart
                isStart = false
                MainActor.assumeIsolated { self?.setWanted(on, userInitiated: !initial) }
            }
            .store(in: &cancellables)
    }

    /// Settings geoeffnet: ein stiller Versuch, falls an und der Tap fehlt
    private func settingsOpened() {
        guard wanted, port == nil else { return }
        attemptStart()
    }

    // MARK: Start / Stopp

    private func setWanted(_ on: Bool, userInitiated: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on {
            if userInitiated {
                // Systemdialog nur, wenn der Nutzer die Funktion im laufenden Betrieb einschaltet
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                retryDeadline = Date().addingTimeInterval(60)
            }
            attemptStart()
        } else {
            stop()
            needsPermission = false
        }
    }

    private func attemptStart() {
        guard wanted, port == nil else { return }
        if install() {
            retryTimer?.invalidate()
            retryTimer = nil
            needsPermission = false
        } else {
            needsPermission = true
            // Kein Dauer-Timer: nur kurz nach dem Einschalten, damit die frisch erteilte Berechtigung direkt greift
            if Date() >= retryDeadline {
                retryTimer?.invalidate()
                retryTimer = nil
            } else if retryTimer == nil {
                retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attemptStart() }
                }
            }
        }
    }

    private func install() -> Bool {
        let mask = CGEventMask(1) << CGEventType(rawValue: 14)!.rawValue    // NSSystemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: mediaKeyCallback, userInfo: refcon) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        port = p
        source = src
        addListeners()
        return true
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryDeadline = .distantPast
        removeListeners()
        intercepting.removeAll()
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let p = port { CGEvent.tapEnable(tap: p, enable: false); CFMachPortInvalidate(p) }
        source = nil
        port = nil
    }

    // MARK: CoreAudio-Cache

    private func addListeners() {
        guard listenerBlock == nil else { return }
        cachedID14 = nil
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.cachedID14 = nil }
        }
        listenerBlock = block
        for sel in Self.listenerSelectors {
            var a = HAL.address(sel)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        }
    }

    private func removeListeners() {
        guard let block = listenerBlock else { return }
        for sel in Self.listenerSelectors {
            var a = HAL.address(sel)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        }
        listenerBlock = nil
        cachedID14 = nil
    }

    private func defaultOutputIsID14() -> Bool {
        if cachedID14 == nil { cachedID14 = HAL.id14Output() }
        guard let id14 = cachedID14, let dev = HAL.defaultOutputDevice() else { return false }
        return dev == id14
    }

    fileprivate func reenable() {
        if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
    }

    // MARK: Ereignisse (Main-Thread, da der Tap auf dem Main-Run-Loop haengt)

    /// true = Ereignis verschlucken
    fileprivate func handle(data1: Int, shift: Bool) -> Bool {
        guard wanted else { return false }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let down = ((keyFlags & 0xFF00) >> 8) == 0xA
        let isRepeat = (keyFlags & 0x1) != 0
        guard keyCode == 0 || keyCode == 1 || keyCode == 7 else { return false }

        // Entscheidung nur beim Key-Down (ohne Repeat) treffen; Repeat und Key-Up uebernehmen sie
        let take: Bool
        if down && !isRepeat {
            take = controller.connection == .connected && !controller.readOnlyBeta && defaultOutputIsID14()
            intercepting[keyCode] = take
        } else {
            take = intercepting[keyCode] ?? false
            if !down { intercepting[keyCode] = nil }
        }
        guard take else { return false }

        if down {
            let fine = shift
            switch keyCode {
            case 0: controller.volumeKey(up: true, fine: fine)
            case 1: controller.volumeKey(up: false, fine: fine)
            default: if !isRepeat { controller.volumeKeyMute() }
            }
            showHUD(fine: fine)
        }
        return true
    }

    private func showHUD(fine: Bool) {
        let s = controller.state
        if s.ui.volumeKeysTarget == 1 {
            hud.show(dB: s.phonesVolumeDB, muted: s.monitor.phonesCut, headphones: true, fine: fine)
        } else {
            hud.show(dB: s.monitor.volumeDB, muted: s.monitor.cut, headphones: false, fine: fine)
        }
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Nur Werte (Sendable) in den MainActor-Block, nicht das CGEvent selbst
    guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
    let data1 = ns.data1
    let shift = event.flags.contains(.maskShift)
    let swallow = MainActor.assumeIsolated { tap.handle(data1: data1, shift: shift) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
