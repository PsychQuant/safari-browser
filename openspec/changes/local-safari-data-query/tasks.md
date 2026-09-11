> **歷史紀錄界線**：第 1–6 節保留 #109 原始工作與當時驗證紀錄（含 1.3 的更正）。其中 `withCopy`、WAL sidecar 磁碟複本及舊版驗收項目已由 #111/#112/#113/#115/#116/#117/#120 的 `local-data-correctness` 取代；舊勾選不代表新的記憶體存取／解析行為已完成驗證。當前契約見本 change 的 design/spec；後續證據見第 7 節。

## 1. 檔案存取層

- [x] 1.1 撰寫 `SafariDataStoreTests` 中的 WAL sidecar 測試：建立含 `X.db`、`X.db-wal`、`X.db-shm` 的暫存 fixture，斷言 `withCopy` 交給 body 的目錄同時含有三者；再以只有主檔的 fixture 斷言不因缺 sidecar 而失敗。此測試在實作前必須失敗（滿足 `Safe copy of TCC-protected data files`）。驗證：`swift test --filter SafariDataStoreTests` 由紅轉綠。
- [x] 1.2 實作 `SafariDataStore.withCopy(_:_:)`，使 `SafariDataFile` 的四個 case 都能被複製到獨立暫存目錄並以主檔 URL 呼叫 body，且 body 返回**或拋出**後該目錄皆不再存在（滿足 `Safe copy of TCC-protected data files`）。驗證：1.1 的測試全綠，且測試結束後 `/tmp` 無殘留 `safari-data-*` 目錄。
- [x] 1.3 讓「權限不足」與「檔案不存在」成為兩個可分辨的結果：`Errors.swift` 新增 `fullDiskAccessRequired` 與 `safariDataFileNotFound`，前者以非 0 結束、後者以 0 結束且 stdout 無資料列（滿足 `Full Disk Access failure is distinguished from missing data files`）。**驗證（更正，#109 verify MEDIUM-11）：訊息通道的區分由 `CodeSigningStateTests.testMissingFileErrorIsDistinctFromPermissionError` 覆蓋。exit code 那一半當時沒有做——`ErrorsTests.swift` 在本 change 的任何 commit 中都未被觸及。** 原本此處寫的是「`ErrorsTests` 新增斷言涵蓋兩者的 exit code 與訊息通道」，那是一筆不實的完成紀錄。缺口本身追蹤於後續 issue。
- [x] 1.4 使 FDA 權限錯誤的 stderr 內容隨 binary 自身簽章狀態分歧——ad-hoc build 須提及重編後授權可能失效並同時給出 `DEVELOPER_ID=<cert-sha1> make install-signed` 與「改授權終端機」兩條路；經驗證 durable 的 build 須指示將 binary 加入系統設定，且跨重編保留授權以同一簽署身分與 DR 為前提；無法確認時不得保證授權持續有效（滿足 `Permission guidance is specific to the binary's signing state`）。**紀錄界線（#124）**：保留 #109 原有完成勾選及當時「兩種簽章狀態各有一個單元測試」的紀錄；本次僅同步 #119 的安裝入口及 #122 的分類契約，新分類與指引的驗證由 `shared-install-signature-contract` task 1.1／2.2 追蹤，不以舊勾選宣稱新行為已驗證。

## 2. history 指令

