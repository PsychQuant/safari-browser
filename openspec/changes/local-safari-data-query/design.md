## Context

`safari-browser` 現有 42 個 top-level 指令**全部**透過 AppleScript、Accessibility API 或 CoreGraphics 操作執行中的 Safari。**沒有任何一個指令碰檔案系統。** 本變更引入這個 repo 的第一條本機檔案讀取路徑，因此沒有既有 pattern 可沿用，需要建立新的慣例。

四個目標資料檔位於 `~/Library/Safari/`，受 TCC 保護，需要「完全取用磁碟」（`kTCCServiceSystemPolicyAllFiles`）。這是本工具目前未使用的權限類別——現有的三種權限（輔助使用、螢幕錄製、Apple 事件）都由 `safari-browser setup` 處理。

各檔案的格式與陷阱已於 issue #109 診斷階段實測確認：

| 檔案 | 格式 | 已實測的陷阱 |
|---|---|---|
| `History.db` | SQLite（WAL 模式） | 不連同 `-wal` / `-shm` 複製會漏掉尚未 checkpoint 的最新紀錄 |
| `Bookmarks.plist` | binary plist | `plutil -convert json` 失敗（`Invalid object in plist for JSON format`） |
| `CloudTabs.db` | SQLite | 在開發機上**不存在**——缺檔是常態而非錯誤 |
| `Downloads.plist` | plist | 四者中唯一未實測 |

## Goals / Non-Goals

**Goals:**

- 讓「找回看過的頁面」這類查詢不必離開本工具、不必手寫 SQL
- 四個指令維持與現有 42 個指令一致的介面慣例（輸出格式、`--json`、錯誤處理）
- 在權限不足時給出**能實際照做**的指引，而非泛用的「權限被拒」
- 維持 Non-Interference 契約：唯讀、不碰輸入裝置、不搶焦點、不改 Safari 任何狀態

**Non-Goals:**

- **不**提供跨來源的搜尋策略或關聯查詢。四個指令各自獨立；「先查哪個來源、命中太多如何收斂、跨來源如何交叉比對」屬於使用層策略，不在本變更範圍（此為 issue #109 明確標記的 residue）。
- **不**改變 `safari-browser setup` 的行為，也**不**改變 `make install` 的預設簽章方式。
- **不**支援寫入。四個資料檔一律唯讀。
- **不**支援查詢其他瀏覽器。
- **不**做 `protocol SafariDataSource` 之類的共同查詢抽象（理由見 Decision 2）。
- **不**在 daemon 路徑上支援這四個指令（它們不走 AppleScript，daemon 化無收益）。

## Decisions

### Decision 1：FDA 錯誤訊息依 binary 自身簽章狀態分歧，但**不**改變預設安裝方式

**背景**：issue #109 原本假設「CLI 的 FDA 授權慣常歸給負責的父程序（終端機），而非 binary 自己」，並標記為未驗證前提。

**實測結果推翻了這個假設。** 查詢 `kTCCServiceSystemPolicyAllFiles` 的授權清單發現一個結構完全對照的樣本：`~/bin/` 下另一個無 app bundle、同樣以命令列執行的 binary **持有 FDA 授權**。兩者差別只有簽章——該 binary 是 Developer ID + hardened runtime，而 `safari-browser` 是 adhoc（`TeamIdentifier=not set`），且沒有任何 TCC 條目。

**結論**：binary **可以**自己持有 FDA，決定因素是**簽章**，不是「是不是 CLI」。

**決定**：不改變 `make install` 的預設（仍為 adhoc）。改為讓指令在權限失敗時讀取自身簽章狀態，給出分歧訊息：

- adhoc build → 說明此 build 的授權在重新編譯後可能失效，指向 `make sign-developer-id`，並提供「改為授權終端機」作為替代路徑
- Developer ID build → 直接指引將 binary 加入系統設定的「完全取用磁碟」

**為何不改預設安裝**：`make sign-developer-id` 需要 `DEVELOPER_ID` 環境變數，沒有 Apple Developer 憑證的使用者會直接失敗。把它變成預設會讓**所有**使用者的安裝流程壞掉，代價遠大於本功能。讓錯誤訊息說實話的成本近乎零。

