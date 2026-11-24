import Foundation

/// The keyboard's own dictation (`KeyboardTranscription`) behind the fork's Dropline private API:
/// Dropline's text when it is selected and answers, else nil, and the keyboard's local engine
/// transcribes the same recording. Hex's steps then run in the dictation language, as they do
/// for the app's dictations through Dropline.
enum ForkKeyboardDropline {
    static let engine = "Dropline 私人 API (keyboard)"

    static func transcribe(_ url: URL, hints: [String]) async throws -> (String, SpeechLanguage, String)? {
        guard let answer = try await ForkDroplineRecognition().answer(for: url, hints: hints) else { return nil }
        let identifier = LanguageSettings().effectiveDictationLanguage ?? Locale.preferredLanguages.first ?? "en-US"
        return (try answer.spokenText(), SpeechLanguage(locale: Locale(identifier: identifier), module: .speech), engine)
    }
}
