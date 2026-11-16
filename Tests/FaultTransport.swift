// FaultTransport.swift – Skript-Transport fuer Robustheits-Tests (offline, nie ein Geraet).
import Foundation

/// Ersatz fuer die USB-Diagnose, die im Test-Build nicht enthalten ist (USBTransport.swift fehlt dort).
enum Diag {
    static func event(_ text: String) {}
}

final class FaultTransport: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var requests = 0
    private var setCount = 0
    private var mark = 0

    /// Ab diesem Request (1-basiert, GET+SET zusammen) liefern get nil und set false.
    var failAfterRequest: Int?
    /// get liefert immer nil (Geraet wird nie bereit)
    var getAlwaysNil = false
    /// get liefert zu kurze Daten (1 Byte)
    var shortGets = false
    /// open schlaegt fehl
    var openFails = false

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    var totalRequests: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var sets: Int { lock.lock(); defer { lock.unlock() }; return setCount }
    var requestsSinceMark: Int { lock.lock(); defer { lock.unlock() }; return requests - mark }
    func markNow() { lock.lock(); mark = requests; lock.unlock() }

    func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if openFails { return false }
        opened = true
        return true
    }

    func close() { lock.lock(); opened = false; lock.unlock() }

    private func failing() -> Bool {
        if let n = failAfterRequest, requests > n { return true }
        return false
    }

    func get(_ request: ID14.Request, unit: UInt8, wValue: UInt16, length: Int) -> [UInt8]? {
        guard request != .cur || ID14.isSafeToRead(unit: unit, wValue: wValue) else { return nil }
        lock.lock(); defer { lock.unlock() }
        requests += 1
        if !opened || getAlwaysNil || failing() { return nil }
        if shortGets { return [0] }
        if unit == ID14.Unit.notify.rawValue { return [0xFF, 0, 0, 0xFF] }   // nichts geaendert
        if unit == ID14.Unit.monitor.rawValue, wValue == ID14.Monitor.volume.wValue { return [0x00, 0x80] }  // -128 dB
        return [UInt8](repeating: 0, count: length)
    }

    func set(_ command: SetCommand) -> Bool {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        guard ID14.isWritable(command.control), command.data.count == command.control.length else { return false }
        if !opened || failing() { return false }
        setCount += 1
        return true
    }
}
