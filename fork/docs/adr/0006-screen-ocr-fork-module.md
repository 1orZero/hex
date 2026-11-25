# ADR-0006：螢幕 OCR 做成 fork 模組，螢幕文字交給 transformation

- 狀態：已接受（Derek，2026-11-25）
- 範圍：Mac 的一般聽寫；對應 DER-67

## 背景
Derek 的 `Jev` transformer 用螢幕文字挑候選詞。目前由外部 helper（LaunchAgent `io.veraze.hex-screen-ocr`）每 50 ms 輪詢 `live.ndjson`，在按下快捷鍵時擷取最前方視窗並 OCR，結果寫到 `~/.local/share/hex-lab/screen.json`；`screen.ts` 用 `tail`、`cat` 讀取，最多等 500 ms。Hex.app 已有螢幕錄製權限（Annotate 在 Hex 主行程擷取畫面）。upstream 的 Words on screen 用 Accessibility，只交給辨識偏置，尚未進正式版。

## 決定
在 fork 新增 OCR 模組，在 Hex 主行程內擷取與 OCR。只在快捷鍵確定是聽寫時擷取。結果放進 transformation 的前後文（`HandlerContext` 新欄位），`Jev` 直接讀取。

## 考慮過的做法
- 保留 helper，放進 Hex.app 由 Hex 啟動：仍是另一個程式。
- 等 upstream 的 Words on screen：只偏置辨識，`Jev` 拿不到螢幕文字。

## 影響
- upstream 檔案各加一小段掛勾：`src/dictation/context.rs`、`src/recognition/context_watch.rs`、`src/personal_commands.rs`、`src/personal_commands/hex.d.ts`。OCR 本體放新檔。
- 不再需要 LaunchAgent、輪詢與暫存檔。`Jev` 要改讀新欄位。
- upstream 的 Words on screen 進正式版後，兩者並存：upstream 的用於辨識偏置，fork 的用於 transformation。
