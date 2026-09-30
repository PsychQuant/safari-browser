## Why

#227：目標解析失敗時的錯誤與 `--first-match` 警告會把所有開著分頁的完整 URL 印出來，含 query。簽章連結的簽章就放在 query 裡，一次打錯的 `--url` 就會把它印進終端機、scrollback、螢幕錄影與貼出去的錯誤報告。`pdf-cache`（#210）已對自己印出的 URL 去掉 query，但共用的錯誤它管不到。

清單的用途是幫人挑 `--url` 子字串，scheme、host、path 就夠；使用者明確要求時（`safari-browser documents`）才需要完整 URL。

## What Changes

- 四個位置顯示分頁 URL 時去掉 query 與 fragment，留 `?…`（有 query）或 `#…`（只有 fragment）作記號：`documentNotFound` 的清單、`ambiguousWindowMatch` 的候選、`targetTabChanged` 的「Target position now shows」、`--first-match` 的 stderr 警告。
- 不變：`documents`／`tabs`／`cloud-tabs` 的輸出（使用者明確要求的探索）、使用者自己輸入的 pattern／期望描述、下載錯誤裡的資源網址、exit code 與錯誤種類。
- 取捨（明寫）：只差 query 的兩個分頁在錯誤清單裡看起來一樣；`[window N]` 標籤、`--window N --tab-in-window M` 與 `documents` 仍能區分。
- 決定是在無人值守下做的（見 #227 的 Diagnosis）；整個實作在一個 commit，翻案只需還原它。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `document-targeting`：新增一條 URL 顯示規則；「Document not found surfaces discoverable error」的「列出 URL」改為列出去掉 query 的 URL。
- `document-listing`：「Discovery aid」明寫錯誤清單與 `documents` 的 URL 顯示不同（前者去 query，後者完整）。

## Impact

- `Utilities/Errors.swift`（三處渲染）、新檔 `Utilities/URLText.swift`、`SafariBridge.swift`（`--first-match` 警告一行）、測試、CHANGELOG、README。
- 所有帶目標旗標的指令的錯誤文字。
