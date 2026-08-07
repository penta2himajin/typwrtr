import Foundation

/// Downloads euhadra L1 packs into Application Support (same URLs as `scripts/fetch-models.sh`).
enum PackDownloader {
    enum DownloadError: LocalizedError {
        case unsupported(AppLanguage)
        case http(Int, String)
        case incomplete(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupported(let lang):
                return """
                \(lang.displayName) needs euhadra’s SenseVoice setup (Python).

                Run in the typwrtr repo:
                  \(lang.fetchCommand)

                Then Refresh.
                """
            case .http(let code, let name):
                return "Download failed (\(code)) for \(name)."
            case .incomplete(let detail):
                return detail
            case .cancelled:
                return "Download cancelled."
            }
        }
    }

    private struct RemoteFile {
        let url: URL
        let localName: String
    }

    /// Destination folder under Application Support for this language’s pack.
    static func destinationDirectory(for language: AppLanguage) -> URL {
        URL(fileURLWithPath: ModelLocator.applicationSupportModels, isDirectory: true)
            .appendingPathComponent(language.packFolderName, isDirectory: true)
    }

    /// Whether Download can fetch this pack in-app (Korean still needs the script).
    static func isInAppDownloadSupported(for language: AppLanguage) -> Bool {
        language != .korean
    }

    /// Download missing files. `progress` is 0…1 on the calling queue’s preference (we call it off main).
    static func download(
        language: AppLanguage,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard isInAppDownloadSupported(for: language) else {
            completion(.failure(DownloadError.unsupported(language)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = destinationDirectory(for: language)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let files = try remoteFiles(for: language)
                let total = Double(files.count)
                for (index, file) in files.enumerated() {
                    progress(Double(index) / total)
                    let out = dest.appendingPathComponent(file.localName)
                    if FileManager.default.fileExists(atPath: out.path),
                       (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0
                    {
                        continue
                    }
                    try downloadFile(file.url, to: out)
                }
                progress(1)
                try finalize(language: language, dest: dest)
                guard ModelLocator.isLanguagePackReady(language) else {
                    throw DownloadError.incomplete(
                        "Downloaded files look incomplete under \(dest.path)."
                    )
                }
                completion(.success(dest))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Manifest (mirrors fetch-models.sh)

    private static func remoteFiles(for language: AppLanguage) throws -> [RemoteFile] {
        switch language {
        case .japanese:
            let base = URL(
                string: "https://huggingface.co/sunilmahendrakar/parakeet-tdt-0.6b-ja-onnx/resolve/main"
            )!
            return [
                "vocab.txt",
                "config.json",
                "encoder-model.onnx",
                "decoder_joint-model.onnx",
                "encoder-model.onnx.data",
                "decoder_joint-model.onnx.data",
            ].map { RemoteFile(url: base.appendingPathComponent($0), localName: $0) }

        case .english, .spanish:
            let base = URL(
                string: "https://huggingface.co/istupakov/canary-180m-flash-onnx/resolve/main"
            )!
            return [
                "vocab.txt",
                "config.json",
                "encoder-model.int8.onnx",
                "decoder-model.int8.onnx",
            ].map { RemoteFile(url: base.appendingPathComponent($0), localName: $0) }

        case .chinese:
            let base = URL(
                string: "https://huggingface.co/funasr/Paraformer-large/resolve/main"
            )!
            return [
                RemoteFile(url: base.appendingPathComponent("am.mvn"), localName: "am.mvn"),
                RemoteFile(url: base.appendingPathComponent("config.yaml"), localName: "config.yaml"),
                // Quant weights saved as model.onnx (same as fetch-models.sh).
                RemoteFile(url: base.appendingPathComponent("model_quant.onnx"), localName: "model.onnx"),
            ]

        case .korean:
            throw DownloadError.unsupported(language)
        }
    }

    private static func finalize(language: AppLanguage, dest: URL) throws {
        switch language {
        case .english, .spanish:
            try ensureSymlink(
                at: dest.appendingPathComponent("encoder-model.onnx"),
                pointingTo: "encoder-model.int8.onnx"
            )
            try ensureSymlink(
                at: dest.appendingPathComponent("decoder-model.onnx"),
                pointingTo: "decoder-model.int8.onnx"
            )
        case .chinese:
            let tokens = dest.appendingPathComponent("tokens.json")
            if !FileManager.default.fileExists(atPath: tokens.path) {
                try writeParaformerTokens(
                    config: dest.appendingPathComponent("config.yaml"),
                    tokens: tokens
                )
            }
        case .japanese, .korean:
            break
        }
    }

    private static func ensureSymlink(at link: URL, pointingTo targetName: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: link.path) { return }
        let target = link.deletingLastPathComponent().appendingPathComponent(targetName)
        guard fm.fileExists(atPath: target.path) else { return }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: targetName)
    }

    /// Port of the Python snippet in `scripts/fetch-models.sh` paraformer-zh.
    private static func writeParaformerTokens(config: URL, tokens: URL) throws {
        let text = try String(contentsOf: config, encoding: .utf8)
        let pattern = #"^token_list:\s*\n((?:[ \t]*-[ \t].*\n)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let blockRange = Range(match.range(at: 1), in: text)
        else {
            throw DownloadError.incomplete("token_list not found in config.yaml")
        }
        var list: [String] = []
        for line in text[blockRange].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            var tok = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if (tok.hasPrefix("\"") && tok.hasSuffix("\""))
                || (tok.hasPrefix("'") && tok.hasSuffix("'"))
            {
                tok = String(tok.dropFirst().dropLast())
            }
            list.append(tok)
        }
        let data = try JSONSerialization.data(withJSONObject: list, options: [])
        try data.write(to: tokens, options: .atomic)
    }

    private static func downloadFile(_ url: URL, to dest: URL) throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>!
        let task = session.downloadTask(with: url) { temp, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let temp else {
                result = .failure(DownloadError.http(status, url.lastPathComponent))
                return
            }
            result = .success(temp)
        }
        task.resume()
        semaphore.wait()

        let temp = try result.get()
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: temp, to: dest)
    }
}
