import SwiftUI
import UIKit

/// Hex fork (see FORK.md): `hex-dictation://vocabulary/add?term=<term>` adds a term to the
/// custom vocabulary list (`CustomVocabularySettings`, in the App Group the keyboard reads)
/// under the same rules as Settings' vocabulary editor, then says what happened in an alert.
struct VocabularyLink: Equatable {
    /// The trimmed term; nil when the link names none.
    let term: String?

    init?(url: URL) {
        let path = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        guard url.scheme == "hex-dictation", url.host == "vocabulary", path == ["add"] else {
            return nil
        }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "term" }?
            .value
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        term = trimmed.isEmpty ? nil : trimmed
    }

    enum Outcome: Equatable {
        case added(String)
        case alreadyInList(String)
        case tooLong
        case tooShort
        case full
        case noTerm
    }

    /// Adds the term with `CustomVocabularyEditor`'s checks.
    func apply(to settings: CustomVocabularySettings) -> Outcome {
        guard let term else { return .noTerm }
        guard term.count <= CustomVocabularySettings.maxTermLength else { return .tooLong }
        let key = VocabularySpelling.normalizedKey(term)
        guard key.count >= 2 else { return .tooShort }
        let terms = settings.terms
        if let existing = terms.first(where: { VocabularySpelling.normalizedKey($0) == key }) {
            return .alreadyInList(existing)
        }
        guard terms.count < CustomVocabularySettings.maxTermCount else { return .full }
        settings.terms = terms + [term]
        NotificationCenter.default.post(name: .forkVocabularyChanged, object: nil)
        return .added(term)
    }
}

extension Notification.Name {
    /// Posted after a link or the Mac's vocabulary changes the list, so the editor on screen
    /// reloads its list before its next edit writes the list back.
    static let forkVocabularyChanged = Notification.Name("HexForkVocabularyChanged")
}

extension VocabularyLink.Outcome {
    var title: String {
        switch self {
        case .added: "Added to Vocabulary"
        case .alreadyInList: String(localized: "Already in the list")
        case .tooLong: String(localized: "Too long")
        case .tooShort: String(localized: "Needs at least two letters or digits")
        case .full: String(localized: "Up to 100 terms")
        case .noTerm: "No word in the link"
        }
    }

    var message: String? {
        switch self {
        case .added(let term), .alreadyInList(let term): term
        default: nil
        }
    }
}

/// Shows a link's outcome over whatever is on screen, sheets included.
@MainActor
enum VocabularyLinkAlert {
    static func present(_ outcome: VocabularyLink.Outcome) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let alert = UIAlertController(
            title: outcome.title,
            message: outcome.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        top.present(alert, animated: true)
    }
}

extension View {
    /// Hex fork: handles `hex-dictation://vocabulary/add` links and folds in the Mac's vocabulary
    /// as Hex opens and each time it comes back (FORK.md).
    func forkVocabularyLinks() -> some View {
        onOpenURL { url in
            guard let link = VocabularyLink(url: url) else { return }
            VocabularyLinkAlert.present(link.apply(to: CustomVocabularySettings()))
        }
        .task { applyMacVocabulary() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            applyMacVocabulary()
        }
    }
}

@MainActor
private func applyMacVocabulary() {
    if ForkMacVocabulary.apply() {
        NotificationCenter.default.post(name: .forkVocabularyChanged, object: nil)
    }
}
