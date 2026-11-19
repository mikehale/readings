import SwiftUI

struct ChapterDetailView: View {
    let chapter: BookChapter
    let preview: ChapterTextPreview?
    let isSynthesizing: Bool
    let synthesisPhase: SynthesisPhase
    let elapsedSeconds: Int
    let audioURL: URL?
    let isPlaying: Bool
    let statusMessage: String?
    let voiceSummary: String
    let onSynthesize: () -> Void
    let onStopSynthesis: () -> Void
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
                Text(voiceSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow

            HStack(spacing: 12) {
                Button {
                    onSynthesize()
                } label: {
                    Label("Synthesize MP3", systemImage: "waveform")
                }
                .disabled(isSynthesizing || (preview?.fullText.isEmpty ?? true))
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    onStopSynthesis()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isSynthesizing)
                .buttonStyle(.bordered)

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

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            if synthesisPhase.isActive {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(statusTitle)
                .font(.caption.weight(.semibold))
            if synthesisPhase.isActive {
                Text(elapsedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Synthesis status \(statusTitle)")
    }

    private var statusTitle: String {
        switch synthesisPhase {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing…"
        case .running:
            return "Synthesizing…"
        case .stopping:
            return "Stopping…"
        case .cancelled:
            return "Stopped"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch synthesisPhase {
        case .idle: return .secondary
        case .preparing, .running: return .orange
        case .stopping: return .yellow
        case .cancelled: return .gray
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var elapsedLabel: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
