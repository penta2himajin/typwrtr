import Carbon.HIToolbox
import Foundation
import SwiftUI

/// Push-to-talk chord presets (Settings → Mode → Hotkey). Undo stays ⌃⇧Z.
enum PttHotkey: String, CaseIterable {
    case controlShiftD
    case controlShiftSpace

    static let defaultsKey = "typwrtr.pttHotkey"

    /// Symbol used in tooltips / Mode hints / status (e.g. `⌃⇧D`).
    var displaySymbol: String {
        switch self {
        case .controlShiftD: return "⌃⇧D"
        case .controlShiftSpace: return "⌃⇧Space"
        }
    }

    /// Popup menu title.
    var settingsTitle: String {
        switch self {
        case .controlShiftD: return "⌃⇧D (default)"
        case .controlShiftSpace: return "⌃⇧Space"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlShiftD: return UInt32(kVK_ANSI_D)
        case .controlShiftSpace: return UInt32(kVK_Space)
        }
    }

    /// Carbon `RegisterEventHotKey` modifiers.
    var carbonModifiers: UInt32 {
        UInt32(controlKey | shiftKey)
    }

    /// Menu bar accelerator for the disabled “Push to talk” row.
    var menuKeyEquivalent: KeyEquivalent {
        switch self {
        case .controlShiftD: return "d"
        case .controlShiftSpace: return .space
        }
    }

    static var current: PttHotkey {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let hotkey = PttHotkey(rawValue: raw)
            {
                return hotkey
            }
            return .controlShiftD
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
