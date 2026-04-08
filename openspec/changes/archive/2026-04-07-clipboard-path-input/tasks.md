## 1. 共用 file dialog 函式

- [x] 1.1 在 `SafariBridge.swift` 新增 `static func navigateFileDialog(path:)` — 共用的 AppleScript：等 sheet、Cmd+Shift+G、等 Go to Folder、剪貼簿貼路徑（save/restore clipboard）、Enter、等 Go to Folder 關閉、click AXDefault button（try/on error fallback keystroke return）
- [x] 1.2 在 `SafariBridge.swift` 新增 `static func isAccessibilityPermitted() -> Bool` — 封裝 `AXIsProcessTrusted()` 呼叫

## 2. Upload 改造（file-upload spec）

- [x] 2.1 `UploadCommand.swift` — 改造 upload file via file dialog 的預設行為：`run()` 用 `isAccessibilityPermitted()` 偵測權限，有權限 → native（呼叫 `navigateFileDialog`）、無權限 → JS DataTransfer + stderr 提示
- [x] 2.2 `UploadCommand.swift` — 刪除 `clickFileInputAndNavigateDialog` 私有函式，改用 `SafariBridge.navigateFileDialog`
- [x] 2.3 `UploadCommand.swift` — JS chunking URL 檢查改為每 10 chunks 一次，比對忽略 `#` fragment
- [x] 2.4 `UploadCommand.swift` — JS chunking abort 和 NOT_FOUND 路徑加 `delete window.__sbUpload` 清理

## 3. PDF 改造（pdf-export spec）

- [x] 3.1 [P] `PdfCommand.swift` — 改造 export page as PDF 的 dialog 邏輯：刪除內嵌 AppleScript（keystroke + delay 1），改用 `SafariBridge.navigateFileDialog`

## 4. 文件與清理

- [x] 4.1 [P] 更新 README.md — 修正 L170 舊描述（「upload tries JS DataTransfer first」→ 更新為智慧預設）
- [x] 4.2 [P] 更新 SKILL.md — upload/pdf 段落更新
- [x] 4.3 [P] 更新 CHANGELOG.md — v2.3.0 條目加入剪貼簿改進 + 智慧預設