- [x] 2.1 撰寫 Core Data epoch 轉換的獨立單元測試，以 spec 中的三組已知值（`0` → 2001-01-01T00:00:00Z、`1` → 2001-01-01T00:00:01Z、`788918400` → 2026-01-01T00:00:00Z）斷言轉換結果，不依賴實機資料（滿足 `Core Data epoch conversion for history timestamps`）。驗證：`swift test --filter HistoryCommandTests` 中該測試由紅轉綠。
- [x] 2.2 實作 `HistoryCommand`，使 `safari-browser history` 能從複製後的 `History.db` 讀出造訪紀錄並依時間新到舊排序，預設輸出 50 筆、可用 `--limit` 覆寫，且 `--search` 對網址與標題做大小寫不敏感比對、`--since YYYY-MM-DD` 篩選該日起的造訪；無命中時 exit 0 且無資料列（滿足 `Read-only query commands for local Safari data`、`Default result limits reflect data sensitivity`、`Filtering options for history and bookmarks`）。驗證：`safari-browser history --limit 5` 印出 ≤5 行且時間落在當前世紀；`safari-browser history --search zzzzznomatchzzzzz` exit 0 且無輸出。
- [x] 2.3 使 `history` 的說明文字（legend、通知、權限指引）一律走 stderr、資料列與 `--json` 一律走 stdout，且無結果時 `--json` 輸出 `[]`（滿足 `Explanatory text is separated from parseable output`、`JSON output for local data query commands`）。驗證：`safari-browser history --limit 3 2>/dev/null` 僅得三行資料列；`safari-browser history --limit 2 --json | python3 -m json.tool` 不報錯。

## 3. 其餘三個來源指令

- [x] 3.1 [P] 實作 `BookmarksCommand`，使 `safari-browser bookmarks` 以 plist 解析器（非 `plutil -convert json`，該路徑實測會失敗）讀出書籤樹與閱讀列表，輸出含所屬資料夾路徑並以 `reading_list` 區分兩者，不設預設筆數上限，`--folder` 對資料夾路徑做大小寫不敏感比對（滿足 `Read-only query commands for local Safari data`、`Default result limits reflect data sensitivity`、`Filtering options for history and bookmarks`）。驗證：`safari-browser bookmarks --json` 為合法 JSON 且項目數等於實機書籤總數（不被截斷）。
- [x] 3.2 [P] 實作 `CloudTabsCommand`，使 `safari-browser cloud-tabs` 在 `CloudTabs.db` 存在時列出各裝置的分頁，在檔案不存在時以 exit code 0 結束、stdout 無資料列（`--json` 為 `[]`）、stderr 印出說明（滿足 `Read-only query commands for local Safari data`、`Full Disk Access failure is distinguished from missing data files`）。驗證：於開發機（實測無此檔）執行 `safari-browser cloud-tabs; echo $?` 得 0，`safari-browser cloud-tabs --json 2>/dev/null` 得 `[]`。
- [x] 3.3 [P] 實作 `DownloadsCommand`，使 `safari-browser downloads` 讀出下載檔名與來源網址，預設 50 筆、可用 `--limit` 覆寫（滿足 `Read-only query commands for local Safari data`、`Default result limits reflect data sensitivity`）。**此來源為四者中唯一未經實測者**：實作時須先確認 `Downloads.plist` 實際結構，若與 design.md 預期不符，以實測為準並回頭更新 design.md 的 Open Questions 段。驗證：`safari-browser downloads --limit 3 --json | python3 -m json.tool` 不報錯且每筆含 `filename` 與 `source_url`。

## 4. 註冊與文件

- [x] 4.1 使四個指令出現在 `safari-browser --help` 的 subcommand 清單中並可被呼叫（滿足 `Read-only query commands for local Safari data`）。註記：此處動到的 `subcommands:` 陣列與 #110 共享，Conflict Class 為 `C_shared_module_coord`，不可與其交錯合併。驗證：`safari-browser --help` 同時含 `history`、`bookmarks`、`cloud-tabs`、`downloads` 四字串。
- [x] 4.2 將四個指令的 interference level 分級（Non-interfering）與其資料敏感度差異寫入 `non-interference` spec，使日後新增讀取持久化資料的指令有先例可循（滿足 `Local data query commands are non-interfering`、`Data sensitivity is recorded separately from interference level`）。驗證：`spectra validate local-safari-data-query` 通過，且 spec 內文同時載明分級與敏感度兩件事。
- [x] 4.3 使 `README.md` 的指令表涵蓋四個新指令並載明其需要「完全取用磁碟」而非 `setup` 處理的三種權限。驗證：內容審查——四個指令名稱與 FDA 需求皆出現，且未宣稱 `setup` 會處理 FDA。

