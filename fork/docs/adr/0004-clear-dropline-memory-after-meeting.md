# ADR-0004：每場會議的 Dropline 段處理完後，清除整個 Dropline 帳號記憶

- 狀態：已接受（Derek，2026-11-25）
- 範圍：Mac 的 Meetings
- 依據：ADR-0001

## 背景
Hex 的 Dropline 走私人 API，每次送出的內容都會寫進 Derek 的 Dropline 帳號記憶。會議含有其他人的發言，一場會議會寫進很多段。Derek Voice Local 在每場會議處理完後，經 Worker 的 `POST /v1/dropline-private/memory/clear` 清除整個帳號的記憶（Worker 再呼叫 Dropline 的 `DELETE /client/memory`）。

## 決定
選用 Dropline 的會議，在最後一段 Dropline 段處理完後，清除整個 Dropline 帳號記憶，做法和 Derek Voice Local 相同。

## 考慮過的做法
- 不清除：會議內容留在 Dropline，可能影響之後的聽寫。

## 影響
- 一般聽寫留下的 Dropline 記憶也會一起清掉。
- 審核查證（HEX-11、HEX-12）：清除端點接受 Worker 的 owner API bearer 或登入 bearer，鍵盤 bearer 會得到 403；只在 Derek Voice 開啟定期清除、私人連線有效且帳號相符時才真的清除，否則回 `200 {cleared:false}`。前提的處理見計畫 P1。
