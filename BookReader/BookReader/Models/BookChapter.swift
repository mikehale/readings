import Foundation

struct BookChapter: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// Zero-based PDFKit page index where this chapter starts.
    let startPageIndex: Int
    /// Zero-based inclusive end page index (last page of this chapter).
    let endPageIndex: Int

    init(
        id: UUID = UUID(),
        title: String,
        startPageIndex: Int,
        endPageIndex: Int
    ) {
        self.id = id
        self.title = title
        self.startPageIndex = startPageIndex
        self.endPageIndex = endPageIndex
    }

    var pageLabel: String {
        if startPageIndex == endPageIndex {
            return "Page \(startPageIndex + 1)"
        }
        return "Pages \(startPageIndex + 1)–\(endPageIndex + 1)"
    }
}
