## 1. 先寫測試（RED）

- [x] 1.1 新增 `Tests/SafariBrowserTests/ResultSlotRetentionTests.swift`：在 `FakePage` 上以 `Date.now = function(){ return T }` 控制頁面時鐘，涵蓋規格 `Per-call result slot` 需求的每個情境：孤兒在期限後被下一個建槽的呼叫刪除（內嵌 `SB1:BIG` 路徑、`storeScript` 路徑、`--large` 的 `presetScript` 路徑各一）、未到期限的保留、分塊長讀取每一塊更新 `u` 後仍保留、兩個並行呼叫互不影響、沒有 `u`／`u` 非數字／非前綴屬性不動、時鐘為常數／拋錯／非數字時掃描不刪任何東西且呼叫照常完成
- [x] 1.2 確認這些測試現在失敗（孤兒不被回收、槽沒有 `u`）

## 2. 實作

- [x] 2.1 `ResultSlot.swift`：新增 `retentionMilliseconds = 600_000`、`touchStatement`（在 `try` 裡取時鐘，是有限數字才寫 `s.u`）、`stampExpression` 與 `sweepExpression`（走訪 `Object.keys(window)`，名稱前綴、值是物件、`u` 是有限數字且夠舊都成立才 `delete`，整段包在 `try`）
- [x] 2.2 `presetScript` 與 `storeScript` 在建立槽時先掃描、再寫 `u`；`lengthScript`、`errorScript`、`progressScript`、`readScript` 在既有 `var s = …` 之後各更新 `u`，回傳值與 `readScript` 的拒絕條件不變
- [x] 2.3 `JSWrapper.inlineTail` 的大結果分支：先掃描、再寫 `window[k] = { text: r, len: r.length, u: <stampExpression> }`；回覆協定不變
- [x] 2.4 確認 1.1 的測試全綠，且 `JSCommandRoundTripTests` 的往返計數、`ResultSlot*Tests`、`JSInlineProtocolTests` 不變

## 3. 驗證與文件

- [x] 3.1 變異檢查：移除 `u` 的更新、移除期限比較、改成前綴全刪、拿掉值是物件的檢查、拿掉 `u` 是數字的檢查、拿掉時鐘的有限數字檢查、三個建槽點各自不掃描、內嵌分支不寫時間戳，各自至少一個具名測試失敗
- [x] 3.2 完整單元與 smoke；daemon 模式下同一組情境與無 daemon 結果一致
- [x] 3.3 `CHANGELOG.md` 一條；`CLAUDE.md` 的 #190 條目把「孤兒槽留到頁面導走」改成有界回收與其限制（含時鐘前跳與自擁槽路徑的空結果）；`SafariBridge.removeResultSlot` 的說明；`docs/performance.md` 無需動
- [x] 3.4 真機量測：掃描在全域屬性數千個的頁面上的成本，與反覆中斷大型讀取後 `window` 上 `__sbr_` 屬性的數量。結果：每次掃描約 0.095 ms（約 5,200 個 `window` 屬性）；`kill -9` 三個讀 3000 萬字元結果的行程留下 3 個槽，時鐘撥快 700 秒後的下一個大結果呼叫 `main` 留 3、本變更 0，撥快後才產生的 2 個孤兒保留，慢讀與快讀同時進行都完整（自己的 127.0.0.1 fixture 分頁，使用者閒置，視窗事後與事前一致）
