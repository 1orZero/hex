import FluidAudio
import SwiftUI

/// Labs › SenseVoice（中文） (fork), after the Dictation card: the switch, the model's download
/// with its progress, started by turning the switch on, and once it's on the iPhone, whether the
/// keyboard runs it (`ForkSenseVoiceKeyboardLine`) and Remove model.
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
                if isEnabled { ForkSenseVoiceKeyboardLine() }

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

/// Under the switch once the model is on the iPhone: whether the keyboard runs SenseVoice, the limit
/// the keyboard measured, and the limit SenseVoice needs (`ForkSenseVoiceBudget.requiredLimit`), in
/// the words Settings › Dictation uses for Parakeet in the keyboard (`KeyboardParakeetStatus`). The
/// keyboard's word, written as it opens (`ForkSenseVoiceKeyboardStatus`), is read every 2 s, as there.
struct ForkSenseVoiceKeyboardLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let status = ForkSenseVoiceKeyboardStatus()
            let lines = Self.lines(
                parakeetTakes: KeyboardParakeetPlan.current().modelChoice != nil,
                keyboardLimit: KeyboardParakeetSettings().keyboardLimit,
                keyboardState: status.state,
                reason: status.reason,
                free: status.free,
                now: context.date
            )
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text(verbatim: $0) }
            }
            .font(.system(size: 13))
            .foregroundStyle(HexTheme.textBase)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fork-sensevoice-keyboard-status")
        }
    }

    /// Parakeet's plan taking the keyboard comes first, then a limit under SenseVoice's, then the
    /// limit and what the keyboard last said. Upstream's lines keep their words (and translations);
    /// only the two without a counterpart there are new.
    static func lines(
        parakeetTakes: Bool,
        keyboardLimit: Int?,
        keyboardState: (state: KeyboardParakeetSettings.KeyboardState, at: Date)?,
        reason: KeyboardParakeetSettings.UnavailableReason?,
        free: Int?,
        now: Date
    ) -> [String] {
        if parakeetTakes { return ["The keyboard uses Hex's speech model for this language instead of SenseVoice."] }
        let state = stateLine(keyboardState, reason: reason, free: free, now: now)
        guard let keyboardLimit, KeyboardParakeetStatus.megabytes(keyboardLimit) > 0 else { return [state] }
        let has = KeyboardParakeetStatus.megabytes(keyboardLimit)
        let needs = KeyboardParakeetStatus.megabytes(ForkSenseVoiceBudget.requiredLimit)
        guard keyboardLimit >= ForkSenseVoiceBudget.requiredLimit else {
            return [String(localized: "This iPhone's keyboard has \(has) MB; the model needs \(needs) MB, so it uses Apple's speech recognition.")]
        }
        return ["This iPhone's keyboard has \(has) MB; the model needs \(needs) MB.", state]
    }

    /// `KeyboardParakeetStatus.keyboardLine` with SenseVoice's load headroom.
    private static func stateLine(
        _ keyboardState: (state: KeyboardParakeetSettings.KeyboardState, at: Date)?,
        reason: KeyboardParakeetSettings.UnavailableReason?,
        free: Int?,
        now: Date
    ) -> String {
        switch keyboardState {
        case (.preparing, let at)? where now.timeIntervalSince(at) < 180:
            return String(localized: "Getting ready in the keyboard. After a download or an update, this takes a little longer.")
        case (.ready, _)?:
            return String(localized: "Ready in the keyboard")
        case (.unavailable, _)? where reason == .shortOfMemory:
            let needs = ForkSenseVoiceBudget.loadHeadroom
            guard let free, free < needs, KeyboardParakeetStatus.megabytes(free) > 0 else {
                return KeyboardParakeetStatus.unavailableLine(.shortOfMemory)
            }
            return String(localized: "The keyboard had \(KeyboardParakeetStatus.megabytes(free)) MB free when it last opened; loading the model needs \(KeyboardParakeetStatus.megabytes(needs)) MB, so it used Apple's speech recognition. It tries again the next time it opens.")
        case (.unavailable, _)? where reason != nil:
            return KeyboardParakeetStatus.unavailableLine(reason)
        default:
            return KeyboardParakeetStatus.unavailableLine(nil)
        }
    }
}

/// SenseVoice's model download, kept while Settings closes: FluidAudio's fp16 files into
/// `ForkSenseVoice.directory` in the App Group, where the keyboard loads them too. A download
/// that fails or stalls turns the lab off again, and its files resume the next time; one that
/// finishes loads the model in the app (`ForkSenseVoice.prewarm`). A new
/// download or a removal waits for a cancelled one to finish, and a cancelled one's progress and
/// end no longer show (`generation`).
@MainActor
@Observable
final class ForkSenseVoiceDownload {
    static let shared = ForkSenseVoiceDownload()

    /// The share downloaded while a download runs.
    private(set) var fraction: Double?
    private(set) var failed = false
    private var task: Task<Void, Never>?
    private var generation = 0

    func start() {
        guard fraction == nil else { return }
        generation += 1
        let current = generation
        let previous = task
        failed = false
        fraction = 0
        task = Task {
            await previous?.value
            guard generation == current else { return }
            let started = ContinuousClock.now
            do {
                try await Self.download { value in
                    Task { @MainActor in
                        let download = ForkSenseVoiceDownload.shared
                        if download.generation == current { download.fraction = value }
                    }
                }
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "downloaded", detail: ForkSenseVoice.engineName, seconds: (ContinuousClock.now - started) / .seconds(1)))
                ForkSenseVoice.prewarm()
            } catch is CancellationError {
            } catch {
                let ns = error as NSError
                if generation == current {
                    failed = true
                    ForkSenseVoice.isEnabled = false
                }
                ForkSenseVoice.note(ForkSenseVoice.Record(event: "download-failed", detail: "\(ns.domain) \(ns.code)"))
            }
            guard generation == current else { return }
            fraction = nil
            task = nil
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        fraction = nil
    }

    /// Turns the lab off and deletes the files once any download has stopped; the model reads
    /// as removed at once.
    func remove() {
        cancel()
        ForkSenseVoice.isEnabled = false
        SpeechModelStore.clearComplete(ForkSenseVoice.directory)
        let previous = task
        task = Task {
            await previous?.value
            try? FileManager.default.removeItem(at: ForkSenseVoice.directory)
        }
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
