//! The HTTP side of Dropline's private API: the access token from the token
//! endpoint, `/client/dictate/prepare`, and `/client/dictate`, as Derek
//! Voice sends them, plus a meeting segment's retries and the Worker's
//! memory clear.

use std::fmt;
use std::time::{Duration, Instant, SystemTime};

use serde_json::json;

const DROPLINE: &str = "https://api.dropline.fish.audio";
const TOKEN_TIMEOUT: Duration = Duration::from_secs(5);
const PREPARE_TIMEOUT: Duration = Duration::from_secs(3);
/// A 401's one retry runs only when a token refetch plus this much more still
/// fits in the wait.
const RETRY_MINIMUM: Duration = Duration::from_secs(3);
/// Tokens are used until this long before they expire.
const TOKEN_MARGIN_MS: u64 = 5 * 60 * 1000;
const MAX_RESPONSE_BYTES: u64 = 1 << 20;
/// One meeting segment request, however long it runs.
const SEGMENT_TIMEOUT: Duration = Duration::from_secs(60);
/// A 429 without `Retry-After` waits this long; with one, at most `MAX_RATE_WAIT`.
const RATE_WAIT: Duration = Duration::from_secs(5);
const MAX_RATE_WAIT: Duration = Duration::from_secs(60);
/// 429s a segment waits out before it fails; they are not sends.
const MAX_RATE_LIMITS: usize = 10;
/// Sends of one segment through 502–504, network errors, and timeouts.
const MAX_SENDS: usize = 2;
const CLEAR_TIMEOUT: Duration = Duration::from_secs(10);

/// Why Dropline gave no text, as General and the picker show it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Failure {
    NotConfigured,
    Keychain(String),
    TooLong,
    Encoding(String),
    Token(String),
    Network(String),
    Timeout,
    Unauthorized,
    Http(u16),
    InvalidResponse,
    /// The token endpoint refused the bearer (401, 403) or Dropline isn't
    /// connected (404).
    TokenRejected(u16),
    /// The meeting stopped or Hex is quitting.
    Cancelled,
}

impl Failure {
    /// The Worker or Dropline refused this Hex: a meeting sends nothing more.
    pub fn is_authorization(&self) -> bool {
        matches!(
            self,
            Self::NotConfigured | Self::Keychain(_) | Self::TokenRejected(_) | Self::Unauthorized
        )
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotConfigured => write!(f, "沒有設定 Dropline 私人 API"),
            Self::Keychain(detail) => write!(f, "讀不到鑰匙圈的 token：{detail}"),
            Self::TooLong => write!(f, "錄音超過 178 秒"),
            Self::Encoding(detail) => write!(f, "錄音編碼失敗：{detail}"),
            Self::Token(detail) => write!(f, "Token 端點失敗：{detail}"),
            Self::Network(detail) => write!(f, "網路錯誤：{detail}"),
            Self::Timeout => write!(f, "Dropline 逾時"),
            Self::Unauthorized => write!(f, "Dropline 授權失敗（401）"),
            Self::Http(status) => write!(f, "Dropline 回應 HTTP {status}"),
            Self::InvalidResponse => write!(f, "Dropline 的回應格式不對"),
            Self::TokenRejected(404) => write!(f, "Token 端點失敗：HTTP 404（Dropline 沒有連線）"),
            Self::TokenRejected(status) => write!(f, "Token 端點失敗：HTTP {status}"),
            Self::Cancelled => write!(f, "已取消"),
        }
    }
}

/// The dictation's context; empty fields are left out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Context {
    pub text: String,
}

impl Context {
    fn json(&self) -> serde_json::Value {
        if self.text.is_empty() {
            json!({})
        } else {
            json!({ "text": self.text })
        }
    }
}

pub(super) struct AccessToken {
    pub value: String,
    pub expires_at_ms: u64,
}

/// The access token, kept until five minutes before it expires.
pub(super) struct TokenCache {
    cached: Option<AccessToken>,
}

impl TokenCache {
    pub const fn new() -> Self {
        Self { cached: None }
    }

    pub fn current(&self, now_ms: u64) -> Option<String> {
        self.cached
            .as_ref()
            .filter(|token| token.expires_at_ms.saturating_sub(TOKEN_MARGIN_MS) > now_ms)
            .map(|token| token.value.clone())
    }

    pub fn store(&mut self, token: AccessToken) {
        self.cached = Some(token);
    }

    pub fn invalidate(&mut self) {
        self.cached = None;
    }
}

impl Default for TokenCache {
    fn default() -> Self {
        Self::new()
    }
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub(super) struct Request<'a> {
    pub method: &'static str,
    pub url: &'a str,
    pub bearer: &'a str,
    pub content_type: Option<&'a str>,
    pub body: Vec<u8>,
    pub timeout: Duration,
}

