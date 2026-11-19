import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceProfilePicker: View {
    @ObservedObject var store: VoiceReferenceStore
    var isSynthesizing: Bool

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

            Text(store.selectedProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.selectedBackend == .narratorClone {
                cloneSection
            } else if store.selectedBackend == .offlineKokoro {
                Text("Kokoro ONNX (`am_michael`) will spawn as a short-lived CLI later. Andrew remains the working path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cloneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.references.isEmpty {
                Text("Import a short denoised reference clip (≤ ~10–15s) for Chatterbox clone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Reference", selection: Binding(
                    get: { store.selectedReferenceID },
                    set: { store.selectReference($0) }
                )) {
                    ForEach(store.references) { ref in
                        Text(refLabel(ref)).tag(Optional(ref.id))
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
                Button("Import reference…") { importReference() }
                    .disabled(isSynthesizing)
                if let id = store.selectedReferenceID {
                    Button("Remove", role: .destructive) {
                        store.deleteReference(id)
                    }
                    .disabled(isSynthesizing)
                }
            }

            Text("Prefer Demucs-denoised refs. Clone synth is memory-gated and not wired in this build — selecting it keeps the ref ready.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refLabel(_ ref: SavedVoiceReference) -> String {
        ref.isDenoised ? "\(ref.name) · denoised" : ref.name
    }

    private func importReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a short denoised voice reference (MP3/WAV)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.importReference(from: url, isDenoised: true)
        } catch {
            // Surface via store consumers — ContentView watches errors separately if needed.
            NSAlert(error: error).runModal()
        }
    }
}
