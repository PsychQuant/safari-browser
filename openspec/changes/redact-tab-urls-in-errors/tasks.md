## 1. URL 文字處理

- [x] 1.1 測試先失敗：單一 URL 的 query／fragment／兩者／fragment 內的 `?`、緊跟組合符的分隔符、各種標籤形狀、非 URL 文字與空白原樣保留、`://` 後接組合符（Requirement: URLs of open tabs in targeting errors and warnings are shown without query or fragment）
- [x] 1.2 實作 `URLText.redactURL` 與 `redactingURLs(in:)`（以 Unicode scalar 找分隔符）

## 2. 套用到四個位置

- [x] 2.1 測試先失敗：`documentNotFound`、`ambiguousWindowMatch`、`targetTabChanged`、`--first-match` 警告各自不含 query 中的標記，且標籤與使用者自己的 pattern 保留；沒有 query 的 URL 渲染如前
- [x] 2.2 `Errors.swift` 三處與 `SafariBridge` 的警告一行
- [x] 2.3 變異檢查：每個套用點、字元層級的分隔符搜尋、字元層級的 `://` 搜尋、空白遺失

## 3. 規格與文件

- [x] 3.1 spec delta：`document-targeting`（ADDED＋MODIFIED）、`document-listing`（MODIFIED）
- [x] 3.2 CHANGELOG、CLAUDE.md
- [x] 3.3 `document-targeting` 的「Document not found surfaces discoverable error」與 `document-listing` 的「Discovery aid for documentNotFound errors」兩條 MODIFIED 與實作一致（錯誤清單去 query，`documents` 完整）
