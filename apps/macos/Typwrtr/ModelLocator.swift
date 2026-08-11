import AppKit
import Foundation

/// Shared disk locations for ASR models (SessionFactory + SetupChecker).
enum ModelLocator {
    static let parakeetJaDirKey = "typwrtr.parakeetJaDir"
    static let modelRootKey = "typwrtr.modelRoot"
    static let setupDismissedKey = "typwrtr.setupDismissed"

    static let parakeetFolderName = "parakeet-tdt_ctc-0.6b-ja"
    static let canaryFolderName = "canary-180m-flash-onnx"
    static let paraformerFolderName = "paraformer-zh"
    static let dolphinKoFolderName = "dolphin-ko"

    static var applicationSupportModels: String {
        NSString(string: "~/Library/Application Support/Typwrtr/models")
            .expandingTildeInPath
    }

    static var applicationSupportParakeet: String {
        (applicationSupportModels as NSString).appendingPathComponent(parakeetFolderName)
    }

    // MARK: - Persistence

    static func setParakeetJaDir(_ path: String) {
        UserDefaults.standard.set(path, forKey: parakeetJaDirKey)
    }

    static func setModelRoot(_ path: String) {
        UserDefaults.standard.set(path, forKey: modelRootKey)
    }

    static var setupDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: setupDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupDismissedKey) }
    }

    // MARK: - Pack presence

    static func isLanguagePackReady(_ language: AppLanguage) -> Bool {
        switch language {
        case .japanese: return findParakeetJaDir() != nil
        case .english, .spanish: return findCanaryDir() != nil
        case .chinese: return findParaformerZhDir() != nil
        case .korean: return findDolphinKoDir() != nil
        }
    }

    static func isParakeetBundlePresent(at dir: String) -> Bool {
        let base = dir as NSString
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("encoder-model.onnx"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("encoder-model.onnx.data"))
    }

    static func isCanaryBundlePresent(at dir: String) -> Bool {
        let base = dir as NSString
        let vocab = FileManager.default.fileExists(atPath: base.appendingPathComponent("vocab.txt"))
        let fp32 = FileManager.default.fileExists(atPath: base.appendingPathComponent("encoder-model.onnx"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("decoder-model.onnx"))
        let int8 = FileManager.default.fileExists(atPath: base.appendingPathComponent("encoder-model.int8.onnx"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("decoder-model.int8.onnx"))
        return vocab && (fp32 || int8)
    }

    static func isParaformerBundlePresent(at dir: String) -> Bool {
        let base = dir as NSString
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("model.onnx"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("am.mvn"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("tokens.json"))
    }

    static func isDolphinKoBundlePresent(at dir: String) -> Bool {
        let base = dir as NSString
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("model.int8.onnx"))
            && FileManager.default.fileExists(atPath: base.appendingPathComponent("tokens.txt"))
    }

    static func findParakeetJaDir() -> String? {
        packCandidates(
            folder: parakeetFolderName,
            envKeys: ["TYPWRTR_PARAKEET_JA_DIR", "PARAKEET_JA_DIR"],
            savedKey: parakeetJaDirKey
        ).first { isParakeetBundlePresent(at: $0) }
    }

    static func preferredParakeetJaDir() -> String {
        findParakeetJaDir()
            ?? packCandidates(
                folder: parakeetFolderName,
                envKeys: ["TYPWRTR_PARAKEET_JA_DIR", "PARAKEET_JA_DIR"],
                savedKey: parakeetJaDirKey
            ).first
            ?? applicationSupportParakeet
    }

    static func findCanaryDir() -> String? {
        packCandidates(
            folder: canaryFolderName,
            envKeys: ["TYPWRTR_CANARY_DIR", "CANARY_DIR", "CANARY_ES_DIR"],
            savedKey: nil
        ).first { isCanaryBundlePresent(at: $0) }
    }

    static func preferredCanaryDir() -> String {
        findCanaryDir()
            ?? packCandidates(
                folder: canaryFolderName,
                envKeys: ["TYPWRTR_CANARY_DIR", "CANARY_DIR", "CANARY_ES_DIR"],
                savedKey: nil
            ).first
            ?? (applicationSupportModels as NSString).appendingPathComponent(canaryFolderName)
    }

    static func findParaformerZhDir() -> String? {
        packCandidates(
            folder: paraformerFolderName,
            envKeys: ["TYPWRTR_PARAFORMER_ZH_DIR", "PARAFORMER_ZH_DIR"],
            savedKey: nil
        ).first { isParaformerBundlePresent(at: $0) }
    }

    static func findDolphinKoDir() -> String? {
        packCandidates(
            folder: dolphinKoFolderName,
            envKeys: ["TYPWRTR_DOLPHIN_KO_DIR", "DOLPHIN_KO_DIR"],
            savedKey: nil
        ).first { isDolphinKoBundlePresent(at: $0) }
    }

    // MARK: - Folder picker (Debug)

    @discardableResult
    static func pickParakeetFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a language-pack model folder"
        panel.directoryURL = URL(fileURLWithPath: applicationSupportModels, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let path = url.path
        if isParakeetBundlePresent(at: path) {
            setParakeetJaDir(path)
            return path
        }
        let nested = (path as NSString).appendingPathComponent(parakeetFolderName)
        if isParakeetBundlePresent(at: nested) {
            setParakeetJaDir(nested)
            return nested
        }
        setParakeetJaDir(path)
        return path
    }

    // MARK: - Helpers

    private static func packCandidates(
        folder: String,
        envKeys: [String],
        savedKey: String?
    ) -> [String] {
        var out: [String] = []
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment

        if let key = savedKey, let saved = defaults.string(forKey: key), !saved.isEmpty {
            out.append(saved)
        }
        if let root = defaults.string(forKey: modelRootKey), !root.isEmpty {
            out.append((root as NSString).appendingPathComponent(folder))
            out.append(
                ((root as NSString).appendingPathComponent("models") as NSString)
                    .appendingPathComponent(folder)
            )
        }
        for key in envKeys {
            if let dir = env[key], !dir.isEmpty {
                out.append(dir)
            }
        }
        if let root = env["TYPWRTR_ROOT"], !root.isEmpty {
            out.append("\(root)/models/\(folder)")
        }

        out.append((applicationSupportModels as NSString).appendingPathComponent(folder))
        out.append(
            NSString(string: "~/repos/typwrtr/models/\(folder)").expandingTildeInPath
        )
        out.append("models/\(folder)")

        return uniqued(out)
    }

    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in paths {
            if seen.insert(p).inserted {
                result.append(p)
            }
        }
        return result
    }
}
