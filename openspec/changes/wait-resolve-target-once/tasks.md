## 1. 目標解析一次

- [x] 1.1 測試先失敗：URL 目標解析一次、預設目標不列舉、導航後仍追蹤、解析超過逾時仍輪詢一次（Requirement: Wait for URL pattern）
- [x] 1.2 實作 `resolveOnce` 與 `pollUntilDeadline`

## 2. 追蹤分頁

- [x] 2.1 測試先失敗：解析與第一輪之間位移、左側分頁關閉、導航同時左側變動、右側變動、重複網址、位置命名目標（Requirement: Wait for URL pattern）
- [x] 2.2 實作 `WaitURLAnchor` 與 `resolveURLTargetWithWindowURLs`

## 3. 失敗與探測

- [x] 3.1 測試先失敗：視窗關閉、`wait --js --document` 分頁消失、每輪 dialog probe（Requirement: Wait for JS condition）
- [x] 3.2 實作 dangling 對應與 `getCurrentURL` 錨定分支的 probe

## 4. 文件

- [x] 4.1 CHANGELOG 與 docs/performance.md
