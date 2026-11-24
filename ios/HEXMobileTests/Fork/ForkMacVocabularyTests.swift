import XCTest
@testable import HEX

final class ForkMacVocabularyTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        suite = "ForkMacVocabularyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var list: [String] {
        get { CustomVocabularySettings(defaults: defaults).terms }
        set { CustomVocabularySettings(defaults: defaults).terms = newValue }
    }

    /// Writes the Mac's copy as fork/daily.sh does and applies it.
    @discardableResult
    private func copy(_ terms: [String]) throws -> Bool {
        let url = folder.appendingPathComponent(ForkMacVocabulary.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["terms": terms]).write(to: url)
        return ForkMacVocabulary.apply(from: url, defaults: defaults)
    }

    func testTheFirstCopyKeepsTheIPhonesTermsFirstAndAddsTheMacsInItsOrder() throws {
        list = ["qa-phone-one", "qa-phone-two"]
        XCTAssertTrue(try copy(["qa-mac-gamma", "qa-mac-alpha", "qa-mac-beta"]))
        XCTAssertEqual(list, ["qa-phone-one", "qa-phone-two", "qa-mac-gamma", "qa-mac-alpha", "qa-mac-beta"])
        XCTAssertEqual(defaults.stringArray(forKey: ForkMacVocabulary.syncedKey), ["qa-mac-gamma", "qa-mac-alpha", "qa-mac-beta"])
    }

    func testCopyURLMatchesTheNightlyDestination() throws {
        let group = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup))
        XCTAssertEqual(ForkMacVocabulary.copyURL, group.appendingPathComponent("Library/fork-mac-vocabulary.json"))
    }

    func testALaterCopyRemovesWhatTheMacDroppedAndKeepsTheIPhonesOwn() throws {
        list = ["qa-phone-one", "qa-shared"]
        try copy(["qa-mac-alpha", "qa-shared", "qa-mac-beta"])
        list = list + ["qa-phone-later"]
        XCTAssertTrue(try copy(["qa-mac-beta", "qa-mac-delta"]))
        XCTAssertEqual(list, ["qa-phone-one", "qa-shared", "qa-phone-later", "qa-mac-beta", "qa-mac-delta"])
        XCTAssertEqual(defaults.stringArray(forKey: ForkMacVocabulary.syncedKey), ["qa-mac-beta", "qa-mac-delta"])
    }

    func testTheMacsReorderingMovesItsTermsAndALetterCaseChangeReplacesTheTerm() throws {
        list = ["qa-phone-one"]
        try copy(["qa-mac-alpha", "qa-mac-beta", "qa-github"])
        try copy(["qa-GitHub", "qa-mac-beta", "qa-mac-alpha"])
        XCTAssertEqual(list, ["qa-phone-one", "qa-GitHub", "qa-mac-beta", "qa-mac-alpha"])
    }

    func testTheMacsTermsFillTheListTo90InTheMacsOrder() throws {
        let own = (1...5).map { "qa-phone-\($0)" }
        let mac = (1...200).map { "qa-mac-\($0)" }
        list = own
        try copy(mac)
        XCTAssertEqual(list, own + Array(mac.prefix(85)))
        XCTAssertEqual(list.count, ForkMacVocabulary.listLimit)
    }

    func testTermsTheListRefusesAreSkippedForTheNextOnes() throws {
        list = ["qa-phone-one"]
        try copy(["QA-PHONE-ONE", "x", String(repeating: "q", count: 65), "qa-mac-alpha", "qa-mac-alpha"])
        XCTAssertEqual(list, ["qa-phone-one", "qa-mac-alpha"])
    }

    func testTheSameCopyIsAppliedOnce() throws {
        list = ["qa-phone-one"]
        XCTAssertTrue(try copy(["qa-mac-alpha", "qa-mac-beta"]))
        list = ["qa-phone-one", "qa-mac-beta"]
        XCTAssertFalse(try copy(["qa-mac-alpha", "qa-mac-beta"]))
        XCTAssertEqual(list, ["qa-phone-one", "qa-mac-beta"])
    }

    func testNoCopyOrAnUnreadableCopyChangesNothing() throws {
        list = ["qa-phone-one"]
        XCTAssertFalse(ForkMacVocabulary.apply(from: folder.appendingPathComponent("missing.json"), defaults: defaults))
        let bad = folder.appendingPathComponent("bad.json")
        try Data("{\"words\": []}".utf8).write(to: bad)
        XCTAssertFalse(ForkMacVocabulary.apply(from: bad, defaults: defaults))
        XCTAssertEqual(list, ["qa-phone-one"])
        XCTAssertNil(defaults.stringArray(forKey: ForkMacVocabulary.syncedKey))
    }
}
