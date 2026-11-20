import Foundation
import PDFKit

enum ChapterDetector {
    /// Walks the PDF outline and returns top-level (or all leaf-ish) chapters with page ranges.
    /// Falls back to a single "Full book" chapter when no outline destinations exist.
    static func chapters(from document: PDFDocument) -> [BookChapter] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        guard let root = document.outlineRoot else {
            return [fullBookChapter(pageCount: pageCount)]
        }

        var starts: [(title: String, pageIndex: Int)] = []
        collectOutlineItems(root, into: &starts, document: document)

        // Deduplicate by page, keep first title for that page.
        var seenPages = Set<Int>()
        var unique: [(title: String, pageIndex: Int)] = []
        for item in starts.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            guard item.pageIndex >= 0, item.pageIndex < pageCount else { continue }
            if seenPages.insert(item.pageIndex).inserted {
                unique.append(item)
            }
        }

        guard !unique.isEmpty else {
            return [fullBookChapter(pageCount: pageCount)]
        }

        var result: [BookChapter] = []
        for (offset, item) in unique.enumerated() {
            let end: Int
            if offset + 1 < unique.count {
                end = max(item.pageIndex, unique[offset + 1].pageIndex - 1)
            } else {
                end = pageCount - 1
            }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                BookChapter(
                    title: title.isEmpty ? "Chapter \(offset + 1)" : title,
                    startPageIndex: item.pageIndex,
                    endPageIndex: end
                )
            )
        }
        return result
    }

    private static func fullBookChapter(pageCount: Int) -> BookChapter {
        BookChapter(title: "Full book", startPageIndex: 0, endPageIndex: pageCount - 1)
    }

    private static func collectOutlineItems(
        _ outline: PDFOutline,
        into result: inout [(title: String, pageIndex: Int)],
        document: PDFDocument
    ) {
        let childCount = outline.numberOfChildren
        if childCount == 0 {
            if let pageIndex = pageIndex(for: outline, document: document) {
                let title = outline.label ?? "Untitled"
                result.append((title, pageIndex))
            }
            return
        }

        // Prefer top-level destinations; also include children that have destinations
        // when the parent itself has none (common nested TOC pattern).
        for index in 0..<childCount {
            guard let child = outline.child(at: index) else { continue }
            if let pageIndex = pageIndex(for: child, document: document) {
                let title = child.label ?? "Untitled"
                result.append((title, pageIndex))
            } else if child.numberOfChildren > 0 {
                collectOutlineItems(child, into: &result, document: document)
            }
        }
    }

    private static func pageIndex(for outline: PDFOutline, document: PDFDocument) -> Int? {
        if let destination = outline.destination, let page = destination.page {
            let index = document.index(for: page)
            return index >= 0 ? index : nil
        }
        if let action = outline.action as? PDFActionGoTo, let page = action.destination.page {
            let index = document.index(for: page)
            return index >= 0 ? index : nil
        }
        return nil
    }
}
