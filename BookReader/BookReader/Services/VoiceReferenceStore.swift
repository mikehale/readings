import Foundation

/// Persists short clone reference clips under Application Support/BookReader/VoiceRefs/.
@MainActor
final class VoiceReferenceStore: ObservableObject {
    @Published private(set) var references: [SavedVoiceReference] = []
    @Published var selectedReferenceID: UUID?
    @Published var selectedBackend: BackendKind = .onlineAndrew

    enum BackendKind: String, CaseIterable, Identifiable {
        case onlineAndrew
        case offlineKokoro
        case narratorClone

        var id: String { rawValue }

        var label: String {
            switch self {
            case .onlineAndrew: return "Andrew (online)"
            case .offlineKokoro: return "Kokoro offline (soon)"
            case .narratorClone: return "Narrator clone"
            }
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let indexURL: URL
    private let selectionURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        rootURL = support
            .appendingPathComponent("BookReader", isDirectory: true)
            .appendingPathComponent("VoiceRefs", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        indexURL = rootURL.appendingPathComponent("index.json")
        selectionURL = rootURL.appendingPathComponent("selection.json")
        load()
        seedDuneDenoisedIfNeeded()
        load()
    }

    var selectedReference: SavedVoiceReference? {
        guard let selectedReferenceID else { return references.first }
        return references.first { $0.id == selectedReferenceID } ?? references.first
    }

    var selectedProfile: VoiceProfile {
        switch selectedBackend {
        case .onlineAndrew:
            return .onlineAndrew
        case .offlineKokoro:
            return .offlineKokoro(voice: VoiceProfile.defaultKokoroVoice)
        case .narratorClone:
            guard let ref = selectedReference else {
                return .onlineAndrew
            }
            return .clone(refAudioURL: fileURL(for: ref))
        }
    }

    func fileURL(for reference: SavedVoiceReference) -> URL {
        rootURL.appendingPathComponent(reference.fileName)
    }

    @discardableResult
    func importReference(from sourceURL: URL, name: String? = nil, isDenoised: Bool = true) throws -> SavedVoiceReference {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        let safeExt = ["mp3", "wav", "m4a", "aiff", "caf"].contains(ext) ? ext : "mp3"
        let display = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let fileName = sanitize(display) + "-\(UUID().uuidString.prefix(8)).\(safeExt)"
        let dest = rootURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)

        let ref = SavedVoiceReference(
            name: display,
            fileName: fileName,
            isDenoised: isDenoised
        )
        references.append(ref)
        selectedReferenceID = ref.id
        selectedBackend = .narratorClone
        try persist()
        return ref
    }

    func selectReference(_ id: UUID?) {
        selectedReferenceID = id
        if id != nil {
            selectedBackend = .narratorClone
        }
        try? persistSelection()
    }

    func selectBackend(_ backend: BackendKind) {
        selectedBackend = backend
        try? persistSelection()
    }

    func deleteReference(_ id: UUID) {
        guard let index = references.firstIndex(where: { $0.id == id }) else { return }
        let ref = references.remove(at: index)
        try? fileManager.removeItem(at: fileURL(for: ref))
        if selectedReferenceID == id {
            selectedReferenceID = references.first?.id
        }
        try? persist()
    }

    // MARK: - Persistence

    private struct SelectionState: Codable {
        var backend: String
        var referenceID: UUID?
    }

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([SavedVoiceReference].self, from: data) {
            references = decoded.sorted { $0.createdAt < $1.createdAt }
        } else {
            references = []
        }
        if let data = try? Data(contentsOf: selectionURL),
           let selection = try? JSONDecoder().decode(SelectionState.self, from: data) {
            selectedBackend = BackendKind(rawValue: selection.backend) ?? .onlineAndrew
            selectedReferenceID = selection.referenceID
        }
        if selectedReferenceID == nil {
            selectedReferenceID = references.first?.id
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(references)
        try data.write(to: indexURL, options: .atomic)
        try persistSelection()
    }

    private func persistSelection() throws {
        let state = SelectionState(
            backend: selectedBackend.rawValue,
            referenceID: selectedReferenceID
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: selectionURL, options: .atomic)
    }

    /// Optional first-run seed from the Project store hillclimb denoised Dune clip when present on this Mac.
    private func seedDuneDenoisedIfNeeded() {
        guard references.isEmpty else { return }
        let candidates = [
            "/Users/mhale/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/bc-947aaf02-cd76-4149-a374-008f3282ccbb/files/media/local-tts-hillclimb/01b-reference-dune-narrator-10s-denoised.mp3",
            "/cursor/stores/bc-947aaf02-cd76-4149-a374-008f3282ccbb/media/local-tts-hillclimb/01b-reference-dune-narrator-10s-denoised.mp3",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                _ = try importReference(
                    from: url,
                    name: "Dune narrator (denoised 10s)",
                    isDenoised: true
                )
                // Seed should not force clone backend as default synth — keep Andrew as ship path.
                selectedBackend = .onlineAndrew
                try? persistSelection()
            } catch {
                continue
            }
            break
        }
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "voice-ref" : String(collapsed.prefix(60))
    }
}
