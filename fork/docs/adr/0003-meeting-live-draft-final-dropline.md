# ADR-0003：選用 Dropline 時，會議中用本機草稿，定稿和摘要用 Dropline

- 狀態：已接受（Derek，2026-11-25）
- 範圍：Mac 的 Meetings
- 依據：ADR-0001

## 背景
依 ADR-0001，Dropline 每 2–3 分鐘才回來一段。會議中的畫面和 Copy new（⌥⌃V）需要即時文字。

## 決定
會議進行中，畫面、Copy new 與 ⌥⌃V 繼續用本機草稿，草稿先經 fork 內建繁體轉換。會議停止後，定稿（`transcript.ndjson`、`transcript.md`）由 Dropline 段組成，摘要讀這份定稿。

## 考慮過的做法
- Dropline 段回來後即時換掉草稿：會議中較準，但畫面文字會被換掉，也要改較多 upstream 程式。
- 畫面和 Copy new 只用 Dropline 已回來的文字：最多落後約 3 分鐘。

## 影響
- 會議中複製的文字可能和定稿不同。
- 本機草稿照常轉錄，所以本機模型在會議中仍會執行。
