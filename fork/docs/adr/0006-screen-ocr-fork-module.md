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

## 實作（DER-67，PR #11）
- 讀取時機：只在有模式用 script transformation 時讀取。一次擷取只讀一次，在擷取確定成立時讀（按住超過門檻、`hex dictation start`，或閒置時釋放的麥克風重新開啟時）；短按在結束時讀。raw 與取消的聽寫不讀。
- 權限：讀取前用 `CGPreflightScreenCaptureAccess` 檢查，從不跳出授權要求。macOS 在同一個行程裡沿用第一次的結果，所以給了螢幕錄製權限後要重開 Hex。
- 交付：transformation chain 最多等 500 ms。逾時、失敗或沒有權限時省略 `screenLines`，最多傳 400 行、32 KiB。Hex 不寫檔，log 只記行數與耗時。螢幕文字不進辨識，也不進 Dropline。
- upstream 掛勾：實際動到 8 個檔案、共 40 行，比「影響」列的 4 個檔案多了 `build.rs`、`src/recognition.rs`，以及 `src/dictation/processor.rs`、`src/meeting/detection.rs` 的測試 fixture。各處用途記在 `FORK.md` 的「Screen text」。
- 量測：Vision 載入後，一次讀取約 220–290 ms，在錄音中完成，transformation 不必等待。新簽章的 build 第一次載入 Vision 曾花 45 秒。
- `Jev`：Derek dotfiles 的修改（`screen.ts` 先讀 `context.screenLines`）在安裝新版後套用，之後停用 LaunchAgent。
