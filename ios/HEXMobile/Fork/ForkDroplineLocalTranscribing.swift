import Foundation

extension LocalTranscribing {
    /// This engine's transcription behind the fork's Dropline private API
    /// (`ForkDroplineRecognition`): Dropline when selected, this engine otherwise and on any
    /// Dropline failure. An empty Dropline answer means it heard no speech.
    nonisolated func transcribePreferringDropline(_ audioURL: URL, vocabulary: [String]) async throws -> String {
        let result = try await ForkDroplineRecognition().recognize(audioURL, hints: vocabulary) {
            try await self.transcribe(audioURL, vocabulary: vocabulary)
        }
        switch result {
        case .dropline(let answer):
            return try answer.spokenText()
        case .local(let text, _):
            return text
        }
    }
}
