import Foundation

/// Downloads euhadra L1 packs into Application Support (same URLs as `scripts/fetch-models.sh`).
/// Uses `/usr/bin/curl` (same stack as the fetch script) because `URLSession` often
/// stalls on Hugging Face’s CDN redirects for large ONNX files.
enum PackDownloader {
    private static let lock = NSLock()
    private static var isDownloading = false

    enum DownloadError: LocalizedError {
        case unsupported(AppLanguage)
        case curlFailed(Int32, String)
        case incomplete(String)
        case cancelled
        case busy

        var errorDescription: String? {
            switch self {
            case .unsupported(let lang):
                return """
                \(lang.displayName) needs euhadra’s SenseVoice setup (Python).

                Run in the typwrtr repo:
                  \(lang.fetchCommand)

                Then reopen Setup (status updates automatically).
                """
            case .curlFailed(let code, let name):
                return "Download failed (curl \(code)) for \(name)."
            case .incomplete(let detail):
                return detail
            case .cancelled:
                return "Download cancelled."
            case .busy:
                return "A download is already in progress."
            }
        }
    }

    /// True while an in-app pack fetch is running (Setup skips UI rebuilds).
    static var isInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDownloading
    }

    private struct RemoteFile {
        let url: URL
        let localName: String
        /// Approximate size for weighted progress (0 = unknown / tiny).
        let expectedBytes: Int64
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

    /// Download missing files. `progress` is 0…1 (may be called off the main queue).
    static func download(
        language: AppLanguage,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard isInAppDownloadSupported(for: language) else {
            completion(.failure(DownloadError.unsupported(language)))
            return
        }

        lock.lock()
        if isDownloading {
            lock.unlock()
            completion(.failure(DownloadError.busy))
            return
        }
        isDownloading = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                lock.lock()
                isDownloading = false
                lock.unlock()
            }
            do {
                let dest = destinationDirectory(for: language)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let files = try remoteFiles(for: language)
                let totalWeight = Double(files.map(\.expectedBytes).reduce(0, +))
                var completedWeight: Int64 = 0

                for file in files {
                    let out = dest.appendingPathComponent(file.localName)
                    if fileByteSize(at: out) > 0 {
                        completedWeight += file.expectedBytes
                        progress(totalWeight > 0 ? Double(completedWeight) / totalWeight : 1)
                        continue
                    }

                    let base = Double(completedWeight)
                    try downloadFile(file.url, to: out, expectedBytes: file.expectedBytes) { fraction in
                        let weight = Double(file.expectedBytes)
                        let overall = totalWeight > 0
                            ? (base + weight * fraction) / totalWeight
                            : fraction
                        progress(min(1, max(0, overall)))
                    }
                    completedWeight += file.expectedBytes
                    progress(totalWeight > 0 ? Double(completedWeight) / totalWeight : 1)
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
            // Sizes are approximate; used only for progress weighting.
            return [
                RemoteFile(url: base.appendingPathComponent("vocab.txt"), localName: "vocab.txt", expectedBytes: 500_000),
                RemoteFile(url: base.appendingPathComponent("config.json"), localName: "config.json", expectedBytes: 5_000),
                RemoteFile(url: base.appendingPathComponent("encoder-model.onnx"), localName: "encoder-model.onnx", expectedBytes: 50_000_000),
                RemoteFile(url: base.appendingPathComponent("decoder_joint-model.onnx"), localName: "decoder_joint-model.onnx", expectedBytes: 50_000_000),
                RemoteFile(url: base.appendingPathComponent("encoder-model.onnx.data"), localName: "encoder-model.onnx.data", expectedBytes: 1_200_000_000),
                RemoteFile(url: base.appendingPathComponent("decoder_joint-model.onnx.data"), localName: "decoder_joint-model.onnx.data", expectedBytes: 1_000_000_000),
            ]

        case .english, .spanish:
            let base = URL(
                string: "https://huggingface.co/istupakov/canary-180m-flash-onnx/resolve/main"
            )!
            return [
                RemoteFile(url: base.appendingPathComponent("vocab.txt"), localName: "vocab.txt", expectedBytes: 60_000),
                RemoteFile(url: base.appendingPathComponent("config.json"), localName: "config.json", expectedBytes: 100),
                RemoteFile(url: base.appendingPathComponent("encoder-model.int8.onnx"), localName: "encoder-model.int8.onnx", expectedBytes: 133_710_896),
                RemoteFile(url: base.appendingPathComponent("decoder-model.int8.onnx"), localName: "decoder-model.int8.onnx", expectedBytes: 79_520_211),
            ]

        case .chinese:
            let base = URL(
                string: "https://huggingface.co/funasr/Paraformer-large/resolve/main"
            )!
            return [
                RemoteFile(url: base.appendingPathComponent("am.mvn"), localName: "am.mvn", expectedBytes: 50_000),
                RemoteFile(url: base.appendingPathComponent("config.yaml"), localName: "config.yaml", expectedBytes: 200_000),
                RemoteFile(url: base.appendingPathComponent("model_quant.onnx"), localName: "model.onnx", expectedBytes: 240_000_000),
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

    /// Fetch one file with curl; `fileProgress` is 0…1 for this file.
    private static func downloadFile(
        _ url: URL,
        to dest: URL,
        expectedBytes: Int64,
        fileProgress: @escaping (Double) -> Void
    ) throws {
        let fm = FileManager.default
        let partial = dest.appendingPathExtension("part")
        try? fm.removeItem(at: partial)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-fL",
            "--retry", "3",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--max-time", "3600",
            "-A", "Typwrtr/0.1",
            "--output", partial.path,
            url.absoluteString,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        fileProgress(0)
        try proc.run()

        // Poll with `attributesOfItem` — `URL.resourceValues(.fileSize)` can stay
        // cached at 0 while curl appends, which freezes UI progress (e.g. 62%).
        while proc.isRunning {
            let written = fileByteSize(at: partial)
            if expectedBytes > 0 {
                fileProgress(min(0.99, Double(written) / Double(expectedBytes)))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            try? fm.removeItem(at: partial)
            throw DownloadError.curlFailed(proc.terminationStatus, dest.lastPathComponent)
        }
        let size = fileByteSize(at: partial)
        guard size > 0 else {
            try? fm.removeItem(at: partial)
            throw DownloadError.incomplete("Empty download: \(dest.lastPathComponent)")
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: partial, to: dest)
        fileProgress(1)
    }

    private static func fileByteSize(at url: URL) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}
