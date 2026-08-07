import Foundation

/// User-facing language preference. Maps to euhadra L1 ASR packs.
enum AppLanguage: String, CaseIterable {
    case japanese
    case english
    case chinese
    case spanish
    case korean

    static let defaultsKey = "typwrtr.language"

    /// Persisted choice, else OS locale among en/ja/zh/es (else English).
    /// Korean locale falls back to English while Korean remains WIP.
    static var current: AppLanguage {
        get {
            let resolved: AppLanguage
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let value = AppLanguage(rawValue: raw)
            {
                resolved = value
            } else {
                let code = Locale.current.language.languageCode?.identifier ?? "en"
                switch code {
                case "ja": resolved = .japanese
                case "zh": resolved = .chinese
                case "es": resolved = .spanish
                default: resolved = .english
                }
            }
            return resolved.isSelectable ? resolved : .english
        }
        set {
            guard newValue.isSelectable else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// Recommended: ja / en. Experimental: zh / es (Q22). Korean is WIP (no in-app pack yet).
    var isExperimental: Bool {
        switch self {
        case .japanese, .english, .korean: return false
        case .chinese, .spanish: return true
        }
    }

    /// Selectable in Setup. Korean stays listed but disabled until SenseVoice is shippable in-app.
    var isSelectable: Bool {
        self != .korean
    }

    var displayName: String {
        let base: String
        switch self {
        case .japanese: base = "Japanese"
        case .english: base = "English"
        case .chinese: base = "Chinese"
        case .spanish: base = "Spanish"
        case .korean: base = "Korean"
        }
        if !isSelectable {
            return "\(base) (work in progress)"
        }
        return isExperimental ? "\(base) (experimental)" : base
    }

    var ffi: FfiLanguage {
        switch self {
        case .japanese: return .japanese
        case .english: return .english
        case .chinese: return .chinese
        case .spanish: return .spanish
        case .korean: return .korean
        }
    }

    /// Folder name under `models/` / Application Support.
    var packFolderName: String {
        switch self {
        case .japanese: return "parakeet-tdt_ctc-0.6b-ja"
        case .english, .spanish: return "canary-180m-flash-onnx"
        case .chinese: return "paraformer-zh"
        case .korean: return "sensevoice-small-onnx"
        }
    }

    /// CLI hint for installing the pack this language needs.
    var fetchCommand: String {
        switch self {
        case .japanese:
            return "./scripts/fetch-models.sh parakeet-ja"
        case .english, .spanish:
            return "./scripts/fetch-models.sh canary"
        case .chinese:
            return "./scripts/fetch-models.sh paraformer-zh"
        case .korean:
            return "./scripts/fetch-models.sh sensevoice-ko"
        }
    }

    var fixedFallbackTranscript: String {
        switch self {
        case .japanese:
            return "えーと、こんにちは、タイプライター"
        case .english:
            return "Hello, this is Typwrtr"
        case .chinese:
            return "你好，这是 Typwrtr"
        case .spanish:
            return "Hola, esto es Typwrtr"
        case .korean:
            return "안녕하세요, Typwrtr입니다"
        }
    }
}
