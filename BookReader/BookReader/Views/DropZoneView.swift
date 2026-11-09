import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    var onOpen: () -> Void
    var onDropURLs: ([URL]) -> Void

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
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(.quaternary)
                .padding(24)
        )
        .onDrop(of: [UTType.fileURL, UTType.pdf], isTargeted: nil) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    @MainActor
    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        if !pdfs.isEmpty {
            onDropURLs(pdfs)
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let path = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: URL(fileURLWithPath: path))
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