pub(super) struct Response {
    pub status: u16,
    pub body: Vec<u8>,
    /// `Retry-After` in seconds, when the server sent one.
    pub retry_after: Option<Duration>,
}

/// One HTTP exchange; tests answer with their own.
pub(super) trait Transport {
    fn send(&self, request: Request<'_>) -> Result<Response, Failure>;
}

/// Hex's own HTTPS (`net`): the platform's TLS and the computer's proxy.
pub(super) struct Http;

impl Transport for Http {
    fn send(&self, request: Request<'_>) -> Result<Response, Failure> {
        let timeout = request.timeout;
        let agent = crate::net::agent(request.url, |config| {
            config
                .http_status_as_error(false)
                .timeout_global(Some(timeout))
        });
        let mut builder = ureq::http::Request::builder()
            .method(request.method)
            .uri(request.url)
            .header("Authorization", format!("Bearer {}", request.bearer));
        if let Some(content_type) = request.content_type {
            builder = builder.header("Content-Type", content_type);
        }
        let invalid = |_| Failure::Network("無效的請求".into());
        let response = if request.method == "GET" {
            agent.run(builder.body(()).map_err(invalid)?)
        } else {
            agent.run(builder.body(request.body).map_err(invalid)?)
        };
        let failed = |error: ureq::Error| match error {
            ureq::Error::Timeout(_) => Failure::Timeout,
            error => Failure::Network(crate::net::reason(&error)),
        };
        let mut response = response.map_err(failed)?;
        let status = response.status().as_u16();
        let retry_after = response
            .headers()
            .get("retry-after")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.trim().parse::<u64>().ok())
            .map(Duration::from_secs);
        let body = response
            .body_mut()
            .with_config()
            .limit(MAX_RESPONSE_BYTES)
            .read_to_vec()
            .map_err(failed)?;
        Ok(Response {
            status,
            body,
            retry_after,
        })
    }
}

/// `GET <endpoint>` with the bearer: `{access_token, expires_at}`, the
/// expiry in epoch milliseconds.
pub(super) fn fetch_token(
    transport: &dyn Transport,
    endpoint: &str,
    bearer: &str,
) -> Result<AccessToken, Failure> {
    request_token(transport, endpoint, bearer).map_err(|failure| match failure {
        Failure::TokenRejected(404) => Failure::Token("HTTP 404（Dropline 沒有連線）".into()),
        Failure::TokenRejected(status) => Failure::Token(format!("HTTP {status}")),
        failure => failure,
    })
}

/// [`fetch_token`], telling a refused bearer apart.
pub(super) fn request_token(
    transport: &dyn Transport,
    endpoint: &str,
    bearer: &str,
) -> Result<AccessToken, Failure> {
    let response = transport
        .send(Request {
            method: "GET",
            url: endpoint,
            bearer,
            content_type: None,
            body: Vec::new(),
            timeout: TOKEN_TIMEOUT,
        })
        .map_err(|failure| match failure {
            Failure::Timeout => Failure::Token("逾時".into()),
            Failure::Network(detail) => Failure::Token(detail),
            failure => failure,
        })?;
    match response.status {
        200 => {}
        status @ (401 | 403 | 404) => return Err(Failure::TokenRejected(status)),
        status => return Err(Failure::Token(format!("HTTP {status}"))),
    }
    let body: serde_json::Value = serde_json::from_slice(&response.body)
        .map_err(|_| Failure::Token("回應不是 JSON".into()))?;
    let value = body["access_token"]
        .as_str()
        .filter(|token| !token.is_empty());
    let expires_at_ms = body["expires_at"]
        .as_f64()
        .filter(|ms| ms.is_finite() && *ms > 0.0);
    match (value, expires_at_ms) {
        (Some(value), Some(expires_at_ms)) => Ok(AccessToken {
            value: value.to_owned(),
            expires_at_ms: expires_at_ms as u64,
        }),
        _ => Err(Failure::Token("回應缺少 access_token 或 expires_at".into())),
    }
}

/// `POST /client/dictate/prepare`: the session's context ahead of its
/// audio. Its outcome changes nothing; the status is for the log.
pub(super) fn prepare(
    transport: &dyn Transport,
    token: &str,
    session: &str,
    context: &Context,
) -> String {
    let body = json!({ "client": { "session_id": session }, "context": context.json() });
    let url = format!("{DROPLINE}/client/dictate/prepare");
    match transport.send(Request {
        method: "POST",
        url: &url,
        bearer: token,
        content_type: Some("application/json"),
        body: body.to_string().into_bytes(),
        timeout: PREPARE_TIMEOUT,
    }) {
        Ok(response) if (200..300).contains(&response.status) => "ok".into(),
        Ok(response) => format!("http_{}", response.status),
        Err(Failure::Timeout) => "timeout".into(),
        Err(_) => "error".into(),
    }
}

