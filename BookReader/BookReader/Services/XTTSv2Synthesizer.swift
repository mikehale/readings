import Foundation

enum XTTSv2Error: LocalizedError {
    case pythonNotFound
    case scriptNotFound
    case modelNotFound
    case speakerMissing(URL)
    case emptyText
    case processFailed(status: Int32, stderr: String)
    case outputMissing(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Could not find ebook2audiobook’s Python (expected …/ebook2audiobook/python_env/bin/python)."
        case .scriptNotFound:
            return "Missing run_xtts_guarded.py helper in the app bundle or BookReader/Scripts."
        case .modelNotFound:
            return "XTTS-v2 model not found. Install/sync ebook2audiobook models (models/tts/models--coqui--XTTS-v2)."
        case .speakerMissing(let url):
            return "Speaker wav missing: \(url.path)"
        case .emptyText:
            return "No text to synthesize."
        case .processFailed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty { return "XTTS failed with exit \(status)." }
            // Surface RSS-guard aborts clearly when the CLI is killed for memory.
            if detail.contains("GUARD ABORT") || detail.lowercased().contains("rss") {
                return "XTTS Curt was stopped after exceeding the ~9 GiB memory limit (typical peak ~4 GiB). Free some RAM and retry. \(detail.suffix(400))"
            }
            return "XTTS failed (\(status)): \(detail.suffix(800))"
        case .outputMissing(let url):
            return "XTTS finished but no MP3 at \(url.path)."
        case .cancelled:
            return "Synthesis stopped."
        }
    }
}

/// Short-lived Coqui XTTSv2 synth via ebook2audiobook env + RSS-kill helper.
///
/// Curt peaks ~4 GiB; macOS “immediate free” is a poor start gate (often &lt;1 GiB
/// even when the job will fit). Skip free-RAM preflight and rely on RSS kill (~9 GiB).
struct XTTSv2Synthesizer {
    var rssKillGiB: Double = 9
    var device: String = "cpu"

    func synthesize(
        text: String,
        speakerWav: URL,
        to outputURL: URL,
        broker: SynthesisProcessBroker
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw XTTSv2Error.emptyText }
        guard FileManager.default.fileExists(atPath: speakerWav.path) else {
            throw XTTSv2Error.speakerMissing(speakerWav)
        }
        try broker.throwIfCancelled()

        let python = try Self.resolvePython()
        let script = try Self.resolveScript()
        let modelDir = try Self.resolveModelDir()
        try broker.throwIfCancelled()

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookreader-xtts-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: textURL) }
        try trimmed.write(to: textURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.arguments = [
            script.path,
            "--text", textURL.path,
            "--speaker-wav", speakerWav.path,
            "--model-dir", modelDir.path,
            "--out", outputURL.path,
            "--device", device,
            "--rss-kill-gib", String(rssKillGiB),
            // No start-time free-RAM gate for Curt; RSS killer is the safety net.
            "--min-free-gib", "0",
            "--language", "en",
        ]
        process.environment = {
            var env = ProcessInfo.processInfo.environment
            env["COQUI_TOS_AGREED"] = "1"
            env["OMP_NUM_THREADS"] = "2"
            return env
        }()

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try broker.register(process)
                try process.run()
            } catch {
                broker.unregister(process)
                continuation.resume(throwing: error)
                return
            }
            process.terminationHandler = { finished in
                broker.unregister(finished)
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = (out + "\n" + err)
                if broker.wasCancelled || finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: XTTSv2Error.cancelled)
                } else if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: XTTSv2Error.processFailed(
                            status: finished.terminationStatus,
                            stderr: combined
                        )
                    )
                }
            }
        }

        try broker.throwIfCancelled()
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw XTTSv2Error.outputMissing(outputURL)
        }
    }

    // MARK: - Resolution

    static func resolvePython() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/projects/ebook2audiobook/python_env/bin/python",
            "/Users/mhale/projects/ebook2audiobook/python_env/bin/python",
            ProcessInfo.processInfo.environment["BOOKREADER_E2A_PYTHON"] ?? "",
        ].filter { !$0.isEmpty }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XTTSv2Error.pythonNotFound
    }

    static func resolveScript() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "run_xtts_guarded", withExtension: "py", subdirectory: "Scripts")
            ?? Bundle.main.url(forResource: "run_xtts_guarded", withExtension: "py") {
            return bundled
        }
        let repo = URL(fileURLWithPath: "/Users/mhale/projects/readings/BookReader/Scripts/run_xtts_guarded.py")
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        throw XTTSv2Error.scriptNotFound
    }

    static func resolveModelDir() throws -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BOOKREADER_XTTS_MODEL"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: url.appendingPathComponent("model.pth").path) {
                return url
            }
        }

        // Coqui rewrites model.pth on load — must be a writable copy, not the HF snapshot.
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cached = support
            .appendingPathComponent("BookReader", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("xtts-v2", isDirectory: true)
        let cachedModel = cached.appendingPathComponent("model.pth")
        if fm.fileExists(atPath: cachedModel.path) {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cachedModel.path)
            return cached
        }

        let sources: [URL] = {
            var list: [URL] = []
            let snapshotsRoot = URL(
                fileURLWithPath: "/Users/mhale/projects/ebook2audiobook/models/tts/models--coqui--XTTS-v2/snapshots"
            )
            if let snaps = try? fm.contentsOfDirectory(at: snapshotsRoot, includingPropertiesForKeys: nil) {
                list.append(contentsOf: snaps.filter {
                    fm.fileExists(atPath: $0.appendingPathComponent("model.pth").path)
                })
            }
            list.append(
                URL(fileURLWithPath: "/Users/mhale/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/bc-947aaf02-cd76-4149-a374-008f3282ccbb/files/media/local-tts-hillclimb/work/xtts-model")
            )
            return list
        }()

        for source in sources {
            guard fm.fileExists(atPath: source.appendingPathComponent("model.pth").path) else { continue }
            try fm.createDirectory(at: cached, withIntermediateDirectories: true)
            for name in ["config.json", "model.pth", "vocab.json", "speakers_xtts.pth"] {
                let src = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = cached.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
            }
            if fm.fileExists(atPath: cachedModel.path) {
                return cached
            }
        }
        throw XTTSv2Error.modelNotFound
    }
}
