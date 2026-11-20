import Foundation

enum AudioOutputDirectory {
    /// Prefer ~/Movies/BookReader/; fall back to Application Support/BookReader/Audio.
    static func resolve() throws -> URL {
        let fileManager = FileManager.default

        if let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let preferred = movies.appendingPathComponent("BookReader", isDirectory: true)
            do {
                try fileManager.createDirectory(at: preferred, withIntermediateDirectories: true)
                return preferred
            } catch {
                // Fall through to Application Support.
            }
        }

        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fallback = support
            .appendingPathComponent("BookReader", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func outputURL(bookTitle: String, chapterTitle: String) throws -> URL {
        let root = try resolve()
        let bookFolder = root.appendingPathComponent(sanitize(bookTitle), isDirectory: true)
        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        let filename = sanitize(chapterTitle) + ".mp3"
        return bookFolder.appendingPathComponent(filename)
    }

    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "untitled" : String(collapsed.prefix(80))
    }
}
