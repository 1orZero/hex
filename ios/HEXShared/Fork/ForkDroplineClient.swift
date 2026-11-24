import Foundation

nonisolated protocol ForkDroplineHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session, so neither the bearer nor an access token reaches a disk cache.
nonisolated struct ForkDroplineURLSession: ForkDroplineHTTP {
    private static let session = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

nonisolated protocol ForkDroplineClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

nonisolated struct ForkDroplineSystemClock: ForkDroplineClock {
    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Why a dictation didn't go through Dropline; `reason` is what Settings and the typing log show.
nonisolated enum ForkDroplineFailure: Error, Equatable {
    case notConfigured
    case tokenEndpoint(String)
    case unauthorized
    case http(status: Int)
    case timeout
    case network
    case invalidResponse
    case encoding
    case tooLong

    var reason: String {
        switch self {
        case .notConfigured: "找不到 Bearer token"
        case .tokenEndpoint(let detail): "Token 端點失敗（\(detail)）"
        case .unauthorized: "授權失敗（401）"
        case .http(let status): "HTTP \(status)"
        case .timeout: "逾時"
        case .network: "網路錯誤"
        case .invalidResponse: "回應格式錯誤"
        case .encoding: "編碼失敗"
        case .tooLong: "錄音超過 178 秒"
        }
    }
}

nonisolated struct ForkDroplineCredential: Equatable, Sendable {
    let endpoint: URL
    let bearer: String
}

nonisolated struct ForkDroplineAccessToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date
}

/// Dropline's answer: `text` is `final_text`, empty when it heard no speech.
nonisolated struct ForkDroplineAnswer: Equatable, Sendable {
    let text: String
    let language: String?
}

/// The private API's access token, kept in memory until five minutes before it expires and
/// dropped when Dropline refuses it. Only the Worker refreshes tokens; this never does.
actor ForkDroplineTokenCache {
    static let shared = ForkDroplineTokenCache()
    static let margin: TimeInterval = 5 * 60

    private var cached: (credential: ForkDroplineCredential, token: ForkDroplineAccessToken)?

    func token(
        for credential: ForkDroplineCredential,
        now: Date,
        fetch: @Sendable () async throws -> ForkDroplineAccessToken
    ) async throws -> String {
        if let cached, cached.credential == credential,
           cached.token.expiresAt.timeIntervalSince(now) > Self.margin {
            return cached.token.value
        }
        cached = nil
        let fresh = try await fetch()
        cached = (credential, fresh)
        return fresh.value
    }

    func store(_ token: ForkDroplineAccessToken, for credential: ForkDroplineCredential) {
        cached = (credential, token)
    }

    func invalidate() {
        cached = nil
    }
}

/// The recognition half of Derek Voice's Dropline private API: the Worker's token endpoint,
/// `/client/dictate/prepare` and `/client/dictate`.
nonisolated struct ForkDroplineClient: Sendable {
    static let baseURL = URL(string: "https://api.dropline.fish.audio")!
    static let tokenTimeout: Duration = .seconds(5)
    static let prepareTimeout: Duration = .seconds(3)
    /// The whole dictate wait, the 401 token refetch and retry included.
    static let dictateTimeout: Duration = .seconds(10)
    static let retryMinimum: Duration = .seconds(3)

    var http: any ForkDroplineHTTP = ForkDroplineURLSession()
    var clock: any ForkDroplineClock = ForkDroplineSystemClock()
    var tokens: ForkDroplineTokenCache = .shared

    /// `GET <endpoint>` with the bearer: `{access_token, expires_at}`, `expires_at` in epoch ms.
    /// A 404 means the Worker has no Dropline connection.
    func fetchToken(_ credential: ForkDroplineCredential) async throws -> ForkDroplineAccessToken {
        var request = URLRequest(url: credential.endpoint, timeoutInterval: Self.seconds(Self.tokenTimeout))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(
            request,
            within: Self.tokenTimeout,
            timeout: .tokenEndpoint(ForkDroplineFailure.timeout.reason),
            network: .tokenEndpoint(ForkDroplineFailure.network.reason)
        )
        guard response.statusCode == 200 else { throw ForkDroplineFailure.tokenEndpoint("HTTP \(response.statusCode)") }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = body["access_token"] as? String, !token.isEmpty,
              let expiresAt = (body["expires_at"] as? NSNumber)?.doubleValue else {
            throw ForkDroplineFailure.tokenEndpoint(ForkDroplineFailure.invalidResponse.reason)
        }
        return ForkDroplineAccessToken(value: token, expiresAt: Date(timeIntervalSince1970: expiresAt / 1000))
    }

    func accessToken(_ credential: ForkDroplineCredential) async throws -> String {
        try await tokens.token(for: credential, now: clock.now()) {
            try await fetchToken(credential)
        }
    }

    /// Best effort: tells Dropline a recording started; any failure is ignored.
    func prepare(_ credential: ForkDroplineCredential, session: String, context: [String: String]) async {
        guard let token = try? await accessToken(credential) else { return }
        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent("client/dictate/prepare"),
            timeoutInterval: Self.seconds(Self.prepareTimeout)
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.json(["client": ["session_id": session], "context": context])
        _ = try? await send(request, within: Self.prepareTimeout, timeout: .timeout, network: .network)
    }

    /// One dictation. A 401 drops the cached token and retries once with a fresh one when a
    /// token fetch plus `retryMinimum` still fit in the wait; nothing else is retried.
    func dictate(
        _ credential: ForkDroplineCredential,
        audio: Data,
        session: String,
        context: [String: String]
    ) async throws -> ForkDroplineAnswer {
        let started = clock.now()
        var token = try await accessToken(credential)
        for attempt in 0..<2 {
            let left = Self.dictateTimeout - .seconds(clock.now().timeIntervalSince(started))
            if attempt > 0, left < Self.retryMinimum { break }
            let boundary = "hex-dropline-\(UUID().uuidString)"
            var request = URLRequest(
                url: Self.baseURL.appendingPathComponent("client/dictate"),
                timeoutInterval: Self.seconds(left)
            )
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(boundary: boundary, session: session, context: context, audio: audio)
            let (data, response) = try await send(request, within: left, timeout: .timeout, network: .network)
            if (200..<300).contains(response.statusCode) {
                return try Self.answer(data)
            }
            guard response.statusCode == 401 else { throw ForkDroplineFailure.http(status: response.statusCode) }
            guard attempt == 0 else { break }
            let remaining = Self.dictateTimeout - .seconds(clock.now().timeIntervalSince(started))
            guard remaining >= Self.tokenTimeout + Self.retryMinimum else { break }
            await tokens.invalidate()
            token = try await accessToken(credential)
        }
        throw ForkDroplineFailure.unauthorized
    }

    /// `request` (JSON), `context` (JSON, left out when empty) and `audio`, in that order.
    static func multipart(boundary: String, session: String, context: [String: String], audio: Data) -> Data {
        var body = Data()
        func part(_ name: String, filename: String? = nil, type: String, _ content: Data) {
            let disposition = "form-data; name=\"\(name)\"" + (filename.map { "; filename=\"\($0)\"" } ?? "")
            body.append(Data("--\(boundary)\r\nContent-Disposition: \(disposition)\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        let request: [String: Any] = ["mode": "dictate", "language": "auto", "client": ["session_id": session]]
        part("request", type: "application/json", json(request))
        if !context.isEmpty {
            part("context", type: "application/json", json(context))
        }
        part("audio", filename: "recording.ogg", type: "audio/ogg", audio)
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// What helps Dropline spell this dictation: the vocabulary's recognition hints.
    static func context(hints: [String]) -> [String: String] {
        let words = hints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return words.isEmpty ? [:] : ["text": words.joined(separator: ", ")]
    }

    private static func answer(_ data: Data) throws -> ForkDroplineAnswer {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = body["final_text"] as? String else {
            throw ForkDroplineFailure.invalidResponse
        }
        let language = (body["transcript"] as? [String: Any])?["language"] as? String
        return ForkDroplineAnswer(text: traditionalChinese(text), language: language)
    }

    private static func traditionalChinese(_ text: String) -> String {
        let forms = #/[恐恫威惊驚]吓|吓(?:[了我你]?一跳|[唬坏壞傻哭跑退死醒怕]|人[。！？，、.!?\s]|人$)|(吓|了解|明了|斗笠|[烟煙]斗|启|钵|钩)/#
        func convert(_ part: Substring) -> String {
            let string = String(part)
            guard !part.utf8.allSatisfy({ $0 < 128 }) else { return string }
            return string.applyingTransform(StringTransform("[[:Han:]] Hans-Hant"), reverse: false) ?? string
        }
        var output = ""
        var start = text.startIndex
        for match in text.matches(of: forms) {
            guard let form = match.1 else { continue }
            output += convert(text[start..<form.startIndex])
            switch form {
            case "启": output += "啟"
            case "钵": output += "缽"
            case "钩": output += "鉤"
            case "烟斗": output += "煙斗"
            default: output += form
            }
            start = form.endIndex
        }
        return output + convert(text[start...])
    }

    /// Sends within `limit`: URLRequest's own timeout is an idle timeout, not a deadline.
    private func send(
        _ request: URLRequest,
        within limit: Duration,
        timeout: ForkDroplineFailure,
        network: ForkDroplineFailure
    ) async throws -> (Data, HTTPURLResponse) {
        let http = self.http
        let clock = self.clock
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                do {
                    return try await http.send(request)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if (error as? URLError)?.code == .timedOut { throw timeout }
                    throw network
                }
            }
            group.addTask {
                try await clock.sleep(for: limit)
                throw timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw network }
            return result
        }
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return max(0.1, Double(seconds) + Double(attoseconds) / 1e18)
    }
}
