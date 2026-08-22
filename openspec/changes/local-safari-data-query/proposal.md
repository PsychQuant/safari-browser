## Why

`safari-browser` 目前的 42 個指令全部操作**當下開著的** Safari（分頁、DOM、截圖、上傳），沒有任何一個能回答「我之前看過、但忘記網址也忘記站名的頁面在哪」。Safari 在本機存了四份能回答這個問題的資料——造訪紀錄、書籤與閱讀列表、其他裝置的 iCloud 分頁、下載紀錄——而這個工具完全讀不到。

現況下唯一的辦法是繞過本工具、手寫 `sqlite3` 查詢，每次都要重新推導 schema、時間戳換算與 WAL 處理。這是反覆出現的需求，值得成為一等公民指令。

見 issue #109。

## What Changes

- 新增四個平行的 top-level 指令，各自對應一個資料來源：
  - `safari-browser history` — 造訪紀錄（`History.db`），支援 `--search` / `--since` / `--limit`
  - `safari-browser bookmarks` — 書籤與閱讀列表（`Bookmarks.plist`），支援 `--folder`
  - `safari-browser cloud-tabs` — 其他裝置的 iCloud 分頁（`CloudTabs.db`）
  - `safari-browser downloads` — 下載紀錄（`Downloads.plist`），支援 `--limit`
- 新增工具層 `SafariDataStore`，唯一職責是把 TCC 保護目錄下的檔案（含 WAL sidecar）安全複製到暫存區，並在權限不足或檔案不存在時丟出型別化錯誤。
- 四個指令的預設輸出沿用 `documents` 的慣例：說明性文字走 stderr、可解析的資料列走 stdout；`--json` 供程式消費。
- 新增錯誤類型：權限不足（訊息依 binary 自身簽章狀態分歧）、資料檔不存在。
- **不改變** `safari-browser setup` 的行為——完全取用磁碟（FDA）不納入預設權限流程。

## Non-Goals

Non-Goals 記錄於 `design.md` 的 Goals / Non-Goals 段落。

## Capabilities

### New Capabilities

- `local-data-query`: 唯讀查詢本機 Safari 資料的四個指令、其共用的檔案存取層、FDA 權限處理，以及依資料敏感度分級的預設輸出上限。

### Modified Capabilities

- `non-interference`: 新增四個指令的 interference level 分級（皆為 Non-interfering），並要求記載其資料敏感度與既有指令的差異——既有指令只能看到使用者當下自己開著的頁面，這四個讀的是長期全域紀錄。
- `json-output`: 將 `--json` 輸出契約擴及四個新指令。

## Impact

**新增檔案**

- `Sources/SafariBrowser/Commands/HistoryCommand.swift`
- `Sources/SafariBrowser/Commands/BookmarksCommand.swift`
- `Sources/SafariBrowser/Commands/CloudTabsCommand.swift`
- `Sources/SafariBrowser/Commands/DownloadsCommand.swift`
- `Sources/SafariBrowser/Utilities/SafariDataStore.swift`
- `Tests/SafariBrowserTests/SafariDataStoreTests.swift`
- `Tests/SafariBrowserTests/HistoryCommandTests.swift`
- `Tests/SafariBrowserTests/BookmarksCommandTests.swift`

**修改檔案**

- `Sources/SafariBrowser/SafariBrowser.swift` — `subcommands:` 陣列註冊四個新指令
- `Sources/SafariBrowser/Utilities/Errors.swift` — 新增 `fullDiskAccessRequired` 與 `safariDataFileNotFound`
- `README.md` — 指令表補四個新項

**不修改**

- `Sources/SafariBrowser/Commands/SetupCommand.swift` — FDA 不納入 setup
- `Makefile` — 不改變預設安裝的簽章方式

**系統相依**

- 需要「完全取用磁碟」（`kTCCServiceSystemPolicyAllFiles`）才能讀取 `~/Library/Safari/`。這是本工具目前未使用的權限類別（現有只需輔助使用權限、螢幕錄製、Apple 事件）。

**衝突協調**

- 與 #110（MCP façade）共享 `SafariBrowser.swift` 的 `subcommands:` 註冊陣列。Conflict Class 為 `C_shared_module_coord`——兩者並行推進時不可交錯合併。
