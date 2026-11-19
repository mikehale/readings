import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BookReaderViewModel: ObservableObject {
    @Published var book: LoadedBook?
    @Published var selectedChapterID: BookChapter.ID?
    @Published var chapterPreview: ChapterTextPreview?
    @Published var isSynthesizing = false
    @Published var synthesisPhase: SynthesisPhase = .idle
    @Published var elapsedSeconds = 0
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var audioURLs: [BookChapter.ID: URL] = [:]
    @Published var voiceStore: VoiceReferenceStore

    let player = ChapterAudioPlayer()

    private var document: PDFDocument?
    private let synthesizer: SpeechSynthesizing
    private let processBroker = SynthesisProcessBroker()
    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?
    private var synthesisTask: Task<Void, Never>?

    init(
        voiceStore: VoiceReferenceStore,
        synthesizer: SpeechSynthesizing = SpeechSynthesisRouter()
    ) {
        self.voiceStore = voiceStore
        self.synthesizer = synthesizer

        player.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.voiceStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var selectedChapter: BookChapter? {
        guard let book, let selectedChapterID else { return nil }
        return book.chapters.first { $0.id == selectedChapterID }
    }

    var selectedAudioURL: URL? {
        guard let selectedChapterID else { return nil }
        return audioURLs[selectedChapterID]
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PDF book"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }

            let loaded = try PDFBookLoader.load(url: url)
            document = loaded.document
            book = loaded.book
            selectedChapterID = loaded.book.chapters.first?.id
            refreshPreview()
            player.stop()
            audioURLs = [:]
            statusMessage = "Loaded \(loaded.book.pageCount) pages · \(loaded.book.chapters.count) chapters"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectChapter(id: BookChapter.ID?) {
        selectedChapterID = id
        refreshPreview()
        if let id, let url = audioURLs[id] {
            try? player.load(url: url)
        } else {
            player.stop()
        }
    }

    func refreshPreview() {
        guard let document, let chapter = selectedChapter else {
            chapterPreview = nil
            return
        }
        let text = PDFBookLoader.text(for: chapter, in: document)
        chapterPreview = ChapterTextPreview.make(from: text)
    }

    func synthesizeSelectedChapter() {
        guard !isSynthesizing else { return }
        guard let book, let chapter = selectedChapter, let preview = chapterPreview else { return }
        guard !preview.fullText.isEmpty else {
            errorMessage = "This chapter has no extractable text."
            return
        }

        let profile = voiceStore.selectedProfile
        let chapterID = chapter.id
        processBroker.beginJob()
        isSynthesizing = true
        synthesisPhase = .preparing
        errorMessage = nil
        statusMessage = "Preparing \(profile.shortDisplayName)…"
        startElapsedTimer()

        synthesisTask = Task { @MainActor in
            do {
                let outputURL = try AudioOutputDirectory.outputURL(
                    bookTitle: book.title,
                    chapterTitle: chapter.title
                )
                synthesisPhase = .running
                statusMessage = "Synthesizing with \(profile.shortDisplayName)…"
                try await synthesizer.synthesize(
                    text: preview.fullText,
                    profile: profile,
                    to: outputURL,
                    broker: processBroker
                )
                audioURLs[chapterID] = outputURL
                try player.load(url: outputURL)
                synthesisPhase = .completed
                statusMessage = "Saved MP3 · \(profile.shortDisplayName)"
            } catch is SynthesisCancelError {
                synthesisPhase = .cancelled
                statusMessage = "Stopped"
                errorMessage = nil
            } catch let error as EdgeTTSError {
                if case .cancelled = error {
                    synthesisPhase = .cancelled
                    statusMessage = "Stopped"
                    errorMessage = nil
                } else {
                    synthesisPhase = .failed
                    errorMessage = error.localizedDescription
                    statusMessage = nil
                }
            } catch let error as XTTSv2Error {
                if case .cancelled = error {
                    synthesisPhase = .cancelled
                    statusMessage = "Stopped"
                    errorMessage = nil
                } else {
                    synthesisPhase = .failed
                    errorMessage = error.localizedDescription
                    statusMessage = nil
                }
            } catch {
                if processBroker.wasCancelled
                    || error.localizedDescription.lowercased().contains("stopped") {
                    synthesisPhase = .cancelled
                    statusMessage = "Stopped"
                    errorMessage = nil
                } else {
                    synthesisPhase = .failed
                    errorMessage = error.localizedDescription
                    statusMessage = nil
                }
            }
            stopElapsedTimer()
            isSynthesizing = false
            synthesisTask = nil
        }
    }

    func stopSynthesis() {
        guard isSynthesizing else { return }
        synthesisPhase = .stopping
        statusMessage = "Stopping…"
        synthesizer.cancel(broker: processBroker)
    }

    private func startElapsedTimer() {
        elapsedSeconds = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    func togglePlayback() {
        if player.currentURL == nil, let url = selectedAudioURL {
            do {
                try player.load(url: url)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        player.toggle()
    }
}

struct ContentView: View {
    @StateObject private var model: BookReaderViewModel
    @State private var isDropTargeted = false
    /// Keep chapters/voice sidebar visible on launch (not collapsed).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init() {
        let store = VoiceReferenceStore()
        _model = StateObject(wrappedValue: BookReaderViewModel(voiceStore: store))
    }

    var body: some View {
        Group {
            if let book = model.book {
                reader(book)
            } else {
                DropZoneView(
                    onOpen: { model.openPanel() },
                    onDropURLs: { urls in
                        if let url = urls.first {
                            model.open(url: url)
                        }
                    }
                )
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        // Window-wide PDF drop so Finder drags work even after a book is open.
        .pdfDrop(isTargeted: $isDropTargeted) { urls in
            if let url = urls.first {
                model.open(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookReaderOpenPDF)) { _ in
            model.openPanel()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func reader(_ book: LoadedBook) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(3)
                    Text("\(book.pageCount) pages · \(book.chapters.count) chapters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(book.url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding()

                Divider()

                ChapterListView(
                    chapters: book.chapters,
                    selection: Binding(
                        get: { model.selectedChapterID },
                        set: { model.selectChapter(id: $0) }
                    )
                )

                Divider()

                VoiceProfilePicker(
                    store: model.voiceStore,
                    isSynthesizing: model.isSynthesizing
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()

                HStack {
                    Button("Open PDF…") { model.openPanel() }
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            if let chapter = model.selectedChapter {
                ChapterDetailView(
                    chapter: chapter,
                    preview: model.chapterPreview,
                    isSynthesizing: model.isSynthesizing,
                    synthesisPhase: model.synthesisPhase,
                    elapsedSeconds: model.elapsedSeconds,
                    audioURL: model.selectedAudioURL,
                    isPlaying: model.player.isPlaying,
                    statusMessage: model.statusMessage,
                    voiceSummary: model.voiceStore.selectedProfile.shortDisplayName,
                    onSynthesize: { model.synthesizeSelectedChapter() },
                    onStopSynthesis: { model.stopSynthesis() },
                    onTogglePlayback: { model.togglePlayback() }
                )
            } else {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "book.pages",
                    description: Text("Choose a chapter from the sidebar.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open PDF…", action: model.openPanel)
            }
        }
    }
}

#Preview {
    ContentView()
}
