# ADR-0007：會議後的清除記憶以 Derek Voice「定期清除開著」為前提

- 狀態：已接受（Derek，2026-11-25）
- 範圍：Mac 的 Meetings
- 依據：ADR-0004

## 背景
Worker 的 `POST /v1/dropline-private/memory/clear` 只在 Derek Voice 開啟定期清除、私人連線有效且帳號相符時，才真的送出 `DELETE /client/memory`；否則回 `200 {cleared:false}`。鍵盤 bearer 呼叫會得到 403。

## 決定
不修改 Derek Voice Worker。Hex 照 ADR-0004 在每場會議後呼叫清除端點，讀回應的 `cleared`，把結果（已清除／未清除／失敗）記在會議的 `fork-dropline.ndjson`，只記狀態，不記回應內容。定期清除是否開著由 Derek 在 Derek Voice 管理。

## 考慮過的做法
- 修改 Worker，新增不需定期清除的會議清除端點：要改另一個 repo。
- 不清除：推翻 ADR-0004。

## 影響
- 定期清除關閉時，會議內容會留在 Dropline 記憶，Hex 的紀錄會顯示「未清除」。
