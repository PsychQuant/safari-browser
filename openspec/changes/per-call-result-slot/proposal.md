## Problem

#190 記錄 `js --large --output` 曾成功寫出前一批的結果（位元組相同、結束碼 0）。原事件沒有重現，機制未證實。PR #192 以正式 `JSCommand` 加 JavaScriptCore 重現了一個相關的機制：一個呼叫在另一個呼叫的存入與讀取之間把結果存進同一個頁面，兩者共用全域名稱，先到的就讀到後到的資料。

## Root Cause

結果太大、無法在一次 `do JavaScript` 的回覆裡帶回時，指令把它存進頁面的 `window.__sbResult` 與 `window.__sbResultLen`（`js --large`、`SB1:BIG`、`get text`、`get html`、`snapshot`、`exec` 的 in-process 步驟），再分塊讀回。這兩個名稱對同一個頁面上的所有呼叫是同一組。存入、讀長度、讀每一塊、清除是不同的往返，沒有任何東西確認讀到的是自己存的。分塊讀取還有一個獨立的缺口：一塊的結尾若是換行，runner 會把它拿掉；daemon 路徑會把所有結尾空白拿掉；一塊若切在 surrogate pair 中間，兩半都會被 osascript 丟掉。這些都靜默地縮短結果。

## Proposed Solution

每個呼叫把結果存進自己的槽，`window.__sbr_<name> = { text, len, err }`，名稱只有這個呼叫知道，讀完就刪。每一塊回覆的形狀是 `<end>:<text>` 加一個結尾標記，讀取端逐塊檢查位置、長度與標記，任何一項不符就是錯誤，不把殘缺的結果當作結果。存入前把孤立 surrogate 換成 U+FFFD。

這是 #257 的決議：#256 先合併（結果不經頁面的路徑歸它），本 change 在其上只處理仍存進頁面的路徑，取代 #192 的做法；#192 的一般路徑狀態機不再需要（內嵌回覆不經頁面）。

## Success Criteria

- 兩個呼叫交錯時，每個呼叫讀到自己的結果。
- 一塊遺失、被截斷或被改動是明確的錯誤，不是較短的結果。
- 一個呼叫自己做的槽，在成功、空結果與失敗時都被移除；別的呼叫的槽不被動到。
- 結尾空白、結尾換行、surrogate pair 在塊的邊界上完整。
- 內嵌的 `js` 包裝文字不隨呼叫變動，daemon 的編譯快取對最常見的指令仍然有效。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `js-execution`: 新增大型結果的逐呼叫歸屬與完整性要求。

## Impact

- Sources/SafariBrowser/ResultSlot.swift（新增）
- Sources/SafariBrowser/SafariBridge.swift（`doJavaScriptLarge`、`readResultSlot`）
- Sources/SafariBrowser/Commands/JSCommand.swift、JSWrapper.swift、GetCommand.swift
- Tests/SafariBrowserTests/FakePage.swift（新增：在 JavaScriptCore 裡真的執行 CLI 送出的腳本）、ResultSlot*Tests.swift（新增）

## 與 #192 與 #257 的差別（刻意的，細節見 design.md）

沒有帶過來：一般路徑的 prepared／running／done／error 狀態機、協作式取消的檢查點、daemon 的暫時編譯（ephemeral）政策與新 RPC、孤立 surrogate 報錯（B7 決定換成 U+FFFD）。

**#257 B2 的後半有做，但形狀不同**：仍存進頁面而且執行使用者程式碼的路徑（`js --large`／`--output`）有執行證據，但不是四個狀態，而是在槽上加一個 `started` 標記，加上槽本來就有的結果與錯誤；回覆遺失而網址沒變時不再執行第二次，丟出的值不論是什麼都是錯誤（#260）。

`--output` 在程式碼導頁後保留原檔並失敗，**有**帶（審查指出以前把檔案截成零位元組、結束碼 0，真機重現）。
