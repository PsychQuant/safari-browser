## 1. PDF Export（Export page as PDF）

- [x] 1.1 實作 `pdf` 子指令（`PdfCommand.swift`）：Export page as PDF，透過 System Events 觸發 File > Export as PDF，輸入路徑後確認儲存，預設路徑 `page.pdf`

## 2. Snapshot 改善（Compact snapshot mode、Depth-limited snapshot、Improved element descriptions）

- [x] 2.1 新增 `--compact` (`-c`) flag：Compact snapshot mode，排除 display:none、visibility:hidden、零尺寸元素
- [x] 2.2 新增 `--depth` (`-d`) option：Depth-limited snapshot，計算元素到 scope root 的 DOM 層數，超過 N 層的排除
- [x] 2.3 改善 Improved element descriptions：輸出加入 id（#id）、前 3 個 class（.cls1.cls2.cls3）、disabled 狀態（[disabled]）

## 3. JSON 結構化輸出（JSON output for snapshot、JSON output for tabs、JSON output for cookies get）

- [x] 3.1 `snapshot` 加 `--json` flag：JSON output for snapshot，輸出 JSON array 含 ref/tag/type/attributes
- [x] 3.2 `tabs` 加 `--json` flag：JSON output for tabs，輸出 JSON array 含 index/title/url
- [x] 3.3 `cookies get` 加 `--json` flag：JSON output for cookies get，輸出 JSON object

## 4. Drag and Drop（Drag element to target）

- [x] 4.1 實作 `drag` 子指令（`DragCommand.swift`）：Drag element to target，JS 模擬 dragstart → dragover → drop → dragend，含來源和目標元素不存在的錯誤處理，支援 @ref

## 5. Console 分級（Multi-level console capture）

- [x] 5.1 更新 `ConsoleCommand.swift`：Multi-level console capture，override log/warn/error/info/debug，輸出加 [warn]/[error]/[info]/[debug] 前綴，log 保持無前綴

## 6. Media 設定（Set color scheme preference）

- [x] 6.1 實作 `set` 子指令與 `media` 子選項（`SetCommand.swift`）：Set color scheme preference，注入 CSS override `color-scheme` 屬性強制 dark/light

## 7. 整合與驗證

- [x] 7.1 在 `SafariBrowser.swift` 註冊新子指令（pdf, drag, set）
- [x] 7.2 `make install`
- [x] 7.3 驗證 Export page as PDF
- [x] 7.4 驗證 Compact snapshot mode + Depth-limited snapshot + Improved element descriptions
- [x] 7.5 驗證 JSON output for snapshot + JSON output for tabs + JSON output for cookies get
- [x] 7.6 驗證 Drag element to target
- [x] 7.7 驗證 Multi-level console capture
- [x] 7.8 驗證 Set color scheme preference（dark/light）
