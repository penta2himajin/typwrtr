import Foundation

enum AsrBackend: Equatable {
    case parakeetJa(modelDir: String)
    case whisperLocal(cli: String, model: String)
    case fixedTranscript

    var menuLabel: String {
        switch self {
        case .parakeetJa:
            return "ASR: Parakeet ja (ONNX)"
        case .whisperLocal:
            return "ASR: WhisperLocal ja (ggml-tiny)"
        case .fixedTranscript:
            return "ASR: FixedAsr ja (fallback)"
        }
    }
}

enum SessionFactory {
    /// Dogfood default: Japanese.
    static let language: FfiLanguage = .japanese

    /// Prefer Parakeet-ja, then Whisper, else FixedAsr.
    static func makeSession() -> (PttSession, AsrBackend) {
        if let parakeet = tryParakeet() {
            return parakeet
        }
        if let whisper = tryWhisper() {
            return whisper
        }
        NSLog("Typwrtr: no Parakeet/Whisper model — FixedAsr fallback")
        let session = try! PttSession.withFixedTranscript(
            language: language,
            fixedTranscript: "えーと、こんにちは、タイプライター"
        )
        return (session, .fixedTranscript)
    }

    private static func tryParakeet() -> (PttSession, AsrBackend)? {
        let env = ProcessInfo.processInfo.environment
        let dir = env["TYPWRTR_PARAKEET_JA_DIR"]
            ?? env["PARAKEET_JA_DIR"]
            ?? defaultParakeetDir()
        guard FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("encoder-model.onnx")),
              FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("encoder-model.onnx.data"))
        else {
            NSLog("Typwrtr: Parakeet-ja bundle missing at %@", dir)
            return nil
        }
        do {
            let session = try PttSession.withParakeet(language: language, modelDir: dir)
            NSLog("Typwrtr: using Parakeet-ja at %@", dir)
            return (session, .parakeetJa(modelDir: dir))
        } catch {
            NSLog("Typwrtr: Parakeet-ja failed (\(error)); trying Whisper")
            return nil
        }
    }

    private static func tryWhisper() -> (PttSession, AsrBackend)? {
        let env = ProcessInfo.processInfo.environment
        let cli = env["TYPWRTR_WHISPER_CLI"] ?? env["WHISPER_CLI"] ?? defaultCliPath()
        let modelDir = env["TYPWRTR_WHISPER_MODEL_DIR"]
            ?? env["TYPWRTR_MODELS_DIR"].map { "\($0)/whisper" }
            ?? defaultModelDir()
        let modelPath = (modelDir as NSString).appendingPathComponent("ggml-tiny.bin")

        guard FileManager.default.isExecutableFile(atPath: cli),
              FileManager.default.fileExists(atPath: modelPath)
        else {
            return nil
        }
        do {
            let session = try PttSession.withWhisperLocal(
                language: language,
                cliPath: cli,
                modelPath: modelPath
            )
            return (session, .whisperLocal(cli: cli, model: modelPath))
        } catch {
            NSLog("Typwrtr: WhisperLocal failed (\(error))")
            return nil
        }
    }

    private static func defaultParakeetDir() -> String {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["TYPWRTR_ROOT"] {
            candidates.append("\(root)/models/parakeet-tdt_ctc-0.6b-ja")
        }
        candidates.append(contentsOf: [
            NSString(string: "~/repos/typwrtr/models/parakeet-tdt_ctc-0.6b-ja")
                .expandingTildeInPath,
            "models/parakeet-tdt_ctc-0.6b-ja",
            NSString(string: "~/Library/Application Support/Typwrtr/models/parakeet-tdt_ctc-0.6b-ja")
                .expandingTildeInPath,
        ])
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    private static func defaultCliPath() -> String {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["TYPWRTR_ROOT"] {
            candidates.append("\(root)/vendor/whisper.cpp/build/bin/whisper-cli")
        }
        candidates.append(contentsOf: [
            NSString(string: "~/repos/typwrtr/vendor/whisper.cpp/build/bin/whisper-cli")
                .expandingTildeInPath,
            "vendor/whisper.cpp/build/bin/whisper-cli",
            NSString(string: "~/.local/bin/whisper-cli").expandingTildeInPath,
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? candidates[0]
    }

    private static func defaultModelDir() -> String {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["TYPWRTR_ROOT"] {
            candidates.append("\(root)/models/whisper")
        }
        candidates.append(contentsOf: [
            NSString(string: "~/repos/typwrtr/models/whisper").expandingTildeInPath,
            "models/whisper",
            NSString(string: "~/Library/Application Support/Typwrtr/models/whisper")
                .expandingTildeInPath,
        ])
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }
}
