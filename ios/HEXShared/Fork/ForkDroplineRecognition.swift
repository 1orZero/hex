import Foundation
import os

nonisolated enum ForkDroplineResult<Local: Sendable>: Sendable {
    case dropline(ForkDroplineAnswer)
    /// `fallback` is why Dropline wasn't used; nil when it isn't selected.
    case local(Local, fallback: ForkDroplineFailure?)
}

/// Dropline heard no speech: the dictation ends quietly with nothing inserted, as when a
/// local engine hears none (`EmptyCapture.endsQuietly`), and the local engine doesn't run.
nonisolated struct ForkDroplineNoSpeech: NoSpeechError {
    var meansNoSpeech: Bool { true }
}

extension ForkDroplineAnswer {
    /// `text`, or `ForkDroplineNoSpeech` when it is empty.
    func spokenText() throws -> String {
        guard !text.isEmpty else { throw ForkDroplineNoSpeech() }
        return text
    }
}

/// The session `prepare` announced, reused by the dictation of that recording.
actor ForkDroplineSessions {
    static let shared = ForkDroplineSessions()
    static let maxAge: TimeInterval = 200

    private var prepared: (id: String, at: Date)?

    func remember(_ id: String, at date: Date) {
        prepared = (id, date)
    }

    func take(now: Date) -> String {
        defer { prepared = nil }
        if let prepared, now.timeIntervalSince(prepared.at) < Self.maxAge {
            return prepared.id
        }
        return UUID().uuidString.lowercased()
    }

    /// The session a live draft goes out in, kept for the next draft and the final text: the
    /// prepared one while it is fresh, else a new one.
    func shared(now: Date) -> String {
        let id = prepared.flatMap { now.timeIntervalSince($0.at) < Self.maxAge ? $0.id : nil }
            ?? UUID().uuidString.lowercased()
        prepared = (id, now)
        return id
    }

    func clear() {
        prepared = nil
    }
}

/// The Dropline private API as a transcription provider: when it is selected, a finished
/// recording goes to Dropline, and any Dropline failure transcribes the same file with the
/// local engine, recording why in the App Group.
nonisolated struct ForkDroplineRecognition: Sendable {
    var settings = ForkDroplineSettings()
    var secrets: any ForkDroplineSecretStore = ForkDroplineKeychain()
    var client = ForkDroplineClient()
    var sessions: ForkDroplineSessions = .shared
    var encode: @Sendable (URL) throws -> Data = { try ForkDroplineAudio.encodedRecording(at: $0) }
    var encodeDraft: @Sendable ([[Int16]]) throws -> Data = { try ForkDroplineAudio.encoded(chunks: $0) }

    private static let log = Logger(subsystem: "anomaly.hex.mobile", category: "fork-dropline")

    var credential: ForkDroplineCredential? {
        guard let endpoint = settings.endpoint, let bearer = secrets.bearer() else { return nil }
        return ForkDroplineCredential(endpoint: endpoint, bearer: bearer)
    }

    /// At the start of a recording; best effort and never waited for. The hints default to the
    /// custom vocabulary, so a hook needs none of its caller's locals.
    static func prepare(hints: [String] = CustomVocabularySettings().activeTerms) {
        Task.detached(priority: .utility) {
            await ForkDroplineRecognition().prepare(hints: hints)
        }
    }

    func prepare(hints: [String]) async {
        guard settings.isEnabled, let credential else { return }
        let session = UUID().uuidString.lowercased()
        await sessions.remember(session, at: client.clock.now())
        await client.prepare(credential, session: session, context: ForkDroplineClient.context(hints: hints))
    }

    /// Dropline when it is selected, else the local engine alone. Cancellation propagates;
    /// every other Dropline failure falls back to `local` with the same recording.
    @concurrent
    func recognize<Local: Sendable>(
        _ url: URL,
        hints: [String],
        local: @escaping @Sendable () async throws -> Local
    ) async throws -> ForkDroplineResult<Local> {
        guard settings.isSelected else {
            return .local(try await local(), fallback: nil)
        }
        let started = client.clock.now()
        do {
            guard let credential else { throw ForkDroplineFailure.notConfigured }
            let audio = try encode(url)
            try Task.checkCancellation()
            let session = await sessions.take(now: client.clock.now())
            let answer = try await client.dictate(
                credential,
                audio: audio,
                session: session,
                context: ForkDroplineClient.context(hints: hints)
            )
            let elapsed = Int(client.clock.now().timeIntervalSince(started) * 1000)
            Self.log.info("Dropline answered in \(elapsed) ms for \(audio.count) bytes of audio")
            return .dropline(answer)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let failure = error as? ForkDroplineFailure ?? .network
            settings.recordFallback(failure.reason, at: client.clock.now())
            Self.log.error("Dropline failed (\(failure.reason, privacy: .public)); using the local engine")
            return .local(try await local(), fallback: failure)
        }
    }

    /// One live draft while recording (`ForkDroplineLiveTranscriber`): the 16 kHz recording so far,
    /// in the session the final text will use. It records no fallback and never runs a local engine.
    @concurrent
    func draft(_ chunks: [[Int16]], hints: [String]) async throws -> ForkDroplineAnswer {
        guard settings.isSelected, let credential else { throw ForkDroplineFailure.notConfigured }
        let audio = try encodeDraft(chunks)
        try Task.checkCancellation()
        let session = await sessions.shared(now: client.clock.now())
        return try await client.dictate(
            credential,
            audio: audio,
            session: session,
            context: ForkDroplineClient.context(hints: hints)
        )
    }

    /// For a caller whose local engine runs after this returns (the keyboard): Dropline's
    /// answer, or nil when it isn't selected or failed (the failure recorded as `recognize` does).
    func answer(for url: URL, hints: [String]) async throws -> ForkDroplineAnswer? {
        switch try await recognize(url, hints: hints, local: {}) {
        case .dropline(let answer):
            return answer
        case .local:
            return nil
        }
    }

    /// Saves the provider only after its endpoint hands out a token for this bearer.
    func save(endpoint: URL, bearer: String) async throws {
        let credential = ForkDroplineCredential(endpoint: endpoint, bearer: bearer)
        let token = try await client.fetchToken(credential)
        try secrets.saveBearer(bearer)
        settings.endpoint = endpoint
        settings.isEnabled = true
        await client.tokens.store(token, for: credential)
    }

    func remove() async {
        secrets.deleteBearer()
        settings.clear()
        await client.tokens.invalidate()
        await sessions.clear()
    }
}
