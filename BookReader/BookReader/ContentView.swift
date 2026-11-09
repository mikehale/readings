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
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var audioURLs: [BookChapter.ID: URL] = [:]

    let player = ChapterAudioPlayer()

    private var document: PDFDocument?
    private let synthesizer = EdgeTTSSynthesizer()
    private var cancellables = Set<AnyCancellable>()

    init() {
        player.objectWillChange
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
        guard let book, let chapter = selectedChapter, let preview = chapterPreview else { return }
        guard !preview.fullText.isEmpty else {
            errorMessage = "This chapter has no extractable text."
            return
        }

        isSynthesizing = true
        errorMessage = nil
        statusMessage = "Synthesizing with \(EdgeTTSSynthesizer.voice)…"

        Task {
            do {
                let outputURL = try AudioOutputDirectory.outputURL(
                    bookTitle: book.title,
                    chapterTitle: chapter.title
                )
                try await synthesizer.synthesize(text: preview.fullText, to: outputURL)
                audioURLs[chapter.id] = outputURL
                try player.load(url: outputURL)
                statusMessage = "Saved MP3 · \(EdgeTTSSynthesizer.voice)"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
            isSynthesizing = false
        }
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
    @StateObject private var model = BookReaderViewModel()

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
        NavigationSplitView {
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

                HStack {
                    Button("Open PDF…") { model.openPanel() }
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if let chapter = model.selectedChapter {
                ChapterDetailView(
                    chapter: chapter,
                    preview: model.chapterPreview,
                    isSynthesizing: model.isSynthesizing,
                    audioURL: model.selectedAudioURL,
                    isPlaying: model.player.isPlaying,
                    statusMessage: model.statusMessage,
                    onSynthesize: { model.synthesizeSelectedChapter() },
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
