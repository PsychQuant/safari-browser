## 1. Core: Full page state scan

- [x] 1.1 在 `SnapshotCommand.swift` 新增 page flag for full page state（`@Flag(name: .long)`），`if page` 分支走獨立 JS path
- [x] 1.2 實作 TreeWalker JS 執行 full page state scan：遍歷 DOM 產出 accessibility tree（headings with level, text nodes, landmarks, list/listitem, aria roles）。排除 `display:none`、`visibility:hidden`、`aria-hidden="true"` 的元素及其子代
- [x] 1.3 在 TreeWalker 中識別互動元素並 push 到 `window.__sbRefs`，指派 `@eN` ref ID（沿用現有 selector: `input,button,a,select,textarea,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable],[onclick]`）
- [x] 1.4 掃描 page metadata：`window.location.href`、`document.title`、`document.readyState`，輸出在最頂端

## 2. 進階掃描（full page state scan 的子能力）

- [x] 2.1 [P] 掃描 live regions：找所有 `[aria-live]` 元素，輸出其 text content 及 `aria-live` 值（polite/assertive）
- [x] 2.2 [P] 掃描 dialog 狀態：找 `dialog[open]` 和 `[role=dialog]`，輸出 `[dialog aria-modal=true/false]` 及其內容
- [x] 2.3 [P] 掃描 form validation：對所有 `input,select,textarea` 檢查 `checkValidity()`，失敗的輸出 `[invalid: "validationMessage"]` 標註

## 3. Page scan output format + 截斷

- [x] 3.1 實作 page scan output format（plain text 縮排）：每層 DOM 深度 2 spaces 縮排（`[heading level=N]`、`[text]`、`[landmark type]`、`@eN tag desc`）
- [x] 3.2 實作 `--json` 搭配 `--page` 的 JSON 輸出：`{ url, title, readyState, tree, refs, validation }`
- [x] 3.3 實作 page scan truncation：超過 2000 行時截斷到完整元素邊界，附加 `... truncated (N total lines). Use -s "<selector>" to narrow scope.`

## 4. 整合

- [x] 4.1 確認 page scan respects scope flag（`-s`）：metadata 不受 scope 影響，tree 只掃 scope 內元素
- [x] 4.2 確認 `-c`（compact）flag 與 `--page` 搭配運作
- [x] 4.3 [P] 更新 SKILL.md 加入 `snapshot --page` 文件與範例
- [x] 4.4 [P] 更新 README.md 加入 `snapshot --page` 指令說明
