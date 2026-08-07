import Foundation

enum AsrBackend: Equatable {
    case parakeetJa(modelDir: String)
    case canary(modelDir: String)
    case paraformerZh(modelDir: String)
    case sensevoice(modelDir: String)
    case whisperLocal(cli: String, model: String)
    case fixedTranscript

    /// Debug-only label (not shown on the primary menu).
    var debugLabel: String {
        switch self {
        case .parakeetJa:
            return "Backend: Parakeet ja (ONNX)"
        case .canary:
            return "Backend: Canary-180M-Flash (ONNX)"
        case .paraformerZh:
            return "Backend: Paraformer-zh (ONNX)"
        case .sensevoice:
            return "Backend: SenseVoice-Small (ONNX)"
        case .whisperLocal:
            return "Backend: WhisperLocal (ggml-tiny)"
        case .fixedTranscript:
            return "Backend: FixedAsr (fallback)"
        }
    }
}

enum SessionFactory {
    /// Prefer euhadra L1 pack for the language, else FixedAsr.
    static func makeSession(language: AppLanguage = .current) -> (PttSession, AsrBackend) {
        switch language {
        case .japanese:
            if let s = tryParakeet(language: language) { return s }
        case .english, .spanish:
            if let s = tryCanary(language: language) { return s }
        case .chinese:
            if let s = tryParaformer(language: language) { return s }
        case .korean:
            if let s = trySensevoice(language: language) { return s }
        }
        NSLog("Typwrtr: no model for %@ — FixedAsr fallback", language.displayName)
        let session = try! PttSession.withFixedTranscript(
            language: language.ffi,
            fixedTranscript: language.fixedFallbackTranscript
        )
        return (session, .fixedTranscript)
    }

    private static func tryParakeet(language: AppLanguage) -> (PttSession, AsrBackend)? {
        guard let dir = ModelLocator.findParakeetJaDir() else {
            NSLog("Typwrtr: Parakeet-ja missing (tried %@)", ModelLocator.preferredParakeetJaDir())
            return nil
        }
        do {
            let session = try PttSession.withParakeet(language: language.ffi, modelDir: dir)
            NSLog("Typwrtr: using Parakeet-ja at %@", dir)
            return (session, .parakeetJa(modelDir: dir))
        } catch {
            NSLog("Typwrtr: Parakeet-ja failed (\(error))")
            return nil
        }
    }

    private static func tryCanary(language: AppLanguage) -> (PttSession, AsrBackend)? {
        guard let dir = ModelLocator.findCanaryDir() else {
            NSLog("Typwrtr: Canary missing (tried %@)", ModelLocator.preferredCanaryDir())
            return nil
        }
        do {
            let session = try PttSession.withCanary(language: language.ffi, modelDir: dir)
            NSLog("Typwrtr: using Canary at %@ for %@", dir, language.displayName)
            return (session, .canary(modelDir: dir))
        } catch {
            NSLog("Typwrtr: Canary failed (\(error))")
            return nil
        }
    }

    private static func tryParaformer(language: AppLanguage) -> (PttSession, AsrBackend)? {
        guard let dir = ModelLocator.findParaformerZhDir() else {
            NSLog("Typwrtr: Paraformer-zh missing")
            return nil
        }
        do {
            let session = try PttSession.withParaformerZh(language: language.ffi, modelDir: dir)
            NSLog("Typwrtr: using Paraformer-zh at %@", dir)
            return (session, .paraformerZh(modelDir: dir))
        } catch {
            NSLog("Typwrtr: Paraformer-zh failed (\(error))")
            return nil
        }
    }

    private static func trySensevoice(language: AppLanguage) -> (PttSession, AsrBackend)? {
        guard let dir = ModelLocator.findSensevoiceDir() else {
            NSLog("Typwrtr: SenseVoice missing")
            return nil
        }
        do {
            let session = try PttSession.withSensevoice(language: language.ffi, modelDir: dir)
            NSLog("Typwrtr: using SenseVoice at %@", dir)
            return (session, .sensevoice(modelDir: dir))
        } catch {
            NSLog("Typwrtr: SenseVoice failed (\(error))")
            return nil
        }
    }
}
