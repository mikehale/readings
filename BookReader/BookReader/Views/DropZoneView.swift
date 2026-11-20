import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    var onOpen: () -> Void
    var onDropURLs: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a PDF to begin")
                .font(.title2)
            Text("Drag and drop a PDF here, or choose a file.")
                .foregroundStyle(.secondary)
            Button("Open PDF…", action: onOpen)
                .keyboardShortcut("o", modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 6])
                )
                .padding(24)
        )
        .pdfDrop(isTargeted: $isTargeted, onDropURLs: onDropURLs)
    }
}

extension View {
    /// Shared PDF file-drop handler (Finder drags often deliver `file://` URL data).
    func pdfDrop(isTargeted: Binding<Bool>? = nil, onDropURLs: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL, .pdf], isTargeted: isTargeted) { providers in
            Task { @MainActor in
                let urls = await PDFDropResolver.urls(from: providers)
                if !urls.isEmpty {
                    onDropURLs(urls)
                }
            }
            return true
        }
    }
}

enum PDFDropResolver {
    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            let loaded: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    continuation.resume(returning: object)
                }
            }
            if let loaded { return loaded }
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: decodeFileURL(item))
            }
        }
    }

    private static func decodeFileURL(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            if let string = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                if let url = URL(string: string), url.isFileURL {
                    return url
                }
                // Plain path without file:// scheme.
                if string.hasPrefix("/") {
                    return URL(fileURLWithPath: string)
                }
            }
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string)
            }
        }
        return nil
    }
}
