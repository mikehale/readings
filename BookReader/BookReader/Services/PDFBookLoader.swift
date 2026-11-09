import Foundation
import PDFKit

enum PDFBookLoaderError: LocalizedError {
    case unreadable
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Could not open that PDF."
        case .emptyDocument:
            return "That PDF has no pages."
        }
    }
}

enum PDFBookLoader {
    static func load(url: URL) throws -> (document: PDFDocument, book: LoadedBook) {
        guard let document = PDFDocument(url: url) else {
            throw PDFBookLoaderError.unreadable
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PDFBookLoaderError.emptyDocument
        }

        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        let chapters = ChapterDetector.chapters(from: document)
        let book = LoadedBook(
            url: url,
            title: displayTitle,
            pageCount: pageCount,
            chapters: chapters
        )
        return (document, book)
    }

    static func text(for chapter: BookChapter, in document: PDFDocument) -> String {
        var parts: [String] = []
        for index in chapter.startPageIndex...chapter.endPageIndex {
            guard let page = document.page(at: index) else { continue }
            if let string = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                parts.append(string)
            }
        }
        // Clean before preview + TTS so ornamental spaced headings aren't spoken letter-by-letter.
        return ChapterTextCleaner.clean(parts.joined(separator: "\n\n"))
    }
}
