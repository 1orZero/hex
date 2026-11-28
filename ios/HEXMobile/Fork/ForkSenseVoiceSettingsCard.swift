import FluidAudio
import SwiftUI

/// Labs › SenseVoice（中文） (fork), after the Dictation card: the switch, the model's download
/// with its progress, started by turning the switch on, and Remove model once it's on the iPhone.
struct ForkSenseVoiceSettingsCard: View {
    @State private var download = ForkSenseVoiceDownload.shared
    @State private var isEnabled = ForkSenseVoice.isEnabled
    @State private var isInstalled = ForkSenseVoice.isInstalled

    var body: some View {
        SettingsCard {
            SettingsToggleRow(
                title: "SenseVoice（中文）",
                detail: detail,
                isOn: Binding(get: { isEnabled }, set: setEnabled)
            )

            if let fraction = download.fraction {
                ProgressView(value: fraction)
                    .tint(HexTheme.success)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else if isInstalled {
                SettingsDivider()

                Button(role: .destructive) {
                    download.remove()
                    refresh()
                } label: {
                    Text(verbatim: "移除模型")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(HexTheme.danger)
            }
        }
        .padding(.top, 8)
        .onAppear {
            refresh()
            if isEnabled, !isInstalled { download.start() }
        }
        .onChange(of: download.fraction == nil) { refresh() }
    }

    private var detail: String {
        if let fraction = download.fraction { return "下載中 \(Int(fraction * 100))%" }
        if download.failed { return "模型沒下載完成，請檢查網路後再開一次" }
        if !isInstalled { return "開啟後下載模型（約 450 MB）" }
        return "辨識時不參考 Custom vocabulary，Word replacements 照常套用"
    }

    private func setEnabled(_ value: Bool) {
        ForkSenseVoice.isEnabled = value
        isEnabled = value
        if value, !isInstalled { download.start() }
        if !value { download.cancel() }
    }

    private func refresh() {
        isEnabled = ForkSenseVoice.isEnabled
        isInstalled = ForkSenseVoice.isInstalled
    }
}

/// SenseVoice's model download, kept while Settings closes: FluidAudio's fp16 files into
/// `ForkSenseVoice.directory` in the App Group, where the keyboard loads them too. A download
/// that fails or stalls turns the lab off again, and its files resume the next time.
@MainActor
@Observable
final class ForkSenseVoiceDownload {
    static let shared = ForkSenseVoiceDownload()

    /// The share downloaded while a download runs.
    private(set) var fraction: Double?
    private(set) var failed = false
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        failed = false
        fraction = 0
        task = Task {
            let started = ContinuousClock.now
            do {
                try await Self.download { value in
                    Task { @MainActor in
                        if ForkSenseVoiceDownload.shared.task != nil { ForkSenseVoiceDownload.shared.fraction = value }
                    }
                }
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "downloaded", detail: ForkSenseVoice.engineName, seconds: (ContinuousClock.now - started) / .seconds(1)))
            } catch is CancellationError {
            } catch {
                let ns = error as NSError
                failed = true
                ForkSenseVoice.isEnabled = false
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "download-failed", detail: "\(ns.domain) \(ns.code)"))
            }
            fraction = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        fraction = nil
    }

    func remove() {
        cancel()
        ForkSenseVoice.isEnabled = false
        try? FileManager.default.removeItem(at: ForkSenseVoice.directory)
    }

    /// FluidAudio's download reports 0–50%, leaving the rest for a compile it doesn't do here.
    nonisolated private static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let reading = ProgressReading()
        SpeechModelStore.prepareRoot()
        try await StallWatch.run(
            limit: ParakeetTranscriber.downloadStallLimit,
            progress: { reading.value },
            operation: {
                try await ModelHub.download(.senseVoiceSmall, to: SpeechModelStore.root, variant: SenseVoiceEncoderPrecision.fp16.rawValue) { event in
                    reading.value = event.fractionCompleted
                    progress(min(1, event.fractionCompleted * 2))
                }
            }
        )
        try Task.checkCancellation()
        SpeechModelStore.markComplete(ForkSenseVoice.directory)
    }
}
