# ADR-0002：Annotate 保留本機模型，用 fork 內建繁體轉換同時轉整段文字和每個字

- 狀態：已接受（Derek，2026-11-25）
- 範圍：Mac 的 Annotate

## 背景
Annotate 用每個字的時間，把旁白對到每張截圖。Dropline 只回傳整段文字，沒有每字時間。Annotate 不執行 transformations，所以文字維持本機模型輸出的簡體。

## 決定
Annotate 繼續用本機模型轉錄。轉錄結果進入 Annotate 前，用 fork 內建繁體轉換（`src/fork/dropline/text.rs` 的 `traditional`）轉換整段文字，也轉換每個字，每字時間不變。

## 考慮過的做法
- 改用 Derek 的 `traditional-chinese` s2tw 對照表：和一般本機聽寫一致，但 Hex 要另外呼叫 TypeScript 設定。
- 改用 Dropline：沒有每字時間，旁白對不到截圖。

## 影響
- Annotate 與 Dropline 結果用同一套轉換，保留程式識別名與粵語「吓」。
- 字典辨識偏置維持現狀。
