## 1. 槽與框架

- [x] 1.1 Per-call result slot（「一個頁面物件，一個名稱」與「名稱由誰取」）：ResultSlot 的名稱（CLI 取、頁面取並以 isValid 驗證）、存入、長度、錯誤、清除腳本；ResultSlotTests 驗證名稱形狀、注入字元被拒、兩個槽互不干擾。
- [x] 1.2 Checked chunk transfer（「分塊回覆的形狀」）：讀取腳本與 parseFrame；surrogate pair 與結尾換行在塊邊界、損壞的框架被拒、按 scalar 解析。
- [x] 1.3 FakePage：在 JavaScriptCore 裡真的執行 CLI 送出的腳本，頁面狀態跨呼叫共用，模擬 runner 與 daemon 對回覆結尾的處理。

## 2. 指令

- [x] 2.1 「整體結果的最後一個換行」與「讀取：每次都分塊」：SafariBridge.doJavaScriptLarge／readResultSlot，自己做的槽在成功、空結果與失敗時都移除；ResultSlotIsolationTests 在讀取中途讓另一個呼叫存入。
- [x] 2.2 JSCommand／JSWrapper：`--large` 的包裝與哨兵改用槽，`SB1:BIG` 帶頁面取的名稱，不合格的名稱不讀、不重跑；ResultSlotCommandTests。
- [x] 2.3 GetCommand：帶 selector 的後備直接把運算式交給分塊讀取；ResultSlotGetTests。
- [x] 2.4 「孤立 surrogate」：存入前 `toWellFormed()`，換成 U+FFFD，不報錯。

- [x] 2.5 「包裝不在使用者的範圍裡宣告變數」：`storeScript` 把運算式當引數、大型包裝的 catch 不宣告變數、內嵌的命名放在自己的函式裡，且不依賴頁面的時鐘與亂數；ResultSlotShadowingTests。
- [x] 2.6 「導頁」與 `--output keeps its file when there is no result`：`runLargePath` 回傳 `String?`，沒有結果時 `--output` 失敗並保留原檔；頁面在長度讀取與第一塊之間被換掉時網址不同就是導頁；ResultSlotCommandTests。
- [x] 2.7 「逾時後不清除」：`SafariBridge.removeResultSlot` 在逾時之後不再多等一個逾時；ResultSlotCommandTests。
- [x] 2.8 Execution evidence for the code `--large` and `--output` run（「執行證據」，#257 B2 後半、#260）：包裝在使用者的程式碼之前標記槽、catch 先設 `threw` 再記錄訊息（切短、三步保護）；`runLargePath` 依 `progressScript`（未開始／丟了錯／已開始／不在）決定要不要試另一種形式、要不要再執行，並且只送本機編得過的那一種形式；ResultSlotExecutionEvidenceTests（含換頁時點矩陣）、JSWrapperTests、ResultSlotTests。
- [x] 2.9 「仍然成立的限制（記錄，不是已解決）」：先丟錯再導頁、頁面被換掉但程式碼其實沒跑、`--url` 的有界重新解析、`SB1:BIG` 的第二次嘗試，寫進 design.md；先丟錯再導頁有測試釘住。

## 3. 驗證與交付

- [x] 3.1 變異測試：60 個變異（腳本不在 repo 內；有些重疊），每個都有具名測試失敗；過程中三次有變異存活（結尾標記檢查、槽在程式碼之前建立、塊尾以外的缺口），各補了測試後全部被殺；執行證據的變異包含標記、`threw`、讀取順序、解析嚴格度與只送一種形式。
- [x] 3.2 「daemon」：確認沒有改 daemon，記錄快取壓力的理由（design.md 的 Risks）；完整單元測試 2082 項中 1 項失敗（`MCPIsolatedBootstrapTests`，在 `origin/main` 與 #256 的 head 上同樣失敗，與本變更無關，另開 issue）、smoke 74/74；四位獨立審查者（協議與安全、行為等價與測試、文件誠實度、對照 #192 的反方），發現已處理或記錄。
- [ ] 3.3 真 Safari 驗收（#257 的 B4）：**部分完成**。已做：兩個同時執行的 `js`（`--large` 與內嵌 BIG 各 20 輪）、34 個大型結果案例對照 `main` 與 #256、頁面全域遮蔽、時鐘與亂數被替換、`--output` 導頁、`window` 上殘留的屬性。沒做：`get text`／`snapshot`／`exec` 與其他呼叫的真機交錯、原始 #190 情境（未重現）、daemon 模式的大型結果、使用者在讀取途中切分頁。