**考慮過的替代方案**：
- *一律指示授權終端機* — 被否決。那是範圍大得多的授權（終端機能讀的檔案遠超本工具所需），且實測證明沒有必要。
- *改 `make install` 預設為 Developer ID 簽章* — 被否決，blast radius 見上。
- *在 `setup` 加 `--with-fda`* — 被否決。FDA 無法以程式方式請求（不像輔助使用有 `AXIsProcessTrusted` 的請求 API），使用者必須手動在系統設定加入，`setup` 能做的只有印出指引，與錯誤訊息重複。

### Decision 2：`SafariDataStore` 只共用檔案存取，**不**抽象查詢

四個來源真正共通的只有一件事：把 TCC 保護的檔案（含 WAL sidecar）安全複製到暫存區，或回報型別化錯誤。

**不建立 `protocol SafariDataSource`。** 四者的輸出結構毫無共通點——造訪紀錄是含時間戳與次數的平面列、書籤是有階層的樹、iCloud 分頁按裝置分組、下載紀錄是檔名對來源網址。強行抽出共同協定會是**假抽象**：協定裡放不進任何有意義的共同方法，每個實作最後都在做完全不同的事，而讀者還得多穿過一層才看得到真正的邏輯。

這也符合本 repo `CLAUDE.md` 的 coding style：「MANY SMALL FILES > FEW LARGE FILES：High cohesion, low coupling」。

**考慮過的替代方案**：
- *完整 repository pattern（型別化模型 + 統一查詢介面）* — 被否決。YAGNI；四個來源沒有共同的查詢語意。
- *每個指令各自複製檔案，不共用工具層* — 被否決。WAL sidecar 處理、FDA 偵測、暫存目錄清理這三件事若複製四份，任一份寫錯都是靜默的資料正確性問題。

### Decision 3：預設輸出上限依**資料性質**分兩類

四個來源的敏感度不對稱，預設上限跟著這個不對稱走：

| 類型 | 指令 | 性質 | 預設 |
|---|---|---|---|
| 行為軌跡 | `history`、`downloads` | 使用者**做了什麼**、何時做——長期全域紀錄 | `--limit` 預設 50，最近優先 |
| 策展／當下狀態 | `bookmarks`、`cloud-tabs` | 使用者**選擇留下**的、現在開著的——本人整理過 | 無上限（資料量本來就小） |

**為何不用 `--confirm` 之類的互動確認**：會彈出互動提示，違反 Non-Interference 契約的精神，且讓指令無法進入管線（`safari-browser history | grep ...` 會卡住）。

**考慮過的替代方案**：
- *四者統一預設上限* — 被否決。對書籤設上限只會讓「列出我的書籤」這個明顯無害的操作被截斷，徒增困惑。
- *完全不設上限* — 被否決。`history` 在實測機器上有超過十萬筆造訪紀錄，預設全吐會淹沒終端機與 agent context。

### Decision 4：時間戳轉換獨立成可測試單元

`History.db` 的 `history_visits.visit_time` 以 Core Data epoch（2001-01-01）計算，需 `+978307200` 轉為 Unix epoch。**寫錯不會產生任何錯誤，只會讓所有時間差 31 年。** 這種靜默失效必須有獨立測試守住，不可只靠 end-to-end 驗證時肉眼判斷。

### Decision 5：缺檔是正常結果，不是錯誤

`CloudTabs.db` 在未啟用 iCloud 分頁同步的機器上不存在（開發機即為此例）。缺檔時指令**以 exit code 0 結束**，stdout 無資料列，stderr 印一行說明。這與「權限不足」是不同的失敗類別，必須分開處理——把缺檔當錯誤會讓正常設定的機器上出現假警報。

## Implementation Contract

### Behavior

安裝並取得 FDA 授權後，使用者可執行四個新指令，各自從對應的本機檔案讀出資料並印到 stdout。四個指令都不修改 Safari 狀態、不需要 Safari 正在執行、不搶視窗焦點。

### Interface

```
safari-browser history    [--search <text>] [--since <YYYY-MM-DD>] [--limit <n>] [--json]
safari-browser bookmarks  [--folder <name>] [--json]
safari-browser cloud-tabs [--json]
safari-browser downloads  [--limit <n>] [--json]
```

