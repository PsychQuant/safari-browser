## 1. URL 文字處理

- [x] 1.1 測試先失敗：query／fragment／兩者／fragment 內的 `?`、緊跟組合符的分隔符、URL 內含空白、非階層式 URL、authority 帳密、冪等（Requirement: URLs of tabs in targeting errors, warnings and navigation notes are shown without query or fragment）
- [x] 1.2 實作 `URLText.redactURL`（Unicode scalar；帳密換成 `…@`）；刪除以空白切 token 的文字層級啟發式

## 2. 在建構處套用

- [x] 2.1 測試先失敗：經真實產生端（`pickNativeTarget` 的九種失敗、`pickFirstMatchFallback` 的警告與 miss）驗證 payload 自己的描述、`"\(error)"` 與渲染文字都不含 query／fragment／帳密
- [x] 2.2 `SafariBridge` 十個建構點、`ambiguousWindowMatch` 加 `tabIndex`、`JSCommand.navigationNote`、`UploadCommand` 的導走錯誤；`documentNotFound` 與 `ambiguousWindowMatch` 的訊息說明 `documents` 印完整 URL（Requirements: Document not found surfaces discoverable error; Window ambiguity surfaces deterministic error）
- [x] 2.3 tripwire：`SafariBridge.swift` 中每一行把分頁 URL 放進「window …」清單的都必須經 `URLText`
- [x] 2.4 變異檢查：十一個建構點各自拿掉、帳密保留、序號遺失、導頁註記、`targetTabChanged` 渲染

## 3. 規格與文件

- [x] 3.1 spec delta：`document-targeting`（ADDED＋兩條 MODIFIED）、`document-listing`（MODIFIED）
- [x] 3.2 CHANGELOG、README、CLAUDE.md
- [x] 3.3 「Discovery aid for documentNotFound errors」改為指向同一批分頁並明寫 URL 顯示的差異（Requirement: Discovery aid for documentNotFound errors）
