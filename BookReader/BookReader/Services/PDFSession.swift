import Foundation
import PDFKit

/// All PDFKit access runs on a dedicated serial queue.
/// Generation is updated under a lock from any thread — never via `queue.sync` from
/// the MainActor (that deadlocks/stalls when PDFKit work is in flight).
final class PDFSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mikehale.BookReader.pdf", qos: .userInitiated)
    private let lock = NSLock()
    private var document: PDFDocument?
    private var generation = 0

    struct OpenResult: Sendable {
        let book: LoadedBook
        let generation: Int
    }

    @discardableResult
    func beginOpen() -> Int {
        lock.lock()
        generation += 1
        let next = generation
        document = nil
        lock.unlock()
        return next
    }

    func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Load PDF + outline off the main thread. Always invokes `completion` on the main queue
    /// (including cancellation), so the UI never sticks on a spinner.
    func open(url: URL, generation: Int, completion: @escaping (Result<OpenResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(CancellationError()))
                }
                return
            }

            // Read bytes on the PDF queue first so PDFKit does not touch a security-scoped
            // file URL from a background thread (can stall). Then build PDFDocument from data.
            let result: Result<OpenResult, Error>
            do {
                guard self.isCurrent(generation) else {
                    throw CancellationError()
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard self.isCurrent(generation) else {
                    throw CancellationError()
                }
                guard let document = PDFDocument(data: data) else {
                    throw PDFBookLoaderError.unreadable
                }
                let pageCount = document.pageCount
                guard pageCount > 0 else {
                    throw PDFBookLoaderError.emptyDocument
                }

                let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
                let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines))
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? url.deletingPathExtension().lastPathComponent
                let chapters = ChapterDetector.chapters(from: document)
                let book = LoadedBook(
                    url: url,
                    title: displayTitle,
                    pageCount: pageCount,
                    chapters: chapters
                )

                guard self.isCurrent(generation) else {
                    throw CancellationError()
                }
                self.lock.lock()
                self.document = document
                self.lock.unlock()
                result = .success(OpenResult(book: book, generation: generation))
            } catch is CancellationError {
                result = .failure(CancellationError())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Extract + clean chapter text on the PDF queue. Completion on main.
    func chapterText(
        chapter: BookChapter,
        generation: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation) else { return }
            self.lock.lock()
            let document = self.document
            self.lock.unlock()
            guard let document else {
                DispatchQueue.main.async {
                    completion(.failure(PDFBookLoaderError.unreadable))
                }
                return
            }
            let text = PDFBookLoader.text(for: chapter, in: document)
            guard self.isCurrent(generation) else { return }
            DispatchQueue.main.async {
                completion(.success(text))
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }
}