/// `POST /client/dictate` once, and once more with a new token after a 401
/// while enough of the wait is left. `token(true)` drops the cached token.
pub(super) fn dictate(
    transport: &dyn Transport,
    token: &mut dyn FnMut(bool) -> Result<String, Failure>,
    audio: &[u8],
    session: &str,
    context: &Context,
    deadline: Instant,
) -> Result<String, Failure> {
    let url = format!("{DROPLINE}/client/dictate");
    let boundary = format!("hex-dropline-{session}");
    let body = multipart(&boundary, session, context, audio);
    let content_type = format!("multipart/form-data; boundary={boundary}");
    let mut access = token(false)?;
    for attempt in 0..2 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(Failure::Timeout);
        }
        let response = transport.send(Request {
            method: "POST",
            url: &url,
            bearer: &access,
            content_type: Some(&content_type),
            body: body.clone(),
            timeout: left,
        })?;
        match response.status {
            200..=299 => return final_text(&response.body),
            401 if attempt == 0 => {
                if deadline.saturating_duration_since(Instant::now())
                    < TOKEN_TIMEOUT + RETRY_MINIMUM
                {
                    return Err(Failure::Unauthorized);
                }
                access = token(true)?;
            }
            401 => return Err(Failure::Unauthorized),
            status => return Err(Failure::Http(status)),
        }
    }
    Err(Failure::Unauthorized)
}

/// `final_text`: what to insert; empty when Dropline heard no speech.
fn final_text(body: &[u8]) -> Result<String, Failure> {
    let body: serde_json::Value =
        serde_json::from_slice(body).map_err(|_| Failure::InvalidResponse)?;
    body["final_text"]
        .as_str()
        .map(super::text::traditional)
        .ok_or(Failure::InvalidResponse)
}

/// `POST /client/dictate` for one meeting segment: up to 60 s a request; a
/// 429 waits out `Retry-After` (5 s without one, at most 60 s, at most 10
/// times) and is not a send; 502–504, network errors, and timeouts send at
/// most twice; a 401 fetches a new token once. `proceed` runs before each
/// request and `wait` sleeps a 429 out; either returns false when the
/// meeting stopped.
#[allow(clippy::too_many_arguments)]
pub(super) fn transcribe_segment(
    transport: &dyn Transport,
    token: &mut dyn FnMut(bool) -> Result<String, Failure>,
    audio: &[u8],
    session: &str,
    context: &Context,
    proceed: &mut dyn FnMut() -> bool,
    wait: &dyn Fn(Duration) -> bool,
) -> Result<String, Failure> {
    let url = format!("{DROPLINE}/client/dictate");
    let boundary = format!("hex-dropline-{session}");
    let body = multipart(&boundary, session, context, audio);
    let content_type = format!("multipart/form-data; boundary={boundary}");
    let mut access = token(false)?;
    let mut sends = 0;
    let mut limits = 0;
    let mut refreshed = false;
    loop {
        if !proceed() {
            return Err(Failure::Cancelled);
        }
        sends += 1;
        let response = transport.send(Request {
            method: "POST",
            url: &url,
            bearer: &access,
            content_type: Some(&content_type),
            body: body.clone(),
            timeout: SEGMENT_TIMEOUT,
        });
        let failure = match response {
            Ok(response) => match response.status {
                200..=299 => return segment_text(&response.body),
                429 => {
                    sends -= 1;
                    limits += 1;
                    if limits > MAX_RATE_LIMITS {
                        return Err(Failure::Http(429));
                    }
                    let pause = response.retry_after.unwrap_or(RATE_WAIT).min(MAX_RATE_WAIT);
                    if !wait(pause) {
                        return Err(Failure::Cancelled);
                    }
                    continue;
                }
                401 if !refreshed => {
                    sends -= 1;
                    refreshed = true;
                    access = token(true)?;
                    continue;
                }
                401 => return Err(Failure::Unauthorized),
                status @ 502..=504 => Failure::Http(status),
                status => return Err(Failure::Http(status)),
            },
            Err(failure @ (Failure::Network(_) | Failure::Timeout)) => failure,
            Err(failure) => return Err(failure),
        };
        if sends >= MAX_SENDS {
            return Err(failure);
        }
    }
}

