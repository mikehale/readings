import SwiftUI

struct ChapterDetailView: View {
    let chapter: BookChapter
    let preview: ChapterTextPreview?
    let isSynthesizing: Bool
    let audioURL: URL?
    let isPlaying: Bool
    let statusMessage: String?
    let onSynthesize: () -> Void
    let onTogglePlayback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(preview?.previewText ?? "Select a chapter to preview text.")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            Divider()
            controls
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title)
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Text(chapter.pageLabel)
                if let preview {
                    Text("\(preview.wordCount) words")
                    Text("\(preview.characterCount) characters")
                    if preview.isTruncated {
                        Text("preview truncated")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    onSynthesize()
                } label: {
                    if isSynthesizing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Synthesizing…")
                    } else {
                        Label("Synthesize MP3", systemImage: "waveform")
                    }
                }
                .disabled(isSynthesizing || (preview?.fullText.isEmpty ?? true))
                .buttonStyle(.borderedProminent)

                Button {
                    onTogglePlayback()
                } label: {
                    Label(
                        isPlaying ? "Pause" : "Play",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .disabled(audioURL == nil || isSynthesizing)
                .buttonStyle(.bordered)

                Spacer()
            }

            if let audioURL {
                Text(audioURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
