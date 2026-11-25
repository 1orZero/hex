// The fork's screen text (FORK.md, "Screen text"): the front window's text
// lines, read with Vision while a dictation records, for its transformations.
// Rust calls these on its own threads; nothing here asks for a permission.
import AppKit
import ScreenCaptureKit
import Vision

/// Longest captured side in pixels; bounds OCR time on large displays.
private let maximumCaptureDimension: CGFloat = 2800
/// How long ScreenCaptureKit may take to list the windows or capture one.
private let captureTimeout: DispatchTimeInterval = .seconds(5)

private enum Status: Int32 {
    case done = 0
    case windowGone = 1
    case captureFailed = 2
    case recognitionFailed = 3
    case stopped = 4
}

private final class Outcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func take() -> Value? {
        lock.withLock { value }
    }
}

/// `operation`'s value, or nil when it threw or outlasted `captureTimeout`.
private func blocking<Value>(_ operation: @escaping @Sendable () async throws -> Value) -> Value? {
    let semaphore = DispatchSemaphore(value: 0)
    let outcome = Outcome<Value>()
    let task = Task.detached {
        if let value = try? await operation() {
            outcome.store(value)
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + captureTimeout) == .success else {
        task.cancel()
        return nil
    }
    return outcome.take()
}

/// Hex itself, any other Hex build, and this process never count as the
/// window being dictated into.
private func excludedProcesses() -> Set<pid_t> {
    let hex = NSWorkspace.shared.runningApplications.filter { application in
        guard let id = application.bundleIdentifier else { return false }
        return id == "anomaly.hex" || id.hasPrefix("anomaly.hex.")
    }
    return Set(hex.map(\.processIdentifier)).union([ProcessInfo.processInfo.processIdentifier])
}

/// Lines in reading order. English only and without language correction:
/// correction would respell identifiers such as RecordingContextCapture.
private func recognizeLines(in image: CGImage) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    // Vision uses a bottom-left origin. Rows go top to bottom, each left to right; a line joins the row above when
    // their centers are closer than half the shorter line's height, so a row of words with and without
    // descenders stays one row.
    var rows: [[VNRecognizedTextObservation]] = []
    for observation in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
        if let first = rows.last?.first,
           abs(first.boundingBox.midY - observation.boundingBox.midY)
               < min(first.boundingBox.height, observation.boundingBox.height) / 2 {
            rows[rows.count - 1].append(observation)
        } else {
            rows.append([observation])
        }
    }
    return rows
        .flatMap { row in row.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        .compactMap { $0.topCandidates(1).first?.string }
        .map { $0.replacingOccurrences(of: "\n", with: " ") }
}

private func joined(_ lines: [String]) -> UnsafeMutablePointer<CChar>? {
    strdup(lines.joined(separator: "\n"))
}

@_cdecl("hex_fork_screen_text_permitted")
public func hexForkScreenTextPermitted() -> Bool {
    CGPreflightScreenCaptureAccess()
}

/// The frontmost normal window (layer 0, wider and taller than 50 points)
/// that no Hex build owns, or 0. CGWindowList is ordered front to back.
@_cdecl("hex_fork_screen_text_front_window")
public func hexForkScreenTextFrontWindow() -> UInt32 {
    let excluded = excludedProcesses()
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return 0 }
    for window in windows {
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              let pid = window[kCGWindowOwnerPID as String] as? pid_t, !excluded.contains(pid),
              let id = window[kCGWindowNumber as String] as? CGWindowID,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              (bounds["Width"] ?? 0) > 50, (bounds["Height"] ?? 0) > 50
        else { continue }
        return id
    }
    return 0
}

/// Window `id`'s text lines, one per line, or nil with `status` saying why.
/// Only that window is captured, without the cursor; when it is gone,
/// nothing else is. `stopped(context)` is checked between the steps.
@_cdecl("hex_fork_screen_text_read_window")
public func hexForkScreenTextReadWindow(
    _ id: UInt32,
    _ stopped: @convention(c) (UnsafeRawPointer?) -> Bool,
    _ context: UnsafeRawPointer?,
    _ status: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<CChar>? {
    func fail(_ reason: Status) -> UnsafeMutablePointer<CChar>? {
        status.pointee = reason.rawValue
        return nil
    }
    guard let content = blocking({
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }) else { return fail(.captureFailed) }
    guard let window = content.windows.first(where: { $0.windowID == id }) else { return fail(.windowGone) }
    if stopped(context) { return fail(.stopped) }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    let scale = min(
        CGFloat(filter.pointPixelScale),
        maximumCaptureDimension / max(window.frame.width, window.frame.height, 1)
    )
    configuration.width = max(1, Int(window.frame.width * scale))
    configuration.height = max(1, Int(window.frame.height * scale))
    configuration.showsCursor = false
    guard let image = blocking({
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }) else { return fail(.captureFailed) }
    if stopped(context) { return fail(.stopped) }
    guard let lines = try? recognizeLines(in: image) else { return fail(.recognitionFailed) }
    status.pointee = Status.done.rawValue
    return joined(lines)
}

/// The text lines of the image at `path`, read as a window's are.
@_cdecl("hex_fork_screen_text_read_image")
public func hexForkScreenTextReadImage(
    _ path: UnsafePointer<CChar>,
    _ status: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<CChar>? {
    let url = URL(fileURLWithPath: String(cString: path))
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let lines = try? recognizeLines(in: image)
    else {
        status.pointee = Status.recognitionFailed.rawValue
        return nil
    }
    status.pointee = Status.done.rawValue
    return joined(lines)
}

/// Vision loads its text model on the first request, which took 43 s after
/// a restart; a blank image loads it now.
@_cdecl("hex_fork_screen_text_prewarm")
public func hexForkScreenTextPrewarm() {
    guard let blank = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )?.makeImage() else { return }
    _ = try? recognizeLines(in: blank)
}

@_cdecl("hex_fork_screen_text_free")
public func hexForkScreenTextFree(_ text: UnsafeMutablePointer<CChar>?) {
    free(text)
}
