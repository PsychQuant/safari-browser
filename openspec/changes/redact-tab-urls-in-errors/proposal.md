## Why

#227：目標解析失敗時的錯誤與 `--first-match` 警告會把所有開著分頁的完整 URL 印出來，含 query。簽章連結的簽章就放在 query 裡，OAuth 回呼的 code 與 token 在 query 或 fragment；一次打錯的 `--url` 就會把它們印進終端機、scrollback、螢幕錄影與貼出去的錯誤報告。`pdf-cache`（#210）已對自己印出的 URL 去掉 query，但共用的錯誤它管不到。

清單的用途是幫人挑 `--url` 子字串或分頁位置，scheme、host、path 加分頁位置就夠；使用者明確要求時（`safari-browser documents`）才需要完整 URL。

## What Changes

- 六個位置顯示分頁 URL 時去掉 query 與 fragment（留 `?…`／`#…`），並把 authority 的帳密換成 `…@`：`documentNotFound` 的清單、`ambiguousWindowMatch` 的候選、`targetTabChanged` 的「Target position now shows」、`--first-match` 的 stderr 警告、`js` 導頁的 stderr 註記、`upload` 的「頁面已導走」錯誤。
- **在建構 payload 的地方脫敏，不是在 `errorDescription` 渲染**：daemon 的 wire error 與 log 印的是 payload（`"\(error)"`），不經 `errorDescription`。切割不要求 URL 是階層式（`about:`、`data:` 同樣處理）。
- `ambiguousWindowMatch` 的候選加上分頁序號（`[window N tab M]`）：常見的模糊原因正是「只差 query 的兩個分頁」，脫敏後只剩序號能區分，也是 `--window N --tab-in-window M` 要的。訊息與 `documentNotFound` 都說明 `safari-browser documents` 會印完整 URL。
- 不變：使用者自己輸入的 pattern 與期望描述、`documents`／`tabs`／`cloud-tabs`、頁面載入的資源網址（`save-image` 的下載錯誤等，屬不同類別，另案）、exit code 與錯誤種類。
- 決定是在無人值守下做的（見 #227 的 Diagnosis 與 R1 處置）；要翻案，還原兩個實作 commit（`bac69fa` 與其後的 R1 修正）與 spec 的提案。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `document-targeting`：新增一條 URL 顯示規則（封閉的六個位置）；修改「Document not found surfaces discoverable error」與「Window ambiguity surfaces deterministic error」。
- `document-listing`：「Discovery aid」改為「指向同一批分頁」，並明寫錯誤清單與 `documents` 對 URL 的顯示不同。

## Impact

- `Utilities/Errors.swift`、新檔 `Utilities/URLText.swift`、`SafariBridge.swift`（十個建構點）、`JSCommand.swift`、`UploadCommand.swift`、測試、CHANGELOG、README、CLAUDE.md。
- 所有帶目標旗標的指令的錯誤文字；`ambiguousWindowMatch` 的 payload 多一個 `tabIndex`。