/// A meeting segment's words as heard: `transcript.text`, else `final_text`
/// (Derek Voice's order).
fn segment_text(body: &[u8]) -> Result<String, Failure> {
    let body: serde_json::Value =
        serde_json::from_slice(body).map_err(|_| Failure::InvalidResponse)?;
    body["transcript"]["text"]
        .as_str()
        .or_else(|| body["final_text"].as_str())
        .map(super::text::traditional)
        .ok_or(Failure::InvalidResponse)
}

/// What the Worker said to a memory clear.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Cleared {
    Yes,
    /// `200 {cleared: false}`: Derek Voice's scheduled clearing is off.
    No,
    Failed(String),
}

/// The Worker's memory clear beside the token endpoint, or `None` when the
/// endpoint doesn't end in `/dropline-private/token`.
pub(super) fn memory_clear_url(endpoint: &str) -> Option<String> {
    let mut url = url::Url::parse(endpoint).ok()?;
    let path = url
        .path()
        .strip_suffix("/dropline-private/token")?
        .to_owned();
    url.set_path(&format!("{path}/dropline-private/memory/clear"));
    url.set_query(None);
    Some(url.into())
}

/// `POST <url>` with the Worker bearer. Only the outcome is kept, never the
/// answer's other content.
pub(super) fn clear_memory(transport: &dyn Transport, url: &str, bearer: &str) -> Cleared {
    let response = transport.send(Request {
        method: "POST",
        url,
        bearer,
        content_type: Some("application/json"),
        body: b"{}".to_vec(),
        timeout: CLEAR_TIMEOUT,
    });
    match response {
        Ok(response) if response.status == 200 => {
            match serde_json::from_slice::<serde_json::Value>(&response.body)
                .ok()
                .and_then(|body| body["cleared"].as_bool())
            {
                Some(true) => Cleared::Yes,
                Some(false) => Cleared::No,
                None => Cleared::Failed("回應格式不對".into()),
            }
        }
        Ok(response) => Cleared::Failed(format!("HTTP {}", response.status)),
        Err(failure) => Cleared::Failed(failure.to_string()),
    }
}

