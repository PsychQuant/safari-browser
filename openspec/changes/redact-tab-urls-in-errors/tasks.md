## 1. URL 文字處理

- [x] 1.1 測試先失敗：query／fragment／兩者／fragment 內的 `?`、緊跟組合符的分隔符、URL 內含空白、非階層式 URL、authority 帳密、冪等（Requirement: URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment）
- [x] 1.2 實作 `URLText.redactURL`（Unicode scalar；帳密換成 `…@`）；刪除以空白切 token 的文字層級啟發式

## 2. 在建構處套用

- [x] 2.1 測試先失敗：經真實產生端（`pickNativeTarget` 的九種失敗、`pickFirstMatchFallback` 的警告與 miss）驗證 payload 自己的描述、`"\(error)"` 與渲染文字都不含 query／fragment／帳密
- [x] 2.2 `SafariBridge` 十一個建構點、`ambiguousWindowMatch` 加 `tabIndex`、`JSCommand.navigationNote`、`UploadCommand` 的導走錯誤；`documentNotFound` 與 `ambiguousWindowMatch` 的訊息說明 `documents` 印完整 URL（Requirements: Document not found surfaces discoverable error; Window ambiguity surfaces deterministic error）
- [x] 2.3 tripwire（形狀檢查，不是證明）：`SafariBridge.swift`、`JSCommand.swift`、`UploadCommand.swift`、`Errors.swift` 中內插分頁 `.url` 的行都必須經 `URLText`；各檔的脫敏處數固定（11／1／2／1，增減都要有人決定）；`targetTabChanged` 改用 `RedactedURL`，不需要 tripwire
- [x] 2.4 變異檢查：十一個建構點各自拿掉、帳密保留、序號遺失、導頁註記、`targetTabChanged` 渲染
- [x] 2.5 R2：路徑參數、路徑內另一個 URL 的帳密、`data:`／`javascript:`、長度上限（每一項各自拿掉都有測試失敗）；`upload` 導走訊息的行為測試；`-1719`／`-1728` 翻譯處的行為測試；positional 未命中的清單也帶「URL 已截短」的說明；提示涵蓋 `--url`／`--url-exact`／`--url-endswith`；`--profile` 下 `--window` 的數字說明；`documents` 測試不再掃描真的 Safari

## 3. 規格與文件

- [x] 3.1 spec delta：`document-targeting`（ADDED＋兩條 MODIFIED）、`document-listing`（MODIFIED）、`file-upload`（MODIFIED）
- [x] 3.2 CHANGELOG、README、CLAUDE.md
- [x] 3.3 「Discovery aid for documentNotFound errors」改為指向同一批分頁並明寫 URL 顯示的差異（Requirement: Discovery aid for documentNotFound errors）
- [x] 3.4 「Upload file via file dialog」的導走錯誤改為顯示不含 query 的新舊 URL，兩者脫敏後相同時說明差異在沒顯示的部分（Requirement: Upload file via file dialog）
- [x] 2.6 R3：`redactURL` 取不動點（冪等）、外層 authority 只認開頭的 `scheme://`、`data:`／`javascript:` 前導空白、`RedactedURL`；上限與處理順序以字面值／輸入釘住；upload 導走分支以假頁面實際驅動；說明文字改為「shortened」
- [x] 3.5 `human-emulation` 的「Cross-subcommand tab enumeration is consistent」與 `document-listing` 對齊（Requirement: Tab bar as ground truth）
