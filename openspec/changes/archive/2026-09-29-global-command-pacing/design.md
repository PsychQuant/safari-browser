## Context

#184 的目的是免除批次呼叫者手動插入等待。#182／#186 的截斷 Cauchy 已合併；目前沒有全域 pacing。一般 CLI、isolated MCP hidden wrapper、persistent worker 與 daemon exec 並非同一入口，單在 main 加 sleep 會漏掉呼叫或重複等待。

本設計由 `/idd-all` 的 PR + unattended 流程推進。使用者已於2026-09-29明確選擇「每個步驟後等待」，確認逐步邊界；其餘設計依已記錄的unattended決策推進。

## Goals / Non-Goals

**Goals:** opt-in設定一次即可替一般命令和exec步驟加上有界隨機等待；三種CLI/MCP路徑一致；預設速度、輸出、退出碼與不重播不變；可用單次off覆寫。

**Non-Goals:** 不提供跨程序鎖或全站限速器，不保證避免CAPTCHA，不代替使用者明確wait，不新增daemon wire欄位／版本協商，不改既有抽樣演算法，不新增全域固定seed。

## Decisions

### 環境政策與副作用前驗證

採 `SAFARI_BROWSER_PACING`：未設定、空字串、`off`為關閉，`cauchy`為啟用，其餘值拒絕，大小寫明確。四個可選參數為 `SAFARI_BROWSER_PACING_MIN_MS`、`MAX_MS`、`MEDIAN_MS`、`SCALE_MS`。後三者同樣使用完整 `SAFARI_BROWSER_PACING_` 前綴。預設沿用TruncatedCauchy，max上限3600000ms，不提供全域allow-long-wait。關閉時忽略附屬參數，確保單次off可以解除繼承的錯誤設定。

新增 `CommandPacing` 保存解析後政策、抽樣與可注入的async sleeper。重用 `TruncatedCauchy`／`JitterNanosecondRange`，啟用時在operation前驗參數及抽出本次duration，避免做完副作用才因數值錯誤失敗。每次操作重新用系統亂數抽樣；近乎固定的spread警告沿用原有數值說明，但將wait專用旗標名稱換為此介面的環境鍵，不輸出固定seed介面。

### 共用命令邊界與單次等待

在 `CLIExecution` 提供共用「執行已解析command」helper，一般execute與`MCPWorkerCommand`的inner command都使用它。helper負責sync/async command一致性與pacing；不得遞迴呼叫會轉成exit code的完整execute，避免診斷印兩次或吞掉原始error。

分類：普通public leaf會等待；`ExecCommand`只建立／傳遞政策而不在整批後等待；`WaitCommand`、所有daemon管理leaf、MCP host、root/help、非leaf命令群組與hidden wrapper不等。內部角色以明確型別辨認，不以`shouldDisplay`代替；`TabSwitchCommand`雖因預設子命令而在help中隱藏，仍須驗設定並等待。ArgumentParser解析／validate錯誤發生在helper之前；內建HelpCommand由保留commandName `help`識別並排除，兩者都不解析pacing。hidden wrapper不等，但其inner普通command會等一次。TaskLocal只保存本次命令的政策，作用域結束即還原，不讓persistent呼叫互相污染。

### paced exec預選逐步分派

當本次政策啟用時，`ExecCommand`在任何RPC前跳過整批daemon快速路徑，使用既有SubprocessStepDispatcher。每個子程序繼承client環境、透過共用CLI邊界等待；子命令內的既有daemon router仍可使用暖快取。外層exec不等第二次，skipped step不啟動子程序也不等，明確wait步驟沿既有語意。

政策關閉時原有整批選路不變。這個明確選路不同於錯誤後fallback：不得送出整批後才因缺少pacing資訊重跑。不新增daemon設定欄位，也不讓server啟動時的環境替client決定等待。代價是啟用時多出逐步process／連線成本；相較秒級刻意間隔，保留版本相容與client所有權較有價值。

### 錯誤與取消保留執行結果

已進入operation的普通命令，成功與runtime error後都等待一次。原runtime error在正常等待後原樣拋回；不改stdout、stderr內容與退出碼。`CancellationError`或已取消Task不再開始額外等待；operation前的取消拒絕執行，operation後或sleep中的取消不重跑operation。

若原operation成功而sleep被取消，回報固定診斷指出「pacing interrupted after command execution; earlier effects are not undone」，非零退出；若operation本來已失敗，保留原錯誤而不以sleep錯誤取代。一般CLI既有OS signal termination不攔截。MCP的原有deadline包括等待，不自動延長；README範例要求client timeout包含命令成本及所選max。這也表示命令先完成、等待期間被host timeout仍是既有unknown-outcome，不能重播。

## Implementation Contract

- 新增上述五個環境鍵；無global旗標、無新daemon JSON欄位。啟用後的command輸出與格式不增加pacing metadata；只有無效政策、近固定spread警告或取消診斷寫stderr。
- `CommandPacing` 提供可驗證的prepare／perform邊界與sleep依賴，測試用自有operation與captured durations證明次數、先後及no replay；產品預設使用Task.sleep。
- `CLIExecution` 的共用已解析command helper處理standalone與persistent；`MCPWorkerCommand`保留身分與遞迴防護，再進相同helper。解析error/help不被pacing設定遮蔽。
- `ExecCommand`選路讀本次政策，啟用後不送`exec.runScript`；正常逐步子命令仍保留原shared target args與daemon opt-in。明確off恢復整批快速路徑。
- 驗收必涵蓋：off零sleep、錯設定零operation、sample在operation前、operation後exactly-one sleep、runtime error保留、取消不重播、wait/help/daemon/host/wrapper排除、inner command一次、exec兩個實際步驟兩次而skipped零次、daemon整批RPC零或一的實際觀察、MCP兩模式等價及既有deadline。
- 真實非GUI路徑以`history --limit 0`和`js --file`自有不存在檔案在Safari／資料庫存取前發生的runtime error驗證等待；正向operation使用自有測試command驗證。daemon使用自有socket／fake handler，不能操作使用者Safari或資料。延遲fixture使用小毫秒區間，測試主要依賴注入sleep與事件順序，避免緊繃的牆鐘斷言。
- README／CHANGELOG記錄開關、參數、所有例外、paced exec成本、MCP timeout包含等待與非跨程序限速。

## Risks / Trade-offs

- [漏掉hidden inner command或多等wrapper] → 一份helper、三路整合測試與重複等待變異。
- [舊daemon忽略pacing] → 送出前選逐步路徑，不修改RPC schema。
- [大批次超過既有timeout] → 不延長既有budget，文件說明整批預算包含每步等待；timeout仍可能已有副作用。
- [錯誤遮蔽／隱性重播] → 保存原operation結果，sleep只執行一次；取消後不再執行operation。
- [啟用後吞吐量下降] → 等待是明確opt-in；off零額外sleep、保留原快速路徑。

## Migration Plan

既有呼叫不需要修改。使用者設定環境即可啟用，以單次 `SAFARI_BROWSER_PACING=off` 或移除設定回復；MCP host變更啟動環境後需重啟。不得自動修改使用者shell設定或已安裝binary。

## Open Questions

沒有阻擋本次實作的未決事項。exec逐步邊界已由使用者明確確認；若需求再變更，先ingest規格再調整程式。
