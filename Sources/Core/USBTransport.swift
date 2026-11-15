// USBTransport.swift – echter Transport ueber CUSB (IOKit). Nur auf der USB-Queue des Controllers benutzen.
import Foundation

final class USBTransport: DeviceTransport {
    private var dev: OpaquePointer?
    private let timeoutMS: UInt32 = 500

    var isOpen: Bool { dev != nil }
    /// PID des geoeffneten Geraets (vor dem ersten erfolgreichen open: iD14-PID)
    private(set) var openedProductID: UInt16 = ID14.productID

    init() {}
    deinit { close() }

    func open() -> Bool {
        if dev != nil { return true }
        // Alle Profil-PIDs (iD14 zuerst); bei nur angestecktem iD14 identisch zum bisherigen Matching.
        let pids = DeviceProfile.all.map(\.productID)
        var pid: UInt16 = 0
        dev = pids.withUnsafeBufferPointer { cusb_open(ID14.vendorID, $0.baseAddress, Int32($0.count), &pid) }
        if dev != nil { openedProductID = pid }
        return dev != nil
    }

    func close() {
        guard let d = dev else { return }
        cusb_close(d)
        dev = nil
    }

    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]? {
        guard let d = dev, length > 0, length <= Int(UInt16.max) else { return nil }
        var buf = [UInt8](repeating: 0, count: length)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = buf.withUnsafeMutableBytes { p -> Int32 in
            cusb_control(d, 0xA1, request.rawValue, wValue, UInt16(unit) << 8,
                         p.baseAddress, UInt16(length), timeoutMS)
        }
        Diag.record(Diag.Entry(t: t0, dur: DispatchTime.now().uptimeNanoseconds &- t0, isSet: false,
                               req: request.rawValue, unit: unit, wValue: wValue, len: UInt16(length),
                               result: n, d0: 0, d1: 0))
        guard n >= 0 else { return nil }
        return Array(buf.prefix(Int(n)))
    }

    func set(_ command: SetCommand) -> Bool {
        // Sicherheitsprüfung: nur Whitelist und exakte Länge, sonst wird nichts gesendet.
        guard ID14.isWritable(command.control), command.data.count == command.control.length else { return false }
        guard let d = dev else { return false }
        var buf = command.data
        let len = UInt16(buf.count)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = buf.withUnsafeMutableBytes { p -> Int32 in
            cusb_control(d, 0x21, ID14.Request.cur.rawValue, command.control.wValue, command.control.wIndex,
                         p.baseAddress, len, timeoutMS)
        }
        Diag.record(Diag.Entry(t: t0, dur: DispatchTime.now().uptimeNanoseconds &- t0, isSet: true,
                               req: ID14.Request.cur.rawValue, unit: command.control.unit,
                               wValue: command.control.wValue, len: len, result: n,
                               d0: command.data.first ?? 0, d1: command.data.count > 1 ? command.data[1] : 0))
        return n >= 0
    }

    // MARK: Hotplug

    private final class WatchBox {
        let onChange: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onChange = f }
    }

    /// Meldet Anstecken (true) / Abziehen (false) auf dem Main-Run-Loop, auch sofort für ein bereits angestecktes Gerät.
    static func watch(onChange: @escaping (Bool) -> Void) {
        // Box bleibt absichtlich für die Prozesslaufzeit retained (C-Seite hält nur den rohen Zeiger).
        let ctx = Unmanaged.passRetained(WatchBox(onChange)).toOpaque()
        let pids = DeviceProfile.all.map(\.productID)
        let rc = pids.withUnsafeBufferPointer { p in
            cusb_watch(ID14.vendorID, p.baseAddress, Int32(p.count), { ctx, attached in
                guard let ctx = ctx else { return }
                Unmanaged<WatchBox>.fromOpaque(ctx).takeUnretainedValue().onChange(attached != 0)
            }, ctx)
        }
        if rc != 0 { Unmanaged<WatchBox>.fromOpaque(ctx).release() }
    }
}

/// Diagnose (Opus): Ringpuffer der letzten 60 Requests als ROHWERTE (kein Formatieren im Normalbetrieb).
/// Erst beim ersten Fehler einer Serie wird formatiert und nach ~/Library/Logs/ID14Control.log geschrieben.
/// Die Datei rotiert bei 512 KB nach ID14Control.log.1.
enum Diag {
    struct Entry {
        var t: UInt64; var dur: UInt64; var isSet: Bool
        var req: UInt8; var unit: UInt8; var wValue: UInt16; var len: UInt16
        var result: Int32; var d0: UInt8; var d1: UInt8
    }
    private static let capacity = 60
    nonisolated(unsafe) private static var ring = [Entry](repeating: Entry(t: 0, dur: 0, isSet: false, req: 0, unit: 0,
                                                                          wValue: 0, len: 0, result: 0, d0: 0, d1: 0),
                                                          count: capacity)
    nonisolated(unsafe) private static var head = 0
    nonisolated(unsafe) private static var filled = 0
    nonisolated(unsafe) private static var dumped = false
    private static let lock = NSLock()
    private static let maxBytes: UInt64 = 512 * 1024
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ID14Control.log")
    private static let linePrefix = ""

    /// Heisser Pfad: nur Struct kopieren, kein Allozieren, kein Formatieren.
    static func record(_ e: Entry) {
        lock.lock()
        ring[head] = e
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
        let failed = e.result < 0
        var snapshot: [Entry]? = nil
        if failed && !dumped {
            dumped = true
            snapshot = (0..<filled).map { ring[(head - filled + $0 + capacity) % capacity] }
        } else if !failed {
            dumped = false
        }
        lock.unlock()
        if let s = snapshot {
            append(["=== ERSTER FEHLER – letzte \(s.count) Requests ==="] + s.map(format))
        }
    }

    static func event(_ text: String) {
        append(["\(linePrefix)\(clock(DispatchTime.now().uptimeNanoseconds)) EVENT \(text)"])
    }

    // MARK: Formatieren (nur bei Fehler/Ereignis)

    private static let wallFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// Uptime-Nanosekunden -> Uhrzeit
    private static func clock(_ uptimeNS: UInt64) -> String {
        let ago = Double(DispatchTime.now().uptimeNanoseconds &- uptimeNS) / 1e9
        return wallFormatter.string(from: Date().addingTimeInterval(-ago))
    }

    private static func format(_ e: Entry) -> String {
        let what = e.isSet
            ? String(format: "SET unit=%02x wValue=%04x len=%d data=[%02x %02x]", e.unit, e.wValue, e.len, e.d0, e.d1)
            : String(format: "GET req=%02x unit=%02x wValue=%04x len=%d", e.req, e.unit, e.wValue, e.len)
        return "\(clock(e.t)) \(what) -> \(e.result) (\(String(format: "%.1f", Double(e.dur) / 1e6)) ms)"
    }

    private static let fileLock = NSLock()

    private static func append(_ lines: [String]) {
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        fileLock.lock(); defer { fileLock.unlock() }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
