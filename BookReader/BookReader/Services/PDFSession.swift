import Foundation
import PDFKit

/// All PDFKit access runs on a dedicated serial queue — never awaited from the MainActor.
/// Awaiting PDFKit from MainActor can freeze the UI (PDFKit often hops/syncs to the main run loop).
final class PDFSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mikehale.BookReader.pdf", qos: .userInitiated)
    private var document: PDFDocument?
    private var generation = 0

    struct OpenResult: Sendable {
        let book: LoadedBook
        let generation: Int
    }

    @discardableResult
    func beginOpen() -> Int {
        queue.sync {
            generation += 1
            document = nil
            return generation
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.generation += 1
            self?.document = nil
        }
    }

    /// Load PDF + outline off the main thread. Calls `completion` on the main queue.
    func open(url: URL, generation: Int, completion: @escaping (Result<OpenResult, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<OpenResult, Error>
            do {
                let loaded = try PDFBookLoader.load(url: url)
                guard generation == self.generation else { return }
                self.document = loaded.document
                result = .success(OpenResult(book: loaded.book, generation: generation))
            } catch {
                guard generation == self.generation else { return }
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
            // Superseded open/cancel — drop silently (caller already moved on).
            guard generation == self.generation else { return }
            guard let document = self.document else {
                DispatchQueue.main.async {
                    completion(.failure(PDFBookLoaderError.unreadable))
                }
                return
            }
            let text = PDFBookLoader.text(for: chapter, in: document)
            guard generation == self.generation else { return }
            DispatchQueue.main.async {
                completion(.success(text))
            }
        }
    }
}
