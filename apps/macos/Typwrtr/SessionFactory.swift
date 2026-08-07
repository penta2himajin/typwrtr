import Foundation

enum AsrBackend: Equatable {
    case whisperLocal(cli: String, model: String)
    case fixedTranscript

    var menuLabel: String {
        switch self {
        case .whisperLocal:
            return "ASR: WhisperLocal ja (ggml-tiny)"
        case .fixedTranscript:
            return "ASR: FixedAsr ja (fallback)"
        }
    }
}

enum SessionFactory {
    /// Dogfood default: Japanese (multilingual whisper tiny).
    static let language: FfiLanguage = .japanese

    /// Prefer Whisper when CLI + model exist; otherwise FixedAsr.
    static func makeSession() -> (PttSession, AsrBackend) {
        let env = ProcessInfo.processInfo.environment
        let cli = env["TYPWRTR_WHISPER_CLI"] ?? env["WHISPER_CLI"] ?? defaultCliPath()
        let modelDir = env["TYPWRTR_WHISPER_MODEL_DIR"]
            ?? env["TYPWRTR_MODELS_DIR"].map { "\($0)/whisper" }
            ?? defaultModelDir()

        // Multilingual tiny covers Japanese (`-l ja` set in core).
        let modelName = "ggml-tiny.bin"
        let modelPath = (modelDir as NSString).appendingPathComponent(modelName)

        if FileManager.default.isExecutableFile(atPath: cli),
           FileManager.default.fileExists(atPath: modelPath)
        {
            do {
                let session = try PttSession.withWhisperLocal(
                    language: language,
                    cliPath: cli,
                    modelPath: modelPath
                )
                return (session, .whisperLocal(cli: cli, model: modelPath))
            } catch {
                NSLog("Typwrtr: WhisperLocal failed (\(error)); falling back to FixedAsr")
            }
        } else {
            NSLog(
                "Typwrtr: Whisper paths missing (cli=%@ model=%@) — FixedAsr fallback",
                cli,
                modelPath
            )
        }

        let session = try! PttSession.withFixedTranscript(
            language: language,
            fixedTranscript: "えーと、こんにちは、タイプライター"
        )
        return (session, .fixedTranscript)
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
