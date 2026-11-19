import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct VoiceProfilePicker: View {
    @ObservedObject var store: VoiceReferenceStore
    var isSynthesizing: Bool

    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewingID: String?
    @State private var statusNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice")
                .font(.headline)

            Picker("Backend", selection: Binding(
                get: { store.selectedBackend },
                set: { store.selectBackend($0) }
            )) {
                ForEach(VoiceReferenceStore.BackendKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSynthesizing)
            .controlSize(.small)

            Text(store.selectedProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.selectedBackend == .xttsHQ {
                samplesSection
                librarySection
            } else if store.selectedBackend == .offlineKokoro {
                Text("Kokoro ONNX (`am_michael`) later. Use XTTS Curt for HQ or Andrew online.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusNote {
                Text(statusNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var samplesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Samples")
                .font(.subheadline.weight(.semibold))
            ForEach(BundledVoiceSample.catalog) { sample in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.name + (sample.isDefaultHQ ? " · HQ" : ""))
                            .font(.caption.weight(.medium))
                        Text(sample.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        togglePreview(sample)
                    } label: {
                        Image(systemName: previewingID == sample.id ? "stop.fill" : "play.fill")
                    }
                    .disabled(sample.resourceURL == nil || isSynthesizing)
                    .help("Preview sample")

                    Button("Use") {
                        copySample(sample)
                    }
                    .disabled(sample.resourceURL == nil || isSynthesizing)
                    .help("Copy into your voice library and select for XTTS")
                }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your library")
                .font(.subheadline.weight(.semibold))

            if store.references.isEmpty {
                Text("No saved refs yet — tap Use on a sample, or Import…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Reference", selection: Binding(
                    get: { store.selectedReferenceID },
                    set: { store.selectReference($0) }
                )) {
                    ForEach(store.references) { ref in
                        Text(ref.name).tag(Optional(ref.id))
                    }
                }
                .disabled(isSynthesizing)

                if let ref = store.selectedReference {
                    Text(store.fileURL(for: ref).path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                Button("Import…") { importReference() }
                    .disabled(isSynthesizing)
                if let id = store.selectedReferenceID {
                    Button("Remove", role: .destructive) {
                        store.deleteReference(id)
                    }
                    .disabled(isSynthesizing)
                }
            }

            Text("XTTS Curt peaks ~4 GiB; killed if RSS exceeds ~9 GiB. Prefer short speaker wavs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func copySample(_ sample: BundledVoiceSample) {
        do {
            let ref = try store.copySampleToLibrary(sample)
            statusNote = "Copied “\(ref.name)” into VoiceRefs and selected for XTTS."
            stopPreview()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func togglePreview(_ sample: BundledVoiceSample) {
        if previewingID == sample.id {
            stopPreview()
            return
        }
        guard let url = sample.resourceURL else { return }
        do {
            stopPreview()
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            previewPlayer = player
            previewingID = sample.id
            player.play()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewingID = nil
    }

    private func importReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a short speaker reference (WAV/MP3) for XTTS"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importReference(from: url, engine: "xtts")
            statusNote = "Imported \(url.lastPathComponent)."
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
