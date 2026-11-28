import SwiftUI

/// In the Labs card while SenseVoice is on: the newest dictations SenseVoice decided on
/// (`ForkSenseVoice.Record`'s `transcribed` and `fallback`), newest first, each with its time, the
/// app or the keyboard, and SenseVoice or Apple with why. Read as the card appears and as Hex
/// comes back to the foreground. A log over `byteLimit` or one that doesn't decode reads as none;
/// the next dictation writes it anew (`Record.append`).
struct ForkSenseVoiceRecentDictations: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [Row] = []

    static let limit = 10
    /// 50 records are about 10 KB.
    static let byteLimit = 64 * 1024

    struct Row: Equatable, Identifiable {
        let id: Int
        let time: String
        let process: String
        let engine: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Recent dictations")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HexTheme.textMuted)

            if rows.isEmpty {
                Text(verbatim: "No dictations yet")
                    .foregroundStyle(HexTheme.textMuted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(verbatim: row.time)
                                .monospacedDigit()
                                .foregroundStyle(HexTheme.textMuted)
                                .accessibilityLabel(Text(verbatim: "\(row.time), \(row.process), \(row.engine)"))
                            Text(verbatim: row.process)
                                .accessibilityHidden(true)
                            Text(verbatim: row.engine)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(HexTheme.textBase)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fork-sensevoice-recent")
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        rows = Self.rows(Self.read(ForkSenseVoice.Record.url), now: .now)
    }

    /// The log's bytes, or nil when there is none or it is over `byteLimit`.
    static func read(_ url: URL?) -> Data? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit + 1), data.count <= byteLimit else { return nil }
        return data
    }

    /// The newest `limit` dictations in `data`: HH:mm today, with the date before today.
    static func rows(_ data: Data?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [Row] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data, let records = try? decoder.decode([ForkSenseVoice.Record].self, from: data) else { return [] }
        let time = formatter("HHmm", calendar: calendar, locale: locale)
        let date = formatter("MMMd", calendar: calendar, locale: locale)
        return records
            .filter { $0.event == "transcribed" || $0.event == "fallback" }
            .sorted { $0.at > $1.at }
            .prefix(limit)
            .enumerated()
            .map { index, record in
                Row(
                    id: index,
                    time: calendar.isDate(record.at, inSameDayAs: now)
                        ? time.string(from: record.at)
                        : "\(date.string(from: record.at)) \(time.string(from: record.at))",
                    process: record.process == "keyboard" ? "Keyboard" : "App",
                    engine: engine(record)
                )
            }
    }

    /// SenseVoice, or Apple with the fallback's reason (`ForkSenseVoice.fallbackReason`, `textReason`).
    static func engine(_ record: ForkSenseVoice.Record) -> String {
        guard record.event == "fallback" else { return "SenseVoice" }
        let reason: String? = switch record.detail.prefix(while: { $0 != " " }) {
        case "memory": "Not enough memory"
        case "loading": "Model loading"
        case "not-loaded": "Model not loaded"
        case "load-failed": "Load failed"
        case "too-long": "Recording too long"
        case "english": "Heard as English"
        case "sparse": "Too few words"
        case "empty": "No words heard"
        case "error": "Error"
        default: nil
        }
        return reason.map { "Apple · \($0)" } ?? "Apple"
    }

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
