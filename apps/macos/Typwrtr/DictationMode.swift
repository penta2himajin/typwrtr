import Foundation

/// How Typwrtr listens and when it inserts (Settings → Mode).
///
/// - ``pushToTalk``: hold PTT hotkey, release → one insert (classic).
/// - ``pushToTalkStreaming``: hold PTT; silence ends a segment and inserts
///   while the key stays down; release flushes the tail (key-gated Free).
/// - ``focusDictation``: armed + text-field focus; silence ends segments (F3).
enum DictationMode: String, CaseIterable {
    case pushToTalk
    case pushToTalkStreaming
    case focusDictation

    static let defaultsKey = "typwrtr.dictationMode"

    /// Settings / docs label.
    var settingsTitle: String {
        switch self {
        case .pushToTalk:
            return "Push to talk (batch)"
        case .pushToTalkStreaming:
            return "Push to talk (streaming)"
        case .focusDictation:
            return "Focus Dictation"
        }
    }

    /// Short hint under the Mode radios (uses current PTT preset).
    var settingsHint: String {
        let chord = PttHotkey.current.displaySymbol
        switch self {
        case .pushToTalk:
            return "Hold \(chord); release to insert the whole capture once."
        case .pushToTalkStreaming:
            return "Hold \(chord); pauses insert while held; release ends."
        case .focusDictation:
            return "While a text field is focused; silence ends each phrase."
        }
    }

    var isFocusDictation: Bool { self == .focusDictation }
    var isStreamingPtt: Bool { self == .pushToTalkStreaming }

    /// Stable tag for NSButton radios in Settings.
    var tag: Int {
        switch self {
        case .pushToTalk: return 0
        case .pushToTalkStreaming: return 1
        case .focusDictation: return 2
        }
    }

    static func from(tag: Int) -> DictationMode? {
        allCases.first { $0.tag == tag }
    }

    /// Persisted mode. Migrates the old `typwrtr.freeArmed` boolean once.
    static var current: DictationMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let mode = DictationMode(rawValue: raw)
            {
                return mode
            }
            // Pre-streaming dogfood: freeArmed true meant Focus Dictation.
            if UserDefaults.standard.bool(forKey: MenuBarModel.freeArmedKey) {
                return .focusDictation
            }
            return .pushToTalk
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            // Keep the old key in sync so anything still reading it stays coherent.
            UserDefaults.standard.set(newValue.isFocusDictation, forKey: MenuBarModel.freeArmedKey)
        }
    }
}
