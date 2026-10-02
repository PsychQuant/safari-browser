## 1. 目標解析一次

- [x] 1.1 測試先失敗：URL 目標解析一次、預設目標不列舉、導航後仍追蹤、解析超過逾時仍輪詢一次（Requirement: Wait for URL pattern）
- [x] 1.2 實作 `resolveOnce` 與 `pollUntilDeadline`

## 2. 追蹤分頁

- [x] 2.1 測試先失敗：解析與第一輪之間位移、左側分頁關閉、導航同時左側變動、右側變動、重複網址、位置命名目標（Requirement: Wait for URL pattern）
- [x] 2.2 實作 `WaitURLAnchor` 與 `resolveURLTargetWithWindowURLs`

## 3. 失敗與探測

- [x] 3.1 測試先失敗：視窗關閉、`wait --js --document` 分頁消失、每輪 dialog probe（Requirement: Wait for JS condition）
- [x] 3.2 實作 dangling 對應與 `getCurrentURL` 錨定分支的 probe

## 4. `--timeout` 的意義（#221）

- [x] 4.1 測試（行為多半原本就成立，只有睡眠的要求量是這次改的，其餘測試是把它釘住）：輪詢超過 deadline 不被中斷且答案算數、deadline 後不再開始輪詢、睡眠不超過 deadline、呼叫逾時與 daemon 未回覆的錯誤原樣結束 wait、預設逾時 30 s
- [x] 4.2 實作 `pollUntilDeadline(_:sleep:now:_:)`（睡眠與時鐘可注入） 與 `--help` 說明

## 5. 文件

- [x] 5.1 CHANGELOG 與 README
