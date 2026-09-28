## 1. 環境政策與副作用前驗證

- [x] 1.1 為`command-pacing`的Explicit environment policy、One bounded delay at the command boundary建立行為RED及受保護分支的Regression測試：off忽略附屬錯值、enabled非法數值／分布／奈秒／1小時上限拒絕、sample失敗零operation、成功／錯誤的prepare→operation→sleep順序與exactly-once。
- [x] 1.2 實作`CommandPacing`環境政策與副作用前驗證，重用TruncatedCauchy／JitterNanosecondRange、系統亂數與可注入sleep；設定錯誤不回顯未解析的環境值，off不配置sampler或sleep；以1.1的政策與順序測試轉GREEN驗收。

## 2. 共用命令邊界與單次等待

- [x] 2.1 為Explicit exemptions and wrapper ownership及Consistent callers and documented scope建立行為RED及受保護分支的Regression測試：普通sync／async command、Exec容器、Wait、daemon管理、host、hidden wrapper／inner、help／parse error以及persistent政策作用域還原。
- [x] 2.2 在CLIExecution加入共用已解析命令執行helper，接上一般execute與MCPWorkerCommand的inner路徑；保留image／遞迴驗證、diagnostic與trace作用域，實現共用命令邊界與單次等待；以2.1分類、次數與作用域測試轉GREEN驗收。
- [x] 2.3 針對「錯誤與取消保留執行結果」與Cancellation never replays an operation完成RED/GREEN與變異：operation前取消零副作用、成功後sleep取消的固定非零診斷、原runtime error優先、取消不延長MCPdeadline且不重跑operation。

## 3. paced exec預選逐步分派

- [x] 3.1 以自有daemon handler／socket及不接觸Safari的`js --file`不存在檔案fixture驗證Daemon-routed execution when available：enabled零batch RPC並逐步分派、off恢復單一batch RPC；兩個實際step各等一次、條件略過step與外層零等待。先建立能失敗的觀察斷言。
- [x] 3.2 修改ExecCommand，在任何RPC前依本次pacing政策預選逐步分派；保留target傳遞與每步daemon opt-in，關閉時保留整批最佳化，不新增RPC欄位或執行後fallback；以3.1的實際RPC計數與逐步事件測試轉GREEN驗收。

## 4. 文件與跨呼叫端驗證

- [x] 4.1 更新README／CHANGELOG，完整列出五個環境鍵、毫秒預設與限制、off覆寫、排除項、paced exec成本、MCP timeout包含每步等待、非跨程序限速及不保證避免CAPTCHA；逐項對照command-pacing spec與實際環境解析器做文件內容審查。
- [x] 4.2 執行真實非GUIstandalone／isolated MCP／persistent MCP案例，以`history --limit 0`或自有不存在JS檔案在資料庫／Safari操作前產生runtime error，確認結果不變、啟用確有界等待與off／help不等；以自有command補正向成功證據。
- [x] 4.3 做必要變異：移除等待、wrapper多等、設定延後到operation後、paced exec仍送batch、取消後重跑；每個變異以行為測試失敗證明並還原。
- [x] 4.4 跑受影響單元／公開MCP／exec／daemon回歸與完整非GUI檢查；記錄實際執行、跳過、計時餘裕與環境，不宣稱GUI或出版商驗收。

## 5. 驗證與交付

- [ ] 5.1 固定來源，執行六方獨立驗證、逐項對照#184與兩份delta specs，修正阻擋發現並確認來源新鮮度；公開Implementation Complete與Verify紀錄及tasks來源。
- [ ] 5.2 Spectra analyze／validate／archive，機械核對兩份正式spec更新並建立Refs #184的PR，核對PR來源與已驗證快照；外部合併狀態依下方交付追蹤驗收。

## 交付追蹤

PR合併與合併樹一致由IDD最後Delivery comment及Current Status逐項核對，仍是本題交付要求。這項外部狀態不預先勾選，也不以本tasks全勾替代實際merge證據；避免為了先合併含有本檔的PR而預先宣稱該PR已合併。Issue保留OPEN／verified。
