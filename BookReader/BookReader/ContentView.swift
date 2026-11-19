import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BookReaderViewModel: ObservableObject {
    @Published var book: LoadedBook?
    @Published var selectedChapterID: BookChapter.ID?
    @Published var chapterPreview: ChapterTextPreview?
    @Published var isOpeningBook = false
    @Published var isLoadingPreview = false
    @Published var openingProgress: String?
    @Published var isSynthesizing = false
    @Published var synthesisPhase: SynthesisPhase = .idle
    @Published var elapsedSeconds = 0
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var audioURLs: [BookChapter.ID: URL] = [:]
    @Published var voiceStore: VoiceReferenceStore

    let player = ChapterAudioPlayer()

    private let pdfSession = PDFSession()
    private let synthesizer: SpeechSynthesizing
    private let processBroker = SynthesisProcessBroker()
    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?
    private var synthesisTask: Task<Void, Never>?
    private var openGeneration = 0
    private var previewChapterID: BookChapter.ID?
    private var securityScopedURL: URL?
    private var securityScopedAccessActive = false

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

    /// Never awaits PDFKit from the MainActor. Fire-and-forget onto a serial PDF queue.
    func open(url: URL) {
        cancelOpenWork(keepSecurityScope: false)
        releaseSecurityScope()

        let access = url.startAccessingSecurityScopedResource()
        if access {
            securityScopedURL = url
            securityScopedAccessActive = true
        }

        book = nil
        selectedChapterID = nil
        chapterPreview = nil
        player.stop()
        audioURLs = [:]
        errorMessage = nil
        statusMessage = nil
        isLoadingPreview = false
        isOpeningBook = true
        openingProgress = "Opening PDF…"

        // Let SwiftUI paint the spinner before any PDFKit work starts.
        let generation = pdfSession.beginOpen()
        openGeneration = generation
        Task { @MainActor in
            await Task.yield()
            guard self.openGeneration == generation else { return }
            self.openingProgress = "Reading PDF & chapters…"
            self.pdfSession.open(url: url, generation: generation) { [weak self] result in
                Task { @MainActor in
                    self?.handleOpenResult(result, expectedGeneration: generation)
                }
            }
        }
    }

    func cancelOpen() {
        cancelOpenWork(keepSecurityScope: false)
        releaseSecurityScope()
        book = nil
        selectedChapterID = nil
        chapterPreview = nil
        isOpeningBook = false
        isLoadingPreview = false
        openingProgress = nil
        statusMessage = "Open cancelled"
    }

    func selectChapter(id: BookChapter.ID?) {
        selectedChapterID = id
        chapterPreview = nil

        if let id, let url = audioURLs[id] {
            try? player.load(url: url)
        } else {
            player.stop()
        }

        guard let id else {
            isLoadingPreview = false
            openingProgress = nil
            previewChapterID = nil
            return
        }
        // Text extract only after the user (or open) selects a chapter — never during open.
        loadPreview(for: id)
    }

    private func handleOpenResult(
        _ result: Result<PDFSession.OpenResult, Error>,
        expectedGeneration: Int
    ) {
        guard openGeneration == expectedGeneration else { return }

        switch result {
        case .success(let opened):
            guard opened.generation == openGeneration else { return }
            book = opened.book
            isOpeningBook = false
            openingProgress = nil
            statusMessage = "Loaded \(opened.book.pageCount) pages · \(opened.book.chapters.count) chapters"
            // Defer text extract: select first chapter only after open UI is up.
            // Selection triggers preview load separately (spinner in detail, not blocking open).
            if let first = opened.book.chapters.first?.id {
                selectChapter(id: first)
            } else {
                selectedChapterID = nil
                chapterPreview = nil
            }
        case .failure(let error):
            isOpeningBook = false
            openingProgress = nil
            book = nil
            selectedChapterID = nil
            chapterPreview = nil
            errorMessage = error.localizedDescription
            releaseSecurityScope()
        }
    }

    private func loadPreview(for chapterID: BookChapter.ID) {
        guard let chapter = book?.chapters.first(where: { $0.id == chapterID }) else {
            chapterPreview = nil
            isLoadingPreview = false
            return
        }

        let generation = openGeneration
        previewChapterID = chapterID
        isLoadingPreview = true
        openingProgress = "Extracting “\(chapter.title)”…"

        pdfSession.chapterText(chapter: chapter, generation: generation) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.openGeneration == generation else { return }
                guard self.selectedChapterID == chapterID, self.previewChapterID == chapterID else { return }

                switch result {
                case .success(let text):
                    self.chapterPreview = ChapterTextPreview.make(from: text)
                case .failure(let error):
                    self.chapterPreview = nil
                    self.errorMessage = error.localizedDescription
                }
                self.isLoadingPreview = false
                self.openingProgress = nil
            }
        }
    }

    private func cancelOpenWork(keepSecurityScope: Bool) {
        openGeneration = pdfSession.beginOpen()
        previewChapterID = nil
        if !keepSecurityScope {
            // beginOpen already invalidated in-flight PDF work via generation bump.
        }
    }

    private func releaseSecurityScope() {
        if securityScopedAccessActive, let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedAccessActive = false
        securityScopedURL = nil
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
            if model.isOpeningBook {
                openingPlaceholder
            } else if let book = model.book {
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
        .overlay {
            if model.isLoadingPreview && model.book != nil {
                loadingBanner
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
                    isLoadingPreview: model.isLoadingPreview,
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
                    .disabled(model.isOpeningBook)
            }
        }
    }

    private var openingPlaceholder: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text(model.openingProgress ?? "Opening PDF…")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) {
                model.cancelOpen()
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingBanner: some View {
        VStack {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(model.openingProgress ?? "Loading preview…")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
