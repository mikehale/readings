import Foundation

/// Persists speaker refs under Application Support/BookReader/VoiceRefs/.
@MainActor
final class VoiceReferenceStore: ObservableObject {
    @Published private(set) var references: [SavedVoiceReference] = []
    @Published var selectedReferenceID: UUID?
    @Published var selectedBackend: BackendKind = .xttsHQ

    enum BackendKind: String, CaseIterable, Identifiable {
        case xttsHQ
        case onlineAndrew
        case offlineKokoro

        var id: String { rawValue }

        var label: String {
            switch self {
            case .xttsHQ: return "XTTS Curt"
            case .onlineAndrew: return "Andrew"
            case .offlineKokoro: return "Kokoro"
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
        seedBundledCurtIfNeeded()
        load()
    }

    var selectedReference: SavedVoiceReference? {
        guard let selectedReferenceID else { return references.first }
        return references.first { $0.id == selectedReferenceID } ?? references.first
    }

    var selectedProfile: VoiceProfile {
        switch selectedBackend {
        case .xttsHQ:
            if let ref = selectedReference {
                return .xtts(speakerWav: fileURL(for: ref))
            }
            if let curt = BundledVoiceSample.catalog.first(where: \.isDefaultHQ)?.resourceURL {
                return .xtts(speakerWav: curt)
            }
            return .onlineAndrew
        case .onlineAndrew:
            return .onlineAndrew
        case .offlineKokoro:
            return .offlineKokoro(voice: VoiceProfile.defaultKokoroVoice)
        }
    }

    func fileURL(for reference: SavedVoiceReference) -> URL {
        rootURL.appendingPathComponent(reference.fileName)
    }

    @discardableResult
    func importReference(
        from sourceURL: URL,
        name: String? = nil,
        isDenoised: Bool = false,
        engine: String = "xtts"
    ) throws -> SavedVoiceReference {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        let safeExt = ["mp3", "wav", "m4a", "aiff", "caf"].contains(ext) ? ext : "wav"
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
            isDenoised: isDenoised,
            engine: engine
        )
        references.append(ref)
        selectedReferenceID = ref.id
        if engine == "xtts" {
            selectedBackend = .xttsHQ
        }
        try persist()
        return ref
    }

    /// Copy a bundled sample into the user library and select it for XTTS.
    @discardableResult
    func copySampleToLibrary(_ sample: BundledVoiceSample) throws -> SavedVoiceReference {
        guard let url = sample.resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Avoid duplicate Curt/etc. names: reuse existing if same name already present.
        if let existing = references.first(where: { $0.name == sample.name }) {
            selectedReferenceID = existing.id
            selectedBackend = .xttsHQ
            try persistSelection()
            return existing
        }
        return try importReference(from: url, name: sample.name, isDenoised: false, engine: "xtts")
    }

    func selectReference(_ id: UUID?) {
        selectedReferenceID = id
        if id != nil {
            selectedBackend = .xttsHQ
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
            // Migrate old narratorClone → xttsHQ
            let raw = selection.backend == "narratorClone" ? BackendKind.xttsHQ.rawValue : selection.backend
            selectedBackend = BackendKind(rawValue: raw) ?? .xttsHQ
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

    /// Ensure Curt (HQ default) is available; select XTTS on first empty library.
    private func seedBundledCurtIfNeeded() {
        let wasEmpty = references.isEmpty
        if let curt = BundledVoiceSample.catalog.first(where: \.isDefaultHQ),
           !references.contains(where: { $0.name == curt.name }) {
            _ = try? copySampleToLibrary(curt)
        } else if wasEmpty {
            let dune = URL(
                fileURLWithPath: "/Users/mhale/Library/Application Support/Cursor/AgentStores/cursor_agent_stores/bc-947aaf02-cd76-4149-a374-008f3282ccbb/files/media/local-tts-hillclimb/01b-reference-dune-narrator-10s-denoised.mp3"
            )
            if fileManager.fileExists(atPath: dune.path) {
                _ = try? importReference(
                    from: dune,
                    name: "Dune narrator (denoised 10s)",
                    isDenoised: true,
                    engine: "xtts"
                )
            }
        }
        if wasEmpty || selectedBackend == .xttsHQ {
            selectedBackend = .xttsHQ
            if let curt = references.first(where: { $0.name == "Curt" }) {
                selectedReferenceID = curt.id
            }
            try? persistSelection()
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