/// `request` (JSON), `context` (JSON, left out when empty), and `audio`,
/// in that order (Dropline's documentation).
pub(super) fn multipart(boundary: &str, session: &str, context: &Context, audio: &[u8]) -> Vec<u8> {
    let request = json!({
        "mode": "dictate",
        "language": "auto",
        "client": { "session_id": session },
    });
    let mut body = Vec::with_capacity(audio.len() + 1024);
    let mut part = |name: &str, filename: Option<&str>, content_type: &str, content: &[u8]| {
        let filename = filename
            .map(|file| format!("; filename=\"{file}\""))
            .unwrap_or_default();
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"{filename}\r\nContent-Type: {content_type}\r\n\r\n"
            )
            .as_bytes(),
        );
        body.extend_from_slice(content);
        body.extend_from_slice(b"\r\n");
    };
    part(
        "request",
        None,
        "application/json",
        request.to_string().as_bytes(),
    );
    if !context.text.is_empty() {
        part(
            "context",
            None,
            "application/json",
            context.json().to_string().as_bytes(),
        );
    }
    part("audio", Some("recording.ogg"), "audio/ogg", audio);
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    body
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::VecDeque;

    use super::*;

    /// Answers each request with the next scripted response and keeps what
    /// was sent.
    #[derive(Default)]
    struct Script {
        answers: RefCell<VecDeque<Result<Response, Failure>>>,
        sent: RefCell<Vec<(String, String, String)>>,
    }

    impl Script {
        fn answer(self, status: u16, body: &str) -> Self {
            self.answers.borrow_mut().push_back(Ok(Response {
                status,
                body: body.as_bytes().to_vec(),
                retry_after: None,
            }));
            self
        }

        fn fail(self, failure: Failure) -> Self {
            self.answers.borrow_mut().push_back(Err(failure));
            self
        }

        fn limited(self, retry_after: Option<u64>) -> Self {
            self.answers.borrow_mut().push_back(Ok(Response {
                status: 429,
                body: b"{}".to_vec(),
                retry_after: retry_after.map(Duration::from_secs),
            }));
            self
        }
    }

    impl Transport for Script {
        fn send(&self, request: Request<'_>) -> Result<Response, Failure> {
            self.sent.borrow_mut().push((
                request.method.to_owned(),
                request.url.to_owned(),
                request.bearer.to_owned(),
            ));
            self.answers
                .borrow_mut()
                .pop_front()
                .expect("an unscripted request")
        }
    }

    const ENDPOINT: &str = "https://qa-worker.example/v1/dropline-private/token";

    #[test]
    fn a_token_is_read_with_its_expiry() {
        let script = Script::default().answer(
            200,
            r#"{"access_token":"qa-access","expires_at":1800000000000}"#,
        );
        let token = fetch_token(&script, ENDPOINT, "qa-bearer").unwrap();
        assert_eq!(token.value, "qa-access");
        assert_eq!(token.expires_at_ms, 1_800_000_000_000);
        assert_eq!(
            script.sent.borrow()[0],
            ("GET".into(), ENDPOINT.into(), "qa-bearer".into())
        );
    }

    #[test]
    fn a_token_endpoint_that_refuses_or_answers_badly_fails() {
        for (status, body) in [
            (401, "{}"),
            (404, r#"{"error":"not_connected"}"#),
            (200, "not json"),
            (200, r#"{"access_token":"","expires_at":1}"#),
            (200, r#"{"access_token":"qa-access"}"#),
        ] {
            let script = Script::default().answer(status, body);
            assert!(matches!(
                fetch_token(&script, ENDPOINT, "qa-bearer"),
                Err(Failure::Token(_))
            ));
        }
        let script = Script::default().fail(Failure::Timeout);
        assert_eq!(
            fetch_token(&script, ENDPOINT, "qa-bearer").err(),
            Some(Failure::Token("逾時".into()))
        );
    }

    #[test]
    fn the_cache_keeps_a_token_until_five_minutes_before_it_expires() {
        let mut cache = TokenCache::new();
        assert_eq!(cache.current(0), None);
        cache.store(AccessToken {
            value: "qa-access".into(),
            expires_at_ms: 1_000_000,
        });
        assert_eq!(
            cache.current(1_000_000 - TOKEN_MARGIN_MS - 1).as_deref(),
            Some("qa-access")
        );
        assert_eq!(cache.current(1_000_000 - TOKEN_MARGIN_MS), None);
        assert_eq!(cache.current(2_000_000), None);
        cache.invalidate();
        assert_eq!(cache.current(0), None);
    }

    fn later() -> Instant {
        Instant::now() + Duration::from_secs(10)
    }

    #[test]
    fn a_401_fetches_a_new_token_and_sends_once_more() {
        let script = Script::default()
            .answer(401, "{}")
            .answer(200, r#"{"final_text":"qa 你好"}"#);
        let mut asked = Vec::new();
        let mut token = |fresh: bool| {
            asked.push(fresh);
            Ok(if fresh { "qa-new" } else { "qa-old" }.to_owned())
        };
        let text = dictate(
            &script,
            &mut token,
            b"OggS",
            "qa-session",
            &Context::default(),
            later(),
        );
        assert_eq!(text.as_deref(), Ok("qa 你好"));
        assert_eq!(asked, [false, true]);
        let sent = script.sent.borrow();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0].1, "https://api.dropline.fish.audio/client/dictate");
        assert_eq!(sent[0].2, "qa-old");
        assert_eq!(sent[1].2, "qa-new");
    }

    #[test]
    fn a_second_401_or_another_status_fails() {
        let script = Script::default().answer(401, "{}").answer(401, "{}");
        let mut token = |_| Ok("qa-access".to_owned());
        assert_eq!(
            dictate(
                &script,
                &mut token,
                b"OggS",
                "qa",
                &Context::default(),
                later()
            ),
            Err(Failure::Unauthorized)
        );
        for status in [500, 503, 429] {
            let script = Script::default().answer(status, "{}");
            assert_eq!(
                dictate(
                    &script,
                    &mut token,
                    b"OggS",
                    "qa",
                    &Context::default(),
                    later()
                ),
                Err(Failure::Http(status))
            );
            assert_eq!(script.sent.borrow().len(), 1);
        }
    }

    #[test]
    fn a_401_without_time_for_a_retry_fails() {
        let script = Script::default().answer(401, "{}");
        let mut token = |_| Ok("qa-access".to_owned());
        let soon = Instant::now() + Duration::from_secs(2);
        assert_eq!(
            dictate(
                &script,
                &mut token,
                b"OggS",
                "qa",
                &Context::default(),
                soon
            ),
            Err(Failure::Unauthorized)
        );
        assert_eq!(script.sent.borrow().len(), 1);
    }

    #[test]
    fn network_failures_timeouts_and_bad_answers_fail() {
        let mut token = |_| Ok("qa-access".to_owned());
        for (script, expected) in [
            (Script::default().fail(Failure::Timeout), Failure::Timeout),
            (
                Script::default().fail(Failure::Network("qa".into())),
                Failure::Network("qa".into()),
            ),
            (
                Script::default().answer(200, "{}"),
                Failure::InvalidResponse,
            ),
        ] {
            assert_eq!(
                dictate(
                    &script,
                    &mut token,
                    b"OggS",
                    "qa",
                    &Context::default(),
                    later()
                ),
                Err(expected)
            );
        }
        let mut refused = |_| Err(Failure::Token("HTTP 401".into()));
        let script = Script::default();
        assert_eq!(
            dictate(
                &script,
                &mut refused,
                b"OggS",
                "qa",
                &Context::default(),
                later()
            ),
            Err(Failure::Token("HTTP 401".into()))
        );
        assert!(script.sent.borrow().is_empty());
    }

    #[test]
    fn successful_dictation_converts_only_the_chinese_script() {
        for (input, expected) in [
            (
                "qa-请打开软件，读取里面的文件。",
                "qa-請打開軟件，讀取裡面的文件。",
            ),
            (
                "qa-啟用后再启动 API_v2(42)：头发與发展\n\t请睇吓。",
                "qa-啟用後再啟動 API_v2(42)：頭髮與發展\n\t請睇吓。",
            ),
            (
                "qa-佢哋喺度試吓，已經了解斗笠點用。",
                "qa-佢哋喺度試吓，已經了解斗笠點用。",
            ),
            (
                "qa- e\u{301} / API_v2(42) 💻\r\n\t",
                "qa- e\u{301} / API_v2(42) 💻\r\n\t",
            ),
            ("qa-吓了一跳，继续奋斗。", "qa-嚇了一跳，繼續奮鬥。"),
            ("qa-别干擾周杰倫的软件开发。", "qa-別干擾周杰倫的軟件開發。"),
            ("qa-他吓了我一跳，吓得发抖。", "qa-他嚇了我一跳，嚇得發抖。"),
            (
                "qa-睇吓人哋點講。吓？我哋試吓先。",
                "qa-睇吓人哋點講。吓？我哋試吓先。",
            ),
            (
                "qa-你幫我查吓呢個地址，我去洗吓手先。",
                "qa-你幫我查吓呢個地址，我去洗吓手先。",
            ),
            (
                "qa-他想吓唬你，别用吓人的手段吓我一跳。",
                "qa-他想嚇唬你，別用嚇人的手段嚇我一跳。",
            ),
            (
                "qa-請保持干燥，這里很好，會后再说。",
                "qa-請保持乾燥，這裡很好，會後再說。",
            ),
            (
                "qa-读取_v2 和 foo_变量，`读取-v2`：请开门。",
                "qa-读取_v2 和 foo_变量，`读取-v2`：請開門。",
            ),
            (
                "qa-不要吓我，他吓你了吗？吓呆了，吓晕。",
                "qa-不要嚇我，他嚇你了嗎？嚇呆了，嚇暈。",
            ),
            (
                "qa-请打开API_v2并读取 foo_读取_变量 和 变量_读取。",
                "qa-請打開API_v2並讀取 foo_读取_变量 和 变量_读取。",
            ),
            (
                "qa-我去問吓人，睇吓人。好吓人，别用吓人的手段。",
                "qa-我去問吓人，睇吓人。好嚇人，別用嚇人的手段。",
            ),
            ("qa-周杰倫的風采，別干擾他。", "qa-周杰倫的風采，別干擾他。"),
            (
                "qa-日本の国と学校、한국어、`读取_v2`：请开门。",
                "qa-日本の国と学校、한국어、`读取_v2`：請開門。",
            ),
            (
                "qa-启用铜钵和铁钩，保留原來的啓。",
                "qa-啟用銅缽和鐵鉤，保留原來的啓。",
            ),
        ] {
            let body = json!({"final_text": input, "transcript": {"language": "en"}});
            assert_eq!(
                final_text(&serde_json::to_vec(&body).unwrap()).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn an_empty_final_text_is_no_speech() {
        let script = Script::default().answer(200, r#"{"final_text":""}"#);
        let mut token = |_| Ok("qa-access".to_owned());
        assert_eq!(
            dictate(
                &script,
                &mut token,
                b"OggS",
                "qa",
                &Context::default(),
                later()
            )
            .as_deref(),
            Ok("")
        );
    }

    #[test]
    fn the_form_sends_request_context_and_audio_in_order() {
        let context = Context {
            text: "qa-Hex, Dropline".into(),
        };
        let body = multipart("qa-boundary", "qa-session", &context, b"OggS-audio");
        let body = String::from_utf8(body).unwrap();
        let request = body.find(r#"name="request""#).unwrap();
        let context_at = body.find(r#"name="context""#).unwrap();
        let audio = body
            .find(r#"name="audio"; filename="recording.ogg""#)
            .unwrap();
        assert!(request < context_at && context_at < audio);
        assert!(body.contains(r#""session_id":"qa-session""#));
        assert!(body.contains(r#""mode":"dictate""#));
        assert!(body.contains(r#""language":"auto""#));
        assert!(body.contains(r#"{"text":"qa-Hex, Dropline"}"#));
        assert!(body.contains("Content-Type: audio/ogg\r\n\r\nOggS-audio\r\n"));
        assert!(body.starts_with("--qa-boundary\r\n"));
        assert!(body.ends_with("--qa-boundary--\r\n"));
        let without = String::from_utf8(multipart("b", "s", &Context::default(), b"x")).unwrap();
        assert!(!without.contains(r#"name="context""#));
    }
    const SEGMENT_OK: &str =
        r#"{"final_text":"qa 你好。","transcript":{"text":"qa 嗯 你好","language":"zh"}}"#;

    /// Sends one meeting segment through `script`, recording each 429 wait.
    fn segment(script: &Script) -> (Result<String, Failure>, Vec<Duration>, Vec<bool>) {
        let waits = RefCell::new(Vec::new());
        let mut asked = Vec::new();
        let mut token = |fresh: bool| {
            asked.push(fresh);
            Ok(if fresh { "qa-new" } else { "qa-old" }.to_owned())
        };
        let result = transcribe_segment(
            script,
            &mut token,
            b"OggS",
            "qa-session",
            &Context::default(),
            &mut || true,
            &|pause| {
                waits.borrow_mut().push(pause);
                true
            },
        );
        (result, waits.into_inner(), asked)
    }

    #[test]
    fn a_meeting_segment_reads_the_verbatim_transcript_before_final_text() {
        let script = Script::default().answer(200, SEGMENT_OK);
        assert_eq!(segment(&script).0.as_deref(), Ok("qa 嗯 你好"));
        let script = Script::default().answer(
            200,
            r#"{"final_text":"qa 头发","transcript":{"text":null}}"#,
        );
        assert_eq!(segment(&script).0.as_deref(), Ok("qa 頭髮"));
        let script = Script::default().answer(200, r#"{"transcript":{}}"#);
        assert_eq!(segment(&script).0, Err(Failure::InvalidResponse));
        let sent = script.sent.borrow();
        assert_eq!(sent[0].1, "https://api.dropline.fish.audio/client/dictate");
    }

    #[test]
    fn dictation_still_inserts_final_text() {
        let script = Script::default().answer(200, SEGMENT_OK);
        let mut token = |_| Ok("qa-access".to_owned());
        assert_eq!(
            dictate(
                &script,
                &mut token,
                b"OggS",
                "qa",
                &Context::default(),
                later()
            )
            .as_deref(),
            Ok("qa 你好。")
        );
    }

    #[test]
    fn a_429_waits_for_retry_after_or_five_seconds_and_is_not_a_send() {
        let script = Script::default()
            .limited(Some(7))
            .limited(None)
            .limited(Some(600))
            .fail(Failure::Timeout)
            .answer(200, SEGMENT_OK);
        let (result, waits, _) = segment(&script);
        assert_eq!(result.as_deref(), Ok("qa 嗯 你好"));
        assert_eq!(
            waits,
            [
                Duration::from_secs(7),
                Duration::from_secs(5),
                Duration::from_secs(60)
            ]
        );
        assert_eq!(script.sent.borrow().len(), 5);
    }

    #[test]
    fn eleven_429s_fail_the_segment() {
        let mut script = Script::default();
        for _ in 0..=MAX_RATE_LIMITS {
            script = script.limited(Some(1));
        }
        let (result, waits, _) = segment(&script);
        assert_eq!(result, Err(Failure::Http(429)));
        assert_eq!(waits.len(), MAX_RATE_LIMITS);
        assert!(script.answers.borrow().is_empty());
    }

    #[test]
    fn gateway_errors_network_failures_and_timeouts_send_at_most_twice() {
        for first in [
            Err(Failure::Http(502)),
            Err(Failure::Http(503)),
            Err(Failure::Http(504)),
            Err(Failure::Network("qa".into())),
            Err(Failure::Timeout),
        ] {
            let push = |script: Script, outcome: &Result<(), Failure>| match outcome {
                Err(Failure::Http(status)) => script.answer(*status, "{}"),
                Err(failure) => script.fail(failure.clone()),
                Ok(()) => script,
            };
            let script = push(Script::default(), &first).answer(200, SEGMENT_OK);
            assert_eq!(segment(&script).0.as_deref(), Ok("qa 嗯 你好"));
            let script = push(push(Script::default(), &first), &first);
            assert_eq!(segment(&script).0, first.clone().map(|_| String::new()));
            assert_eq!(script.sent.borrow().len(), 2);
        }
    }

    #[test]
    fn other_statuses_and_bad_answers_are_not_resent() {
        for (status, expected) in [
            (400, Failure::Http(400)),
            (500, Failure::Http(500)),
            (413, Failure::Http(413)),
        ] {
            let script = Script::default().answer(status, "{}");
            assert_eq!(segment(&script).0, Err(expected));
            assert_eq!(script.sent.borrow().len(), 1);
        }
        let script = Script::default().answer(200, "not json");
        assert_eq!(segment(&script).0, Err(Failure::InvalidResponse));
        assert_eq!(script.sent.borrow().len(), 1);
    }

    #[test]
    fn a_401_refetches_the_token_once_for_a_segment() {
        let script = Script::default().answer(401, "{}").answer(200, SEGMENT_OK);
        let (result, _, asked) = segment(&script);
        assert_eq!(result.as_deref(), Ok("qa 嗯 你好"));
        assert_eq!(asked, [false, true]);
        assert_eq!(script.sent.borrow()[1].2, "qa-new");
        let script = Script::default().answer(401, "{}").answer(401, "{}");
        let (result, _, _) = segment(&script);
        assert_eq!(result, Err(Failure::Unauthorized));
        assert!(result.unwrap_err().is_authorization());
    }

    #[test]
    fn a_stopped_meeting_sends_nothing_more() {
        let script = Script::default().limited(Some(30));
        let mut token = |_| Ok("qa-access".to_owned());
        let result = transcribe_segment(
            &script,
            &mut token,
            b"OggS",
            "qa",
            &Context::default(),
            &mut || true,
            &|_| false,
        );
        assert_eq!(result, Err(Failure::Cancelled));
        let script = Script::default();
        let result = transcribe_segment(
            &script,
            &mut token,
            b"OggS",
            "qa",
            &Context::default(),
            &mut || false,
            &|_| true,
        );
        assert_eq!(result, Err(Failure::Cancelled));
        assert!(script.sent.borrow().is_empty());
    }

    #[test]
    fn a_refused_bearer_is_an_authorization_failure_but_dictation_reads_the_same() {
        for (status, shown) in [
            (401, "Token 端點失敗：HTTP 401"),
            (403, "Token 端點失敗：HTTP 403"),
            (404, "Token 端點失敗：HTTP 404（Dropline 沒有連線）"),
        ] {
            let script = Script::default().answer(status, "{}");
            let refused = request_token(&script, ENDPOINT, "qa-bearer").err().unwrap();
            assert_eq!(refused, Failure::TokenRejected(status));
            assert!(refused.is_authorization());
            assert_eq!(refused.to_string(), shown);
            let script = Script::default().answer(status, "{}");
            let dictation = fetch_token(&script, ENDPOINT, "qa-bearer").err().unwrap();
            assert!(matches!(dictation, Failure::Token(_)));
            assert_eq!(dictation.to_string(), shown);
        }
        let script = Script::default().answer(500, "{}");
        let failure = request_token(&script, ENDPOINT, "qa-bearer").err().unwrap();
        assert!(!failure.is_authorization());
        assert!(!Failure::Timeout.is_authorization());
    }

    #[test]
    fn the_memory_clear_sits_beside_the_token_endpoint() {
        assert_eq!(
            memory_clear_url(ENDPOINT).as_deref(),
            Some("https://qa-worker.example/v1/dropline-private/memory/clear")
        );
        assert_eq!(
            memory_clear_url("https://qa-worker.example/v1/dropline-private/token?x=1").as_deref(),
            Some("https://qa-worker.example/v1/dropline-private/memory/clear")
        );
        assert_eq!(memory_clear_url("https://qa-worker.example/v1/token"), None);
        assert_eq!(memory_clear_url("not a url"), None);
    }

    #[test]
    fn the_memory_clear_reads_cleared_and_keeps_only_the_outcome() {
        let url = "https://qa-worker.example/v1/dropline-private/memory/clear";
        for (status, body, expected) in [
            (200, r#"{"cleared":true}"#, Cleared::Yes),
            (
                200,
                r#"{"cleared":false,"reason":"qa-secret detail"}"#,
                Cleared::No,
            ),
            (200, r#"{}"#, Cleared::Failed("回應格式不對".into())),
            (
                403,
                r#"{"error":"qa-secret detail"}"#,
                Cleared::Failed("HTTP 403".into()),
            ),
            (429, "{}", Cleared::Failed("HTTP 429".into())),
        ] {
            let script = Script::default().answer(status, body);
            assert_eq!(clear_memory(&script, url, "qa-bearer"), expected);
            let sent = script.sent.borrow();
            assert_eq!(sent[0], ("POST".into(), url.into(), "qa-bearer".into()));
        }
        let script = Script::default().fail(Failure::Network("qa".into()));
        assert_eq!(
            clear_memory(&script, url, "qa-bearer"),
            Cleared::Failed("網路錯誤：qa".into())
        );
    }
}
