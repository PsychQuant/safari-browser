## Why

#227：目標解析失敗時的錯誤與 `--first-match` 警告會把所有開著分頁的完整 URL 印出來，含 query。簽章連結的簽章就放在 query 裡，OAuth 回呼的 code 與 token 在 query 或 fragment；一次打錯的 `--url` 就會把它們印進終端機、scrollback、螢幕錄影與貼出去的錯誤報告。PR #228（`pdf-cache`，#210，尚未合併）對它自己印出的 URL 去掉 query，但共用的錯誤它管不到。

清單的用途是幫人挑 `--url` 子字串或分頁位置，scheme、host、path 加分頁位置就夠；使用者明確要求時（`safari-browser documents`）才需要完整 URL。

## What Changes

- 六個位置顯示分頁 URL 時去掉 query 與 fragment（留 `?…`／`#…`）、把 authority 的帳密換成 `…@`（含路徑裡另一個 URL 的帳密）、把路徑參數（`;jsessionid=…`）換成 `;…`、把 `data:`／`javascript:` 的內容整段換成 `data:…`、並把超過 200 個 scalar 的部分截掉：`documentNotFound` 的清單、`ambiguousWindowMatch` 的候選、`targetTabChanged` 的「Target position now shows」、`--first-match` 的 stderr 警告、`js` 導頁的 stderr 註記、`upload` 的「頁面已導走」錯誤。
- **在建構 payload 的地方脫敏，不是在 `errorDescription` 渲染**：daemon 的 wire error 與 log 的 `error` 欄位印的是 payload（`"\(error)"`），不經 `errorDescription`。`?`／`#` 的切割不要求 URL 是階層式（`about:blank#x` 同樣處理）。唯一的例外明寫在 spec：`targetTabChanged` 的 URL 欄位是 `RedactedURL`：建構時就脫敏、沒有字串字面值轉換，所以 payload 不可能帶未脫敏的 URL，producer 也傳不進原始字串（不是靠測試把關，是編譯不過）。
- `ambiguousWindowMatch` 的候選加上分頁序號（`[window N tab M]`）：常見的模糊原因正是「只差 query 的兩個分頁」，脫敏後只剩序號能區分，也是 `--window N --tab-in-window M` 要的（用了 `--profile` 時，`--window` 只數該 profile 的視窗，訊息會說明）。訊息與 `documentNotFound` 都說明 `safari-browser documents` 會印完整 URL；`upload` 導走的錯誤在兩個 URL 脫敏後長得一樣時會說「差異在沒顯示的部分」。
- 不變：使用者自己輸入的 pattern 與期望描述、`documents`／`tabs`／`cloud-tabs`、daemon log 的 `result` 欄位（記的是指令回傳的內容，另案 #230）、頁面載入的資源網址（`save-image` 的下載錯誤等，屬不同類別，另案 #229）、exit code 與錯誤種類。路徑本身的秘密（`/reset/<token>`）認不出來，照原樣顯示。已知的代價：兩個錯誤都指向 `safari-browser documents` 找完整 URL，而它印出全部——這是刻意的決定（使用者明確執行它），但若威脅是 agent 的對話紀錄，照提示做的 agent 會在下一個指令重現同樣的曝露。
- 決定是在無人值守下做的（見 #227 的 Diagnosis 與 R1 處置）；要翻案，還原所有實作 commit（`git log --grep '(#227)'` 列出，各輪修正都帶 `(#227)`）與 spec 的提案。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `document-targeting`：新增一條 URL 顯示規則（封閉的六個位置）；修改「Document not found surfaces discoverable error」與「Window ambiguity surfaces deterministic error」。
- `document-listing`：「Discovery aid」改為「錯誤清單裡列出的每個分頁都是 `documents` 列得出的分頁，窗號與分頁號相同」，並明寫兩者對 URL 的顯示不同。
- `human-emulation`：「Tab bar as ground truth」的情境「Cross-subcommand tab enumeration is consistent」限縮到列舉分頁的清單，並容許依原因縮小範圍的清單。
- `file-upload`：「Upload file via file dialog」的導走錯誤改為顯示不含 query 的新舊 URL。

## Impact

- `Utilities/Errors.swift`、新檔 `Utilities/URLText.swift`、`SafariBridge.swift`（十一個建構點）、`JSCommand.swift`、`UploadCommand.swift`、測試、CHANGELOG、README、CLAUDE.md。
- 所有帶目標旗標的指令的錯誤文字；`ambiguousWindowMatch` 的 payload 多一個 `tabIndex`。