- `--limit` 於 `history` 與 `downloads` 預設為 `50`；於 `bookmarks` 與 `cloud-tabs` **不提供此選項**
- `--search` 對網址與標題做大小寫不敏感的子字串比對
- `--since` 接受 `YYYY-MM-DD`，篩選該日期（含）之後的造訪
- `--folder` 對書籤資料夾名稱做大小寫不敏感的子字串比對

工具層：

```swift
enum SafariDataFile: CaseIterable {
    case history       // History.db，含 -wal / -shm
    case bookmarks     // Bookmarks.plist
    case cloudTabs     // CloudTabs.db，含 -wal / -shm
    case downloads     // Downloads.plist
}

enum SafariDataStore {
    /// 將指定檔案（含其 WAL sidecar，若有）複製到新建的暫存目錄，
    /// 以主檔 URL 呼叫 `body`，並在 `body` 返回或拋出後**必然**移除該暫存目錄。
    static func withCopy<T>(_ file: SafariDataFile, _ body: (URL) throws -> T) throws -> T

    /// 可測試核心：來源路徑由呼叫端指定，供單元測試以 fixture 驗證 sidecar 行為。
    static func withCopy<T>(
        sourceURL: URL, includeWALSidecars: Bool, _ body: (URL) throws -> T
    ) throws -> T
}
```

**為何是 scope-based 而非回傳 URL**：本文件初稿寫的是 `copyForReading(_:) throws -> URL` + 「呼叫端負責移除」。該形狀**無法滿足** `local-data-query` spec 的 `Safe copy of TCC-protected data files` 要求——其 scenario 明訂暫存目錄在「**成功或失敗皆然**」的情況下都不得殘留，而任何仰賴呼叫端記得寫 `defer` 的契約都會在錯誤路徑上漏掉。改為 scope-based 後清理由型別保證，呼叫端無從遺漏。（此修正於 apply 階段發現並就地更新，未靜默偏離。）

### Data shape（`--json`）

`history`：
```json
[{"url": "...", "title": "...", "visit_time": "2026-08-17T10:03:43+08:00", "visit_count": 3}]
```

`bookmarks`：
```json
[{"folder": "BookmarksBar/AI", "title": "...", "url": "...", "reading_list": false}]
```

`cloud-tabs`：
```json
[{"device": "...", "title": "...", "url": "..."}]
```

`downloads`：
```json
[{"filename": "...", "source_url": "...", "date": "2026-08-17T10:03:43+08:00"}]
```

時間一律為含時區偏移的 ISO 8601。

### 預設輸出（非 `--json`）

沿用 `documents` 的既有慣例：說明性文字寫 **stderr**、可解析的資料列寫 **stdout**，使 `| grep` 這類用法不被裝飾文字污染。

資料列格式為 `[N]  <欄位…>`，欄位間以兩個空格分隔。無資料時 stdout 為空。

### Failure modes

| 情況 | Exit code | 行為 |
|---|---|---|
| 權限不足（無法讀取 `~/Library/Safari/`） | 非 0 | stderr 印出**依簽章狀態分歧**的指引（見 Decision 1）；stdout 無輸出 |
| 資料檔不存在（如未啟用 iCloud 分頁） | **0** | stderr 印一行說明；stdout 無輸出 |
| 資料檔存在但無法解析 | 非 0 | stderr 指出是哪個檔案與哪一層解析失敗 |
| 查詢結果為空（條件無命中） | 0 | stdout 無資料列；`--json` 輸出 `[]` |

「權限不足」與「檔案不存在」**必須**是不同的錯誤類型，不可合併——前者需要使用者採取行動，後者是正常狀態。

### Acceptance criteria

