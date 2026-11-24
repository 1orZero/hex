import XCTest
@testable import HEX

final class ForkDroplineTests: XCTestCase {
    private let endpoint = URL(string: "https://qa-worker.example/v1/dropline-private/token")!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var http: FakeDroplineHTTP!
    private var clock: FakeDroplineClock!
    private var secrets: FakeDroplineSecrets!
    private var tokens: ForkDroplineTokenCache!
    private var sessions: ForkDroplineSessions!

    override func setUp() {
        super.setUp()
        suiteName = "qa-fork-dropline-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        http = FakeDroplineHTTP()
        clock = FakeDroplineClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        secrets = FakeDroplineSecrets()
        tokens = ForkDroplineTokenCache()
        sessions = ForkDroplineSessions()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var credential: ForkDroplineCredential {
        ForkDroplineCredential(endpoint: endpoint, bearer: "qa-bearer")
    }

    private var client: ForkDroplineClient {
        ForkDroplineClient(http: http, clock: clock, tokens: tokens)
    }

    private func makeRecognition(configured: Bool = true) -> ForkDroplineRecognition {
        let settings = ForkDroplineSettings(defaults: defaults)
        if configured {
            settings.endpoint = endpoint
            settings.isEnabled = true
            secrets.stored = "qa-bearer"
        }
        return ForkDroplineRecognition(
            settings: settings,
            secrets: secrets,
            client: client,
            sessions: sessions,
            encode: { _ in Data("qa-ogg".utf8) }
        )
    }

    private func tokenResponse(_ token: String, expiresIn seconds: TimeInterval = 3600) -> FakeDroplineHTTP.Handler {
        let expiresAt = (clock.now().timeIntervalSince1970 + seconds) * 1000
        return FakeDroplineHTTP.json(200, ["access_token": token, "expires_at": expiresAt])
    }

    private func storeToken(_ token: String = "qa-access-cached") async {
        await tokens.store(
            ForkDroplineAccessToken(value: token, expiresAt: clock.now().addingTimeInterval(3600)),
            for: credential
        )
    }

    // MARK: - Token cache

    func testTokenIsFetchedOnceAndReusedUntilFiveMinutesBeforeItExpires() async throws {
        http.enqueue(tokenResponse("qa-access-1"))
        http.enqueue(tokenResponse("qa-access-2"))
        http.enqueue(tokenResponse("qa-access-3"))

        let first = try await client.accessToken(credential)
        let second = try await client.accessToken(credential)
        XCTAssertEqual(first, "qa-access-1")
        XCTAssertEqual(second, "qa-access-1")
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer qa-bearer")

        clock.advance(3600 - 301)
        let stillCached = try await client.accessToken(credential)
        XCTAssertEqual(stillCached, "qa-access-1")
        XCTAssertEqual(http.requests.count, 1)

        clock.advance(2)
        let refetched = try await client.accessToken(credential)
        XCTAssertEqual(refetched, "qa-access-2")
        XCTAssertEqual(http.requests.count, 2)

        await tokens.invalidate()
        let afterInvalidate = try await client.accessToken(credential)
        XCTAssertEqual(afterInvalidate, "qa-access-3")
        XCTAssertEqual(http.requests.count, 3)
    }

    func testTokenEndpointFailuresAreNamed() async {
        http.enqueue(FakeDroplineHTTP.json(404, ["error": "qa-not-connected"]))
        http.enqueue(FakeDroplineHTTP.json(200, ["access_token": "qa-access"]))
        await XCTAssertThrowsFailure(.tokenEndpoint("HTTP 404")) { _ = try await self.client.fetchToken(self.credential) }
        await XCTAssertThrowsFailure(.tokenEndpoint("回應格式錯誤")) { _ = try await self.client.fetchToken(self.credential) }
    }

    // MARK: - Dictate

    func testDictate401RefetchesTheTokenOnceAndSucceeds() async throws {
        http.enqueue(tokenResponse("qa-access-old"))
        http.enqueue(FakeDroplineHTTP.json(401, ["error": "qa-expired"]))
        http.enqueue(tokenResponse("qa-access-new"))
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa hello", "transcript": ["text": "qa hello", "language": "en"]]))
        let localCalls = ForkDroplineCounter()

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: ["qa-term"]) {
            localCalls.increment()
            return "qa-local"
        }

        guard case .dropline(let answer) = result else { return XCTFail("expected Dropline, got \(result)") }
        XCTAssertEqual(answer, ForkDroplineAnswer(text: "qa hello", language: "en"))
        XCTAssertEqual(localCalls.value, 0)
        let requests = http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.dropline.fish.audio/client/dictate")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer qa-access-old")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer qa-access-new")
        XCTAssertTrue(requests[3].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback)
    }

    func testDictate401TwiceFallsBackToTheLocalEngineWithTheSameRecording() async throws {
        http.enqueue(tokenResponse("qa-access-old"))
        http.enqueue(FakeDroplineHTTP.json(401, [:]))
        http.enqueue(tokenResponse("qa-access-new"))
        http.enqueue(FakeDroplineHTTP.json(401, [:]))
        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("qa-recording-\(UUID().uuidString).wav")
        try Data("qa-audio".utf8).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }
        let encoded = ForkDroplineRecorder<URL>()
        let localReads = ForkDroplineRecorder<Data>()
        var recognition = makeRecognition()
        recognition.encode = { url in
            encoded.append(url)
            return Data("qa-ogg".utf8)
        }

        let result = try await recognition.recognize(recording, hints: []) {
            let audio = try Data(contentsOf: recording)
            localReads.append(audio)
            return "qa-local"
        }

        guard case .local(let text, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(text, "qa-local")
        XCTAssertEqual(fallback, .unauthorized)
        XCTAssertEqual(encoded.values, [recording])
        XCTAssertEqual(localReads.values, [Data("qa-audio".utf8)])
        XCTAssertEqual(http.requests.count, 4)
        let recorded = try XCTUnwrap(ForkDroplineSettings(defaults: defaults).lastFallback)
        XCTAssertEqual(recorded.reason, "授權失敗（401）")
        XCTAssertEqual(recorded.at, clock.now())
    }

    func testDictateTimeoutFallsBack() async throws {
        await storeToken()
        clock.timesOut = true
        http.enqueue(FakeDroplineHTTP.hang)

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(let text, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(text, "qa-local")
        XCTAssertEqual(fallback, .timeout)
        XCTAssertEqual(ForkDroplineSettings(defaults: defaults).lastFallback?.reason, "逾時")
    }

    func testNetworkErrorFallsBack() async throws {
        await storeToken()
        http.enqueue { _ in throw URLError(.notConnectedToInternet) }

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(_, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(fallback, .network)
        XCTAssertEqual(ForkDroplineSettings(defaults: defaults).lastFallback?.reason, "網路錯誤")
    }

    func testServerErrorIsNotRetried() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.json(503, [:]))

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(_, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(fallback, .http(status: 503))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testAnswerWithoutFinalTextFallsBack() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.json(200, ["text": "qa-wrong-field"]))

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(_, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(fallback, .invalidResponse)
    }

    func testEmptyFinalTextIsAnAnswerNotAFailure() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": ""]))
        let localCalls = ForkDroplineCounter()

        let result = try await makeRecognition().recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) {
            localCalls.increment()
            return "qa-local"
        }

        guard case .dropline(let answer) = result else { return XCTFail("expected Dropline, got \(result)") }
        XCTAssertEqual(answer.text, "")
        XCTAssertEqual(localCalls.value, 0)
    }

    func testAnEmptyAnswerEndsTheDictationQuietly() throws {
        XCTAssertEqual(try ForkDroplineAnswer(text: "qa hello", language: "en").spokenText(), "qa hello")
        XCTAssertThrowsError(try ForkDroplineAnswer(text: "", language: nil).spokenText()) { error in
            XCTAssertTrue(EmptyCapture.endsQuietly(error), "\(error)")
        }
    }

    // MARK: - Keyboard

    func testKeyboardGetsDroplinesAnswer() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa 你好", "transcript": ["language": "zh"]]))

        let answer = try await makeRecognition().answer(for: URL(fileURLWithPath: "/tmp/qa.wav"), hints: ["qa-term"])

        XCTAssertEqual(answer, ForkDroplineAnswer(text: "qa 你好", language: "zh"))
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback)
    }

    func testKeyboardGetsNothingWhenDroplineIsNotSelected() async throws {
        let recognition = makeRecognition()
        ForkDroplineSettings(defaults: defaults).isEnabled = false

        let answer = try await recognition.answer(for: URL(fileURLWithPath: "/tmp/qa.wav"), hints: [])

        XCTAssertNil(answer)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testKeyboardGetsNothingAfterAFailureAndTheFailureIsRecorded() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.json(503, [:]))

        let answer = try await makeRecognition().answer(for: URL(fileURLWithPath: "/tmp/qa.wav"), hints: [])

        XCTAssertNil(answer)
        XCTAssertEqual(ForkDroplineSettings(defaults: defaults).lastFallback?.reason, "HTTP 503")
    }

    func testEncodingFailureFallsBackWithoutNetwork() async throws {
        var recognition = makeRecognition()
        recognition.encode = { _ in throw ForkDroplineFailure.tooLong }

        let result = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(_, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(fallback, .tooLong)
        XCTAssertEqual(ForkDroplineSettings(defaults: defaults).lastFallback?.reason, "錄音超過 178 秒")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testMissingBearerFallsBack() async throws {
        let recognition = makeRecognition()
        secrets.stored = nil

        let result = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(_, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(fallback, .notConfigured)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testNotSelectedUsesTheLocalEngineAlone() async throws {
        let recognition = makeRecognition()
        ForkDroplineSettings(defaults: defaults).isEnabled = false

        let result = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }

        guard case .local(let text, let fallback) = result else { return XCTFail("expected local, got \(result)") }
        XCTAssertEqual(text, "qa-local")
        XCTAssertNil(fallback)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback)
    }

    func testCancellationPropagatesInsteadOfFallingBack() async throws {
        await storeToken()
        http.enqueue(FakeDroplineHTTP.hang)
        let recognition = makeRecognition()
        let localCalls = ForkDroplineCounter()

        let task = Task {
            try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) {
                localCalls.increment()
                return "qa-local"
            }
        }
        for _ in 0..<500 where http.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        guard !http.requests.isEmpty else {
            _ = await task.result
            return XCTFail("expected a Dropline request")
        }

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(localCalls.value, 0)
        XCTAssertNil(ForkDroplineSettings(defaults: defaults).lastFallback)
    }

    // MARK: - Request shape

    func testMultipartPartsAreRequestContextAudioInThatOrder() throws {
        let body = ForkDroplineClient.multipart(
            boundary: "qa-boundary",
            session: "qa-session",
            context: ["text": "qa-one, qa-two"],
            audio: Data("qa-ogg".utf8)
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        let expected = [
            "--qa-boundary\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n",
            #"{"client":{"session_id":"qa-session"},"language":"auto","mode":"dictate"}"#,
            "\r\n--qa-boundary\r\nContent-Disposition: form-data; name=\"context\"\r\nContent-Type: application/json\r\n\r\n",
            #"{"text":"qa-one, qa-two"}"#,
            "\r\n--qa-boundary\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n",
            "qa-ogg",
            "\r\n--qa-boundary--\r\n",
        ].joined()
        XCTAssertEqual(text, expected)

        let withoutContext = try XCTUnwrap(String(
            data: ForkDroplineClient.multipart(boundary: "qa-b", session: "qa-s", context: [:], audio: Data("qa".utf8)),
            encoding: .utf8
        ))
        XCTAssertFalse(withoutContext.contains("name=\"context\""))
        XCTAssertTrue(withoutContext.contains("name=\"request\""))
        XCTAssertTrue(withoutContext.contains("name=\"audio\""))
    }

    func testContextCarriesTheVocabularyHints() {
        XCTAssertEqual(ForkDroplineClient.context(hints: [" qa-Hex ", "", "qa-Dropline"]), ["text": "qa-Hex, qa-Dropline"])
        XCTAssertEqual(ForkDroplineClient.context(hints: ["  "]), [:])
    }

    func testDictationReusesThePreparedSessionForUpTo200Seconds() async throws {
        let recognition = makeRecognition()
        http.enqueue(tokenResponse("qa-access"))
        http.enqueue(FakeDroplineHTTP.json(200, [:]))
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa one"]))
        http.enqueue(FakeDroplineHTTP.json(200, [:]))
        http.enqueue(FakeDroplineHTTP.json(200, ["final_text": "qa two"]))

        await recognition.prepare(hints: ["qa-term"])
        let prepare = http.requests[1]
        XCTAssertEqual(prepare.url?.absoluteString, "https://api.dropline.fish.audio/client/dictate/prepare")
        XCTAssertEqual(prepare.httpMethod, "POST")
        XCTAssertEqual(prepare.value(forHTTPHeaderField: "Authorization"), "Bearer qa-access")
        let first = try preparedSession(prepare)
        XCTAssertEqual(first, first.lowercased())
        let prepareBody = try XCTUnwrap(JSONSerialization.jsonObject(with: prepare.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(prepareBody["context"] as? [String: String], ["text": "qa-term"])

        clock.advance(199)
        _ = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }
        XCTAssertTrue(String(decoding: http.requests[2].httpBody ?? Data(), as: UTF8.self).contains(first))

        await recognition.prepare(hints: [])
        let second = try preparedSession(http.requests[3])
        clock.advance(201)
        _ = try await recognition.recognize(URL(fileURLWithPath: "/tmp/qa.wav"), hints: []) { "qa-local" }
        let lastBody = String(decoding: http.requests[4].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(lastBody.contains(#""session_id":""#))
        XCTAssertFalse(lastBody.contains(first))
        XCTAssertFalse(lastBody.contains(second))
    }

    private func preparedSession(_ request: URLRequest) throws -> String {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        return try XCTUnwrap((body["client"] as? [String: Any])?["session_id"] as? String)
    }

    // MARK: - Settings

    func testSaveStoresNothingWhenTheTokenFetchFails() async {
        let recognition = makeRecognition(configured: false)
        http.enqueue(FakeDroplineHTTP.json(401, [:]))

        await XCTAssertThrowsFailure(.tokenEndpoint("HTTP 401")) {
            try await recognition.save(endpoint: self.endpoint, bearer: "qa-bearer")
        }

        let settings = ForkDroplineSettings(defaults: defaults)
        XCTAssertNil(secrets.stored)
        XCTAssertNil(settings.endpoint)
        XCTAssertFalse(settings.isEnabled)
    }

    func testSaveStoresEndpointAndBearerAfterATokenArrives() async throws {
        let recognition = makeRecognition(configured: false)
        http.enqueue(tokenResponse("qa-access"))

        try await recognition.save(endpoint: endpoint, bearer: "qa-bearer")

        let settings = ForkDroplineSettings(defaults: defaults)
        XCTAssertEqual(secrets.stored, "qa-bearer")
        XCTAssertEqual(settings.endpoint, endpoint)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer qa-bearer")
        let cached = try await client.accessToken(credential)
        XCTAssertEqual(cached, "qa-access")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRemoveClearsBearerSettingsAndCachedToken() async throws {
        let recognition = makeRecognition()
        await storeToken("qa-access-cached")
        let settings = ForkDroplineSettings(defaults: defaults)
        settings.recordFallback("逾時", at: clock.now())

        await recognition.remove()

        XCTAssertNil(secrets.stored)
        XCTAssertNil(settings.endpoint)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(settings.lastFallback)
        http.enqueue(tokenResponse("qa-access-fresh"))
        let token = try await client.accessToken(credential)
        XCTAssertEqual(token, "qa-access-fresh")
    }

    /// Simulator only: on an iPhone this item is the real bearer.
    func testKeychainKeepsTheBearerOnTheSimulator() throws {
        #if targetEnvironment(simulator)
        let keychain = ForkDroplineKeychain()
        keychain.deleteBearer()
        do {
            try keychain.saveBearer("qa-bearer-keychain")
        } catch let error as ForkDroplineKeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("A build without code signing has no keychain")
        }
        XCTAssertEqual(keychain.bearer(), "qa-bearer-keychain")
        keychain.deleteBearer()
        XCTAssertNil(keychain.bearer())
        #else
        throw XCTSkip("Runs on the simulator only")
        #endif
    }

    private func XCTAssertThrowsFailure(
        _ expected: ForkDroplineFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ForkDroplineFailure, expected, file: file, line: line)
        }
    }
}

// MARK: - Fakes

final class FakeDroplineHTTP: ForkDroplineHTTP, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var handlers: [Handler] = []
    private var sent: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { sent } }

    func enqueue(_ handler: @escaping Handler) {
        lock.withLock { handlers.append(handler) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock { () -> Handler? in
            sent.append(request)
            return handlers.isEmpty ? nil : handlers.removeFirst()
        }
        guard let handler else { throw URLError(.unsupportedURL) }
        return try await handler(request)
    }

    static func json(_ status: Int, _ body: [String: Any]) -> Handler {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let hang: Handler = { _ in
        try await Task.sleep(for: .seconds(3600))
        throw URLError(.timedOut)
    }
}

final class FakeDroplineClock: ForkDroplineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var expires = false

    init(now: Date) {
        current = now
    }

    /// Every deadline passes at once instead of never.
    var timesOut: Bool {
        get { lock.withLock { expires } }
        set { lock.withLock { expires = newValue } }
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(for duration: Duration) async throws {
        if timesOut { return }
        try await Task.sleep(for: .seconds(3600))
    }
}

final class FakeDroplineSecrets: ForkDroplineSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bearerValue: String?

    var stored: String? {
        get { lock.withLock { bearerValue } }
        set { lock.withLock { bearerValue = newValue } }
    }

    func bearer() -> String? { stored }

    func saveBearer(_ bearer: String) throws { stored = bearer }

    func deleteBearer() { stored = nil }
}

final class ForkDroplineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

final class ForkDroplineRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    var values: [Value] { lock.withLock { recorded } }

    func append(_ value: Value) {
        lock.withLock { recorded.append(value) }
    }
}