## 5. 驗收

- [x] 5.1 逐項確認 design.md `Implementation Contract` 的八條 acceptance criteria 全部成立，並確認既有測試未因 subcommand 註冊變動而失敗。驗證：`make test-unit` 全綠，八條逐條手動核對並記錄結果。

## 6. 設計決策追溯

本節僅供追溯 design.md 與 tasks 的對應關係，不含待辦項目。

| design.md 段落 | 由哪些 task 落實 |
|---|---|
| Decision 1：FDA 錯誤訊息依 binary 自身簽章狀態分歧，但**不**改變預設安裝方式 | 1.4 |
| Decision 2：`SafariDataStore` 只共用檔案存取，**不**抽象查詢 | 1.1、1.2、3.1–3.3 |
| Decision 3：預設輸出上限依**資料性質**分兩類 | 2.2、3.1、3.2、3.3 |
| Decision 4：時間戳轉換獨立成可測試單元 | 2.1 |
| Decision 5：缺檔是正常結果，不是錯誤 | 1.3、3.2 |
| Behavior | 2.2、3.1–3.3、4.1 |
| Interface | 2.2、3.1–3.3 |
| Data shape（`--json`） | 2.3、3.1–3.3 |
| 預設輸出（非 `--json`） | 2.3 |
| Failure modes | 1.3、1.4、3.2 |
| Acceptance criteria | 5.1 |
| Scope boundaries | 5.1 |

## 7. 後續替代契約與驗證（#111–#117、#120）

本節補充新證據，不回填成 #109 當時已有的測試。

- [x] 7.1 四個指令接記憶體 SQLite／Data parser，新增合成 parser 與實際 `run(sourceURL:)` 測試。`LocalDataParserTests` 紅燈為原程式 12 項測試、11 failures（含 1 unexpected）；更新後 20 項測試全過、沒有略過。涵蓋 Bookmarks 巢狀／無 type 容器與 Reading List、Downloads nil 日期排序、CloudTabs SQLite schema／join、必要欄位全壞與部分壞、History optional 日期／次數 JSON null、合法搜尋落空、accepted-result limit。
- [x] 7.2 補齊 1.3 歷史缺口：四個指令都以實際 command body 執行合成缺檔與 POSIX permission-denied fixture，再使用 ArgumentParser 的 `exitCode(for:)` 判定錯誤。缺檔為 0，FDA 類別拒絕為非 0；JSON／文字 stdout 與通知／警告／legend stderr 分離均有斷言。本機執行非 root，拒絕測試未略過；這不代替 macOS TCC 的人工授權驗收。
- [x] 7.3 Bookmarks 新增 `--search` 的 title／URL Unicode 大小寫不敏感搜尋，與 `--folder` 取交集。實際 command 測試同時驗證 Reading List 在 JSON／文字保留標記，資料夾名稱不被誤當成 search 欄位。

- [x] 7.4 後續實測補正：明確 Bookmark List 缺 `Children` 是正常空資料夾；日期須能以 UTC 及當前 Gregorian 時區的 CE 0001–9999 表示，極端有限值／BCE 不得變成空日期或錯示年代。新增兩項 regression 的原行為紅燈為 2 測試、50 failures（含 1 unexpected）；加入日期邊界測試後，`LocalDataParserTests` 共 23 項全過、沒有略過。7.1 的 20 項數字保留為先前執行紀錄。

記憶體快照一致性、來源錯誤映射、SQLite step 終止與完整整合驗證由 `local-data-correctness/tasks.md` 的 1.1／2.1／2.2 追蹤；不得以此處 parser 測試通過替代 storage／整合證據。原有殘留複本不以名稱前綴自動清理；新方案不產生新的資料磁碟複本。