1. 四個指令都出現在 `safari-browser --help` 的 subcommand 清單中。
2. `safari-browser history --limit 5` 印出 5 行以內的資料列，時間為當前世紀（驗證 Core Data epoch 轉換）。
3. 針對 epoch 轉換有獨立的單元測試，以已知輸入驗證已知輸出，不依賴實機資料。
4. `SafariDataStore.copyForReading(.history)` 複製後的暫存目錄同時含有 `History.db` 與其存在的 sidecar 檔。
5. 在 `CloudTabs.db` 不存在的機器上，`safari-browser cloud-tabs` 以 exit code 0 結束、stdout 無輸出、stderr 有說明。
6. 四個指令的 `--json` 輸出皆為合法 JSON（`| python3 -m json.tool` 不報錯），無資料時為 `[]`。
7. 非 `--json` 模式下，stdout **不含**任何說明性文字（`2>/dev/null` 後仍可直接解析）。
8. 既有測試全數通過，未因 `SafariBrowser.swift` 的 subcommand 註冊變動而失敗。

### Scope boundaries

**In scope**：四個指令、`SafariDataStore` 工具層、兩個新錯誤類型、subcommand 註冊、`non-interference` 與 `json-output` 兩份 spec 的 delta、新增 `local-data-query` spec、README 指令表、上述單元測試。

**Out of scope**：跨來源搜尋策略、daemon 路徑支援、`setup` 的任何變動、`Makefile` 的任何變動、寫入能力、其他瀏覽器。

## Risks / Trade-offs

**[adhoc 簽章下 FDA 授權可能在重新編譯後靜默失效]** → 錯誤訊息在偵測到 adhoc build 時主動說明此風險並指向 `make sign-developer-id`。**誠實邊界：此失效機制是根據 TCC 以 cdhash 識別未簽章 binary 的運作方式所做的推論，未經實測。** 錯誤訊息的設計對這條推論不敏感——即使推論有誤，建議使用者改用簽章 build 仍然正確。

**[複製 `History.db` 的瞬間 Safari 正在寫入，取得撕裂狀態]** → 連同 `-wal` / `-shm` 一起複製；SQLite 的 WAL 設計對此有容忍度。實作時需明確驗證而非假設——若複製後開啟失敗，錯誤訊息須指出是複製一致性問題而非權限問題。

**[`CloudTabs.db` 無法在開發機驗證]** → 缺檔路徑可測（開發機即為缺檔狀態）；「有檔時解析是否正確」只能標記為未驗證，並在 tasks 中明確記錄此限制，不假裝已驗證。

**[plist 是 Apple 內部格式，無跨版本穩定保證]** → 解析失敗時給出指名檔案與解析層級的錯誤，而非泛用的 parse error，使日後 macOS 改格式時能快速定位。

**[這四個指令的資料敏感度高於既有任何指令]** → 既有指令只看得到使用者當下自己開著的頁面；這四個讀的是長期全域行為軌跡。以預設上限（Decision 3）降低意外傾倒的量，並在 `non-interference` spec 中明文記載此差異，使日後新增同類指令時有先例可循。

**[與 #110 共享 `SafariBrowser.swift` 的 subcommand 註冊陣列]** → Conflict Class 為 `C_shared_module_coord`。兩者若並行推進需序列化合併，不可交錯。

## Migration Plan

無資料遷移。四個指令是純新增，不改變任何既有指令的行為。

若需回退：移除四個 Command 檔、`SafariDataStore.swift`、`SafariBrowser.swift` 中的四筆註冊、`Errors.swift` 中的兩個新 case。既有指令不受影響，因為本變更未修改任何既有程式路徑。

`idd-109-baseline` tag 標記了開工前的 main HEAD，可作為回退錨點。

## Open Questions

- ~~`Downloads.plist` 的實際結構尚未實測~~ — **已於實作階段實測，此問題已關閉。** 實際結構為：根層字典含單一 `DownloadHistory` 陣列，每筆帶 `DownloadEntryPath`（完整路徑，檔名取其 basename）、`DownloadEntryURL`（來源網址）、`DownloadEntryDateAddedKey` 與 `DownloadEntryDateFinishedKey`。

  **一項與預期不同、值得記錄的差異**：這兩個日期欄位是**原生 plist `Date` 物件**，不是 `History.db` 那種 Core Data reference time 整數——因此 `downloads` **不套用** `+978307200` 偏移。若當初照 `history` 的模式類推，會得到全部偏移 31 年且不報錯的時間戳。實作採 `DownloadEntryDateAddedKey`（下載開始時間），實測樣本中兩個欄位皆 100% 存在。
