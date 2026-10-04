## 1. 槽與框架

- [x] 1.1 Per-call result slot（「一個頁面物件，一個名稱」與「名稱由誰取」）：ResultSlot 的名稱（CLI 取、頁面取並以 isValid 驗證）、存入、長度、錯誤、清除腳本；ResultSlotTests 驗證名稱形狀、注入字元被拒、兩個槽互不干擾。
- [x] 1.2 Checked chunk transfer（「分塊回覆的形狀」）：讀取腳本與 parseFrame；surrogate pair 與結尾換行在塊邊界、損壞的框架被拒、按 scalar 解析。
- [x] 1.3 FakePage：在 JavaScriptCore 裡真的執行 CLI 送出的腳本，頁面狀態跨呼叫共用，模擬 runner 與 daemon 對回覆結尾的處理。

## 2. 指令

- [x] 2.1 「整體結果的最後一個換行」與「讀取：每次都分塊」：SafariBridge.doJavaScriptLarge／readResultSlot，自己做的槽在成功、空結果與失敗時都移除；ResultSlotIsolationTests 在讀取中途讓另一個呼叫存入。
- [x] 2.2 JSCommand／JSWrapper：`--large` 的包裝與哨兵改用槽，`SB1:BIG` 帶頁面取的名稱，不合格的名稱不讀、不重跑；ResultSlotCommandTests。
- [x] 2.3 GetCommand：帶 selector 的後備直接把運算式交給分塊讀取；ResultSlotGetTests。
- [x] 2.4 「孤立 surrogate」：存入前 `toWellFormed()`，換成 U+FFFD，不報錯。

## 3. 驗證與交付

- [x] 3.1 變異測試：每個保護被移除時至少一個具名測試失敗。
- [ ] 3.2 「daemon」：確認沒有改 daemon，記錄快取壓力只在少見路徑的理由；完整單元與 smoke 測試、獨立審查。
- [ ] 3.3 真 Safari 驗收（#257 的 B4）：原始 #190 情境、傳輸行為清單、不同路徑交錯呼叫、`SB1:BIG` 的往返次數與耗時。需要使用者的空檔。
