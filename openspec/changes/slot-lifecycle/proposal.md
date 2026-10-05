## Problem

每個呼叫把大型結果存進頁面的 `window.__sbr_<名稱>`，結束時盡力刪除（#190、#261）。呼叫被強制終止、被取消、逾時，或頁面在清除前失效時，刪除不會發生，整份結果文字留在頁面直到頁面卸載。固定名稱時代下一個呼叫會覆蓋它，最多留一份；現在每個孤兒各留一份，大小同結果。反覆中斷大型讀取的長期開啟分頁（SPA）會累積。目前沒有任何回收機制，規格寫的是「槽留到頁面導走，已知，追蹤於 #193」。

## Root Cause

槽的命名每個呼叫唯一（為了不讀到別人的結果），所以沒有下一個呼叫會「剛好覆蓋」孤兒；而 CLI 端在行程被殺之後沒有任何機會再清。頁面端沒有記錄槽何時最後被用過，也就沒有安全回收的依據。

## Proposed Solution

槽帶一個最後使用時間 `u`（毫秒，`Date.now()`）。建立時寫入，每次讀取（長度、錯誤、進度、每一塊）更新。任何呼叫**建立新槽時**，順便刪除頁面上以 `__sbr_` 開頭、且 `u` 是數字、且早於保留期限（10 分鐘）的槽。進行中的呼叫每次往返都更新 `u`（往返間隔是亞秒），所以不會被刪；沒有 `u` 的槽（舊版 CLI 建的）不動；頁面時鐘被改寫或拋錯時只會不回收，不會讀到錯的資料。全部寫在既有的腳本裡，不增加任何 `do JavaScript` 往返。

## Non-Goals

- 不做頁面內計時器（`setTimeout` 到期自清）：每個呼叫在頁面留一個計時器、背景分頁被節流、頁面可改寫 `setTimeout`，閉包若持有槽會把大文字多留一個期限。
- 不做 CLI 端日誌（記錄槽名、下次執行時清）：要在檔案系統留狀態，跨分頁與跨 profile 對不上，清不到已換頁的舊槽。
- 不做「只依名稱前綴全部刪除」：會刪到仍在讀取的並行呼叫。
- 不做筆數上限（LRU）：突發的並行呼叫超過上限時會刪到進行中的。
- 不保證「一定回收」：回收發生在下一個建立大型結果槽的呼叫，不是計時器；之後若沒有任何大型呼叫，孤兒留到頁面卸載。

## Success Criteria

- 孤兒槽（建立後未清除）在下一個建立槽的呼叫、且距其最後使用超過 10 分鐘時被刪除；未超過時保留。
- 進行中的槽（最後使用在期限內，含分塊讀取的每一塊）不被另一個呼叫的掃描刪除；兩個並行呼叫互不影響。
- 沒有 `u` 的槽、不以 `__sbr_` 開頭的屬性、`u` 不是數字的槽，一律不動。
- 頁面把 `Date.now` 換成常數、拋錯或回傳非數字時：呼叫照常完成，掃描不刪任何東西。
- 一般 `js`、大型路徑與內嵌大結果路徑的 `do JavaScript` 往返次數不變；回覆協定（`SB1:*`、塊格式）不變。
- 規格寫明回收時點、期限、受保護對象與限制。

## Impact

- Affected code: `Sources/SafariBrowser/ResultSlot.swift`（`presetScript`、`storeScript`、`lengthScript`、`errorScript`、`progressScript`、`readScript`；新增 `sweepStatement`、`touch`、保留期限常數）、`Sources/SafariBrowser/Commands/JSWrapper.swift`（`inlineTail` 的大結果分支）
- Affected tests: `Tests/SafariBrowserTests/`（新增 `ResultSlotRetentionTests`；`FakePage` 無需改動，頁面時鐘由測試以 `Date.now = …` 控制）
- Affected specs: `js-execution`（修改 Per-call result slot）
- Affected docs: `CHANGELOG.md`、`CLAUDE.md`（#190 條目的「孤兒槽」句子）
