# 詞彙表：會議與 Annotate 的 Dropline、繁體輸出

這份詞彙表隨設計討論更新。用詞以這裡為準。

- **Dropline 段**：會議錄音中，一次送給 Dropline 的一段音訊。Dropline 單次上限 180 秒、8 MB；Derek Voice 用 178 秒為上限。
- **本機草稿**：會議錄音中，本機模型每 6–10 秒轉錄一小段產生的逐字稿，寫入 `transcript.rolling.ndjson`。
- **定稿**：會議停止後寫入 `transcript.ndjson` 與 `transcript.md` 的逐字稿；摘要讀這份。
- **每字時間**：Annotate 轉錄結果中每個字的開始與結束時間，用來把旁白對到每張截圖（keyframe）。
- **fork 內建繁體轉換**：fork 的 `src/fork/dropline/text.rs` 中 `traditional`，用 Apple Foundation 離線轉換字形，不改寫用詞，保留程式識別名與粵語「吓」。套用在 Dropline 成功回傳的文字、Annotate 的本機轉錄，以及會議的逐字稿、標題與摘要。
- **s2tw 對照表**：Derek 的 `traditional-chinese` transformer 用的本機轉換（`~/dotfiles/hex/.config/hex/s2twp.ts`），由 OpenCC s2tw 字典加 Big5 字形與粵語詞產生，不做台灣詞彙替換。
- **辨識偏置**：轉錄時把字典交給模型。Qwen3-ASR／Whisper 一律套用；Parakeet 要開 Labs › Vocabulary biasing。
- **transformations**：使用者在 `hex.config.ts` 定義、依聽寫模式執行的文字轉換，例如 Derek 的 `traditional-chinese → jev → cjk-spacing`。目前只在一般聽寫執行。
- **音軌**：Hex 一場會議錄兩條音軌，`system.wav`（Them）與 `microphone.wav`（You），各自轉錄，最後依時間軸合併。
- **私人 API**：Dropline 官方 App 的 OAuth token 由 Derek Voice Worker 保管；裝置向 `/v1/dropline-private/token` 拿短效 access token，再呼叫 `/client/dictate`。Hex fork 只用這條路線。
- **公開 API**：用使用者自己的 Dropline 金鑰呼叫 `POST /v1/dictate`。Derek Voice 的會議固定用這條。
- **Dropline 記憶**：Dropline 帳號記住送過的內容。清除端點 `DELETE /client/memory` 一次清掉整個帳號的記憶；Derek Voice 在每場會議處理完後經 Worker `POST /v1/dropline-private/memory/clear` 清除。Hex 目前沒有清除。
- **sounds like**：字典項目的其他拼法。只在 Parakeet 系列模型、Labs › Vocabulary biasing 開啟時於辨識層生效；Qwen3-ASR、Whisper 與 Dropline 都不使用。
- **螢幕 OCR helper**：Derek 的外部程式 `io.veraze.hex-screen-ocr`（LaunchAgent），聽寫開始時擷取最前方視窗並用 Vision OCR，結果寫到 `~/.local/share/hex-lab/screen.json`，供 `Jev` 讀取。
- **螢幕詞**：從螢幕文字挑出、像名稱的詞。Derek 的 `Jev` 最多取 30 個，用在辨識後的校正。
- **Words on screen**：upstream `dev` 的 Labs 功能（`screen-vocabulary`），用 Accessibility 讀前景視窗文字，最多 24 個詞，只交給辨識偏置。尚未進正式版。
- **HandlerContext**：transformations 收到的前後文物件，目前有 `source`、`application`、`browserHost`、`browserUrl`、`windowTitle`。
