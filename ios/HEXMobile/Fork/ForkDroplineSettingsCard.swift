import SwiftUI

/// The fork's custom transcription provider, the Dropline private API, on Hex's main screen
/// after its settings card.
struct ForkDroplineSettingsCard: View {
    @State private var endpointHost: String?
    @State private var isEnabled = false
    @State private var fallback: ForkDroplineSettings.Fallback?
    @State private var isAdding = false
    @State private var endpointText = ForkDroplineSettings.defaultEndpoint
    @State private var bearerText = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let endpointHost {
                configured(host: endpointHost)
            } else if isAdding {
                form
            } else {
                HStack(spacing: 12) {
                    title("自訂辨識服務")
                    Spacer(minLength: 8)
                    Button {
                        isAdding = true
                    } label: {
                        Text(verbatim: "新增 Dropline 私人 API")
                            .font(.system(size: 15))
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
            }
        }
        .background(
            HexTheme.bgBase,
            in: RoundedRectangle(cornerRadius: HexTheme.cardRadius, style: .continuous)
        )
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func configured(host: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title(ForkDroplineSettings.providerName)
            Text(verbatim: host)
                .font(.system(size: 12))
                .foregroundStyle(HexTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 50)

        divider

        Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { value in
                    ForkDroplineSettings().isEnabled = value
                    isEnabled = value
                }
            )
        ) {
            title("使用 Dropline 辨識")
        }
        .tint(HexTheme.success)
        .padding(.horizontal, 16)
        .frame(minHeight: 48)

        if let fallback {
            divider

            Text(verbatim: "上次改用本機模型：\(fallback.reason)（\(Self.relative(fallback.at))）")
                .font(.system(size: 13))
                .foregroundStyle(HexTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }

        divider

        Button(role: .destructive) {
            Task {
                await ForkDroplineRecognition().remove()
                reload()
            }
        } label: {
            Text(verbatim: "刪除")
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(HexTheme.danger)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                title("Token 端點")
                TextField(text: $endpointText) {
                    Text(verbatim: ForkDroplineSettings.defaultEndpoint)
                }
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            }

            VStack(alignment: .leading, spacing: 6) {
                title("Bearer token")
                SecureField(text: $bearerText) {
                    Text(verbatim: "Bearer token")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            }

            if let error {
                Text(verbatim: error)
                    .font(.system(size: 13))
                    .foregroundStyle(HexTheme.danger)
            }

            HStack(spacing: 16) {
                Spacer()
                if isSaving {
                    ProgressView()
                }
                Button {
                    cancel()
                } label: {
                    Text(verbatim: "取消")
                }
                .disabled(isSaving)
                Button {
                    save()
                } label: {
                    Text(verbatim: "儲存").bold()
                }
                .disabled(isSaving || bearerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 15))
        }
        .padding(16)
    }

    private var divider: some View {
        Rectangle()
            .fill(HexTheme.borderWeak)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(HexTheme.textBase)
    }

    private func reload() {
        let settings = ForkDroplineSettings()
        endpointHost = settings.endpoint.map { $0.host() ?? $0.absoluteString }
        isEnabled = settings.isEnabled
        fallback = settings.lastFallback
    }

    private func cancel() {
        isAdding = false
        error = nil
        bearerText = ""
        endpointText = ForkDroplineSettings.defaultEndpoint
    }

    private func save() {
        let bearer = bearerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host() != nil else {
            error = "網址格式不正確"
            return
        }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await ForkDroplineRecognition().save(endpoint: endpoint, bearer: bearer)
                cancel()
                reload()
            } catch let failure as ForkDroplineFailure {
                self.error = failure.reason
            } catch let failure as ForkDroplineKeychainError {
                self.error = "無法存入鑰匙圈（\(failure.status)）"
            } catch {
                self.error = ForkDroplineFailure.network.reason
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "zh_Hant_TW")))
    }
}

private extension View {
    func fieldStyle() -> some View {
        font(.system(size: 15))
            .foregroundStyle(HexTheme.textBase)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(HexTheme.layer02, in: RoundedRectangle(cornerRadius: HexTheme.controlRadius, style: .continuous))
    }
}
