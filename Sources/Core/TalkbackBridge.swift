// TalkbackBridge.swift – Schnittstelle zur Audio-Bruecke fuer Talkback ueber das Mac-Mikrofon.
// Die echte Bruecke (Sources/UI/MacTalkbackBridge.swift) gibt es nur im App-Build; Tests nutzen den No-Op.
import Foundation

protocol TalkbackBridge: AnyObject {
    /// Audio starten (darf den Aufrufer nie blockieren)
    func start()
    /// Audio stoppen; danach laufen keine Audio-Threads mehr
    func stop()
}

/// Tut nichts (Standard in Tests und wenn keine Bruecke injiziert wird).
final class NoOpTalkbackBridge: TalkbackBridge {
    func start() {}
    func stop() {}
}
