## 1. Snapshot 指令（Scan interactive elements and assign refs、Interactive-only filter、Scope snapshot to selector、Re-snapshot replaces refs）

- [x] 1.1 實作 `snapshot` 子指令（`SnapshotCommand.swift`）：Scan interactive elements and assign refs，用 Interactive-only filter 掃描互動元素（input, button, a, select, textarea, [role=button/link/menuitem/tab], [contenteditable], [onclick]），分配 @e1..@eN，存到 `window.__sbRefs`，輸出格式 `@eN  tag[type]  描述文字`
- [x] 1.2 支援 `--selector` (`-s`) 選項：Scope snapshot to selector，限定掃描範圍
- [x] 1.3 確保 Re-snapshot replaces refs：每次 snapshot 清空並重建 `window.__sbRefs`

## 2. Ref Resolution（Resolve @ref in selector arguments、Invalid ref error、Stale ref error）

- [x] 2.1 在 SafariBridge 新增 `resolveRef` helper：Resolve @ref in selector arguments，偵測 `@eN` 格式時產生 JS 從 `window.__sbRefs[N-1]` 取元素，否則用 `document.querySelector`。含 Invalid ref error 和 Stale ref error（No snapshot taken）
- [x] 2.2 更新所有使用 `querySelector` 的指令改用 resolveRef helper：click, dblclick, fill, type, select, hover, focus, check, uncheck, scrollintoview, highlight, get text/html/value/attr/box, is visible/enabled/checked, find（共 20+ 個指令）

## 3. 整合與驗證

- [x] 3.1 在 `SafariBrowser.swift` 註冊 `snapshot` 子指令
- [x] 3.2 `swift build -c release` + `make install`
- [x] 3.3 驗證：snapshot 輸出、snapshot -s、click @ref、fill @ref、Invalid ref error、No snapshot taken error、CSS selector 仍正常
