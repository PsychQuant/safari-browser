## Why

Claude 用 safari-browser 操作網頁時，現有 `snapshot` 只列出互動元素（button, input, link），看不到頁面文字內容、heading 結構、錯誤訊息、loading 狀態。導致 Claude 操作後「不知道頁面現在怎麼了」，卡住或盲目繼續。

需要一個一次呼叫就能拿到完整頁面狀態的能力，讓 Claude 每次操作後都能理解頁面語境，不需要額外插入多個指令中斷流程。

## What Changes

新增 `snapshot --page` flag，用 TreeWalker JS 掃描產出完整頁面狀態：

1. **Page metadata** — URL, title, `document.readyState`
2. **Accessibility tree** — headings, text nodes, landmarks (`nav`, `main`, `aside`), aria roles/states, list/listitem 結構
3. **互動元素 + @ref**（沿用現有 `window.__sbRefs` 機制）
4. **Live regions** — `aria-live` alerts, status messages
5. **Dialog/modal 狀態** — 是否有開啟的 `[role=dialog]` 或 `<dialog open>`
6. **Form validation** — invalid fields 及其 `validationMessage`

輸出格式為縮排文字（類似 Playwright accessibility snapshot），`--json` 可搭配使用。大頁面截斷至 ~2000 行。

## Non-Goals

- 不改現有 `snapshot`（無 `--page` flag）的行為 — 互動元素掃描維持不變
- 不做 CSS computed style 分析（顏色、字型、排版） — 那是 screenshot 的領域
- 不做跨 iframe 掃描 — 只掃 top-level document
- 不做 Shadow DOM 穿透 — 第一版只掃 light DOM

## Capabilities

### New Capabilities

- `snapshot-page`: 完整頁面狀態掃描，包含 accessibility tree、page metadata、live regions、dialog 狀態、form validation。輸出縮排文字格式，支援 `--json`。

### Modified Capabilities

- `snapshot`: 新增 `--page` flag。無 flag 時行為不變。

## Impact

- Affected specs: 新增 `specs/snapshot-page/spec.md`，修改 `specs/snapshot/spec.md`（加 `--page` flag）
- Affected code: `Sources/SafariBrowser/Commands/SnapshotCommand.swift`（加 flag + 新 JS 掃描邏輯）
