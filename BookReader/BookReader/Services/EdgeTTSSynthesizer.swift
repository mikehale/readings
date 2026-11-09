import Foundation

enum EdgeTTSError: LocalizedError {
    case binaryNotFound
    case emptyText
    case processFailed(status: Int32, stderr: String)
    case outputMissing(URL)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "edge-tts was not found. Install with: pip install edge-tts  (or pipx/uv), and ensure `edge-tts` is on PATH."
        case .emptyText:
            return "This chapter has no extractable text to synthesize."
        case .processFailed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "edge-tts failed with exit status \(status)."
            }
            return "edge-tts failed (\(status)): \(detail)"
        case .outputMissing(let url):
            return "edge-tts finished but no MP3 was written at \(url.path)."
        }
    }
}

/// Synthesizes chapter narration via the `edge-tts` CLI (Microsoft Neural voices).
struct EdgeTTSSynthesizer {
    static let voice = "en-US-AndrewNeural"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func synthesize(text: String, to outputURL: URL) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EdgeTTSError.emptyText }

        let binary = try Self.resolveEdgeTTSBinary()
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        // Write text to a temp file so we avoid shell-escaping huge chapter bodies.
        let textURL = fileManager.temporaryDirectory
            .appendingPathComponent("bookreader-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: textURL) }
        try trimmed.write(to: textURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--voice", Self.voice,
            "--file", textURL.path,
            "--write-media", outputURL.path,
        ]

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.terminationHandler = { finished in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: EdgeTTSError.processFailed(
                            status: finished.terminationStatus,
                            stderr: stderr
                        )
                    )
                }
            }
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw EdgeTTSError.outputMissing(outputURL)
        }
    }

    static func resolveEdgeTTSBinary() throws -> URL {
        let candidates: [String] = {
            var paths: [String] = []
            if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
                paths.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            paths.append(contentsOf: [
                "\(home)/.local/bin",
                "\(home)/.local/share/mise/shims",
                "\(home)/Library/Python/3.12/bin",
                "\(home)/Library/Python/3.11/bin",
                "\(home)/.pyenv/shims",
                "/opt/homebrew/bin",
                "/usr/local/bin",
            ])
            return paths
        }()

        for dir in candidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("edge-tts")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        // `which` fallback when launched from a GUI app with a sparse PATH.
        if let which = try? runWhich("edge-tts") {
            return which
        }

        throw EdgeTTSError.binaryNotFound
    }

    private static func runWhich(_ name: String) throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
