import XCTest
@testable import HEX

final class VocabularyLinkTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "VocabularyLinkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func link(_ string: String) -> VocabularyLink? {
        VocabularyLink(url: URL(string: string)!)
    }

    func testReadsTheTermPercentDecodedAndTrimmed() {
        XCTAssertEqual(link("hex-dictation://vocabulary/add?term=qa-Foo")?.term, "qa-Foo")
        XCTAssertEqual(link("hex-dictation://vocabulary/add?term=%E5%8F%B0%E5%8C%97")?.term, "台北")
        XCTAssertEqual(link("hex-dictation://vocabulary/add/?term=%20Dax%20Rad%20")?.term, "Dax Rad")
        XCTAssertEqual(link("hex-dictation://vocabulary/Add?term=C++")?.term, "C++")
    }

    func testALinkWithoutATermNamesNone() {
        for string in [
            "hex-dictation://vocabulary/add",
            "hex-dictation://vocabulary/add?term=",
            "hex-dictation://vocabulary/add?term=%20%20",
            "hex-dictation://vocabulary/add?sounds_like=foo",
        ] {
            let parsed = link(string)
            XCTAssertNotNil(parsed, string)
            XCTAssertNil(parsed?.term, string)
            XCTAssertEqual(parsed?.apply(to: CustomVocabularySettings(defaults: defaults)), .noTerm)
        }
    }

    func testLeavesOtherLinksAlone() {
        for string in [
            "hex-dictation://keyboard/start?ts=100",
            "hex-dictation://vocabulary",
            "hex-dictation://vocabulary/remove?term=qa-Foo",
            "hex-dictation://vocabulary/add/more?term=qa-Foo",
            "hex://vocabulary/add?term=qa-Foo",
            "https://vocabulary/add?term=qa-Foo",
        ] {
            XCTAssertNil(link(string), string)
        }
        XCTAssertNil(KeyboardLaunchRequest(url: URL(string: "hex-dictation://vocabulary/add?term=qa-Foo")!))
    }

    func testAddsTheTermWhereTheKeyboardReadsIt() {
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["OpenCode"]

        let outcome = link("hex-dictation://vocabulary/add?term=qa-Foo")?.apply(to: settings)

        XCTAssertEqual(outcome, .added("qa-Foo"))
        XCTAssertEqual(outcome?.title, "Added to Vocabulary")
        XCTAssertEqual(outcome?.message, "qa-Foo")
        XCTAssertEqual(CustomVocabularySettings(defaults: defaults).terms, ["OpenCode", "qa-Foo"])
    }

    func testAnExistingTermSaysSoAndChangesNothing() {
        let settings = CustomVocabularySettings(defaults: defaults)
        settings.terms = ["qa-Foo"]

        let outcome = link("hex-dictation://vocabulary/add?term=QA%20FOO")?.apply(to: settings)

        XCTAssertEqual(outcome, .alreadyInList("qa-Foo"))
        XCTAssertEqual(outcome?.message, "qa-Foo")
        XCTAssertEqual(CustomVocabularySettings(defaults: defaults).terms, ["qa-Foo"])
    }

    func testTheEditorsLimitsRefuseAndChangeNothing() {
        let settings = CustomVocabularySettings(defaults: defaults)
        let tooLong = String(repeating: "x", count: CustomVocabularySettings.maxTermLength + 1)
        XCTAssertEqual(link("hex-dictation://vocabulary/add?term=\(tooLong)")?.apply(to: settings), .tooLong)
        XCTAssertEqual(link("hex-dictation://vocabulary/add?term=a")?.apply(to: settings), .tooShort)
        XCTAssertEqual(settings.terms, [])

        let full = (1...CustomVocabularySettings.maxTermCount).map { "Term \($0)" }
        settings.terms = full
        XCTAssertEqual(link("hex-dictation://vocabulary/add?term=qa-Foo")?.apply(to: settings), .full)
        XCTAssertEqual(CustomVocabularySettings(defaults: defaults).terms, full)
    }
}
