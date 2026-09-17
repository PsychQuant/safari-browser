## 1. 獨立元件

- [x] [P] 1.1 實作 Opt-in bounded request timing、Timing excludes operation contents、Timing contexts remain isolated；先以實際 baseline CLI 重現缺少 trace，再以 deterministic clock／sink 測成功、錯誤、巢狀、並行隔離、上限與晚到結果。
- [x] [P] 1.2 實作 Reproducible performance benchmark；用 fake executables／protocol fixtures 先重現缺少統計／隔離／SKIP 行為，驗證 bounded stderr、process-group cleanup、nearest-rank 分位數及資料最小化，不執行 Safari GUI。

## 2. 整合

- [x] 2.1 將 request-local trace 接入 CLI、目標解析、router／程序、AX worker；用實際 CLI on/off、錯誤與 stdout 對照證明 Opt-in bounded request timing／Timing contexts remain isolated，保持操作只執行一次。
- [x] 2.2 整合 Optional daemon timing preserves execution semantics，驗證兩個並行請求、cache hit／compile、malformed／missing metadata、exec envelope 與 MCP worker 不重播／不污染其他請求。

## 3. 驗證與交付

- [x] 3.1 執行 Reproducible performance benchmark 的真實安全情境；記錄 baseline、on/off 開銷、cold／warm 條件及 GUI SKIP／驗收，撰寫使用說明與判讀，不宣稱未證實加速倍數。
- [ ] 3.2 執行完整回歸、Spectra validate／analyze、六方審查；修正阻擋項，更新 #167 與 PR，通過後依既有授權合併並核對合併樹。
