import Foundation

struct LoadedBook: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let pageCount: Int
    let chapters: [BookChapter]

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        pageCount: Int,
        chapters: [BookChapter]
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.pageCount = pageCount
        self.chapters = chapters
    }
}

struct ChapterTextPreview: Equatable {
    let fullText: String
    let previewText: String
    let wordCount: Int
    let characterCount: Int
    let isTruncated: Bool

    static let previewCharacterLimit = 2_500

    static func make(from fullText: String, limit: Int = previewCharacterLimit) -> ChapterTextPreview {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        let truncated = trimmed.count > limit
        let preview: String
        if truncated {
            let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
            preview = String(trimmed[..<end]) + "…"
        } else {
            preview = trimmed
        }
        return ChapterTextPreview(
            fullText: trimmed,
            previewText: preview.isEmpty ? "(No extractable text on these pages.)" : preview,
            wordCount: words,
            characterCount: trimmed.count,
            isTruncated: truncated
        )
    }
}
