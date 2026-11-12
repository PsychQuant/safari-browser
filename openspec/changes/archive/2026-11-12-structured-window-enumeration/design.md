## Context

`listAllWindows()` 是每個指定目標的指令都會走的路：`documents`（文字與 `--json`）、`tabs`、`tab`、`open`、exec 的 in-process 路徑、native-path resolver（`--url*`、`--window`、`--document`、`--profile`、`--first-match`），以及 `documentNotFound` / `ambiguousWindowMatch` 的清單。它跑 `SafariBridge.listAllWindowsScript`，結果目前是一段文字：每個分頁一筆 `w GS t GS isCur GS url GS title GS winName GS winID RS`。

這段文字有兩條執行路徑：

- **stateless**：`runAppleScript` → `runViaRouter` → `runProcessWithTimeout("/usr/bin/osascript", ["-e", src])`，stdout 以 UTF-8 解碼並去掉結尾一個換行。
- **daemon**：client 送 `applescript.execute`（`DaemonRouter.executeAppleScriptViaDaemon`），daemon 在 `PreCompiledScripts.CompileCache`（`@MainActor`，以 source 文字為鍵的 `NSAppleScript` 快取）執行，回 `descriptor.stringValue`；`exec.runScript` 在 daemon 內以 `DaemonRequestContext.appleScriptRunner`（`Handlers.cachedScriptText`）走同一個快取。

#355 的量測：在真的 Safari 上，`name of tab` 與 `name of window` 都保留 U+001D / U+001E，一個標題就讓 `documents --json` 對 3 個分頁列出 7 列。fac190c 在腳本裡把 28–31 換成 U+FFFD，verify 第一輪量到它是平方時間（`text items of` 對項目數平方；`ignoring diacriticals` 對單一組合字元序列長度平方），維護者因此選擇改成結構化輸出（決定留言，2026-11-09）。

分支：本變更建在 #362 與 #354 之上（`20448a9`）。fac190c 的 handler 整個拿掉；e8eb695 的解析器檢查只保留在結構化資料上仍有意義的部分（見下方「解碼器保留與丟掉的檢查」）；c301a9a 的文件重寫。舊 head 留在本機 ref `backup/355-handler`。

## Goals / Non-Goals

**Goals:**

- 網頁文字只能出現在 AppleScript 字串值裡，任何字元都無法產生、刪除或改變一筆紀錄，也無法改寫 profile 或 window id。
- AppleScript 不對網頁文字做任何逐字元處理；成本與標題長度成線性。
- stateless 與 daemon 兩條路徑對同一個 AppleScript 結果解出相同的值。
- 解碼器失敗即關閉（維護者決定：列舉通不過檢查就讓指令失敗，不丟列），錯誤訊息不含網頁文字（#227）。
- 不增加 Apple event；保留 `WindowEnumerationBatchingTests` 與 `ZeroTabWindowGuardTests` 釘住的意圖（#180 的整批讀取、第二次 URL 讀取以 `considering case` 比較、逐分頁退路；0 分頁視窗佔位；window id、profile、目前分頁）。
- `documents --json` 的鍵與列的形狀不變（Akashic `fulltext fetch` 依賴它）。

**Non-Goals:**

- #363（screenshot 的視窗比對以 U+001F 框住 `name of window`）、#366（`tabURLs(windowID:)` 以 GS 串接分頁網址）、#364（標題含 ` — ` 讓沒有 profile 的視窗冒充 profile）：另案。本變更的 source form 解析器與 descriptor 轉換可以直接拿去修 #363 與 #366（兩者都是「AppleScript 回傳多個字串、Swift 端切開」），但這裡不動它們。
- `ScriptInterpreter.errorCode(for:)` 對新錯誤的對應（exec 腳本裡仍歸為 `appleScriptFailed`）：不在本變更範圍。（列舉失敗時 `runTargetedAppleScript` 的清單已由 #362 改成失敗說明，`windowEnumerationCorrupt` 顯示為「the list came back malformed」。）
- 舊的 GS/RS 文字格式與 4/5/6 欄的舊紀錄相容：移除。新的 client 不會收到舊格式：`applescript.execute` 執行的是 client 送去的新腳本；`exec.runScript` 則由 daemon 用**自己**的程式碼列舉，所以 client 只把 `exec` 腳本送給握手宣告了 `sourceForm` 的 daemon（見「daemon 以握手宣告 source form 能力」）。版本握手只能擋下有 stamp 的不同 build；沒有 stamp 的 build 一律回報 `1.0.0+unknown(source)`，彼此分不出來（#320），能力宣告補上這一點。
- 已排除、不再重開的修法（量過）：把替換切塊、限制組合字元長度、以 `id of` 逐碼點替換。

## Decisions

### 列舉腳本回傳每個視窗一筆的 AppleScript list

腳本改成：

```
set output to {}
repeat with w from 1 to windowCount
    ...
    if tabCount > 0 then
        set currentIdx to index of current tab of window w
        set winName to name of window w
        set winID to id of window w
        （#180 的整批讀取與逐分頁退路，原封不動）
        set end of output to {w, winID, winName, currentIdx, urls, names}
    else
        （winName、winID 以 try 讀，讀不到就是 missing value）
        set end of output to {w, winID, winName, 0, {}, {}}
    end if
end repeat
return output
```

每個視窗一筆，而不是每個分頁一筆：`urls` 與 `names` 本來就是整批讀回的 list，原樣放進紀錄，逐分頁組字串的迴圈整個拿掉；視窗名稱每個視窗只出現一次（舊格式把它寫進該視窗的每一筆，這正是真機量到 4 筆偽造列的原因）。`missing value` 不在腳本裡換成 `""`，交給解碼器，所以腳本對網頁文字完全不碰。沒有視窗時回傳 `{}`，不再是 `""`。

`set end of output to {...}` 而不是 `set output to output & {...}`：後者會把 list 攤平一層。`urls` / `names` 每個視窗都重新賦值（`set urls to {}` 或整批讀取的新 list），已放進 `output` 的 list 不會被之後的 `set end of urls` 改到。

替代方案：保留每分頁一筆、只把欄位改成 list（`{w, t, isCur, url, title, winName, winID}`）。會保留一個沒有用處的逐分頁迴圈，視窗名稱重複 N 次；不採用。

### 線上格式採用 AppleScript source form，兩條路徑各自產生

stateless 路徑以 `osascript -s s -e <script>` 執行，stdout 是 source form。daemon 路徑在 `CompileCache` 內（descriptor 所在的 main actor）把 `NSAppleEventDescriptor` 轉成同一種文字（`AppleScriptSourceForm.render`）。Swift 端只有一個解析器 `AppleScriptSourceForm.parse`。

量測（本機，無 Safari，以 AppleScript 字串常值、`«data utxt…»` 與 `NSAppleScript` 產生值；load average 約 25）：

| 項目 | 結果 |
|---|---|
| `-s s` 的跳脫 | 只跳脫 `"`（`\"`）與 `\`（`\\`）。TAB、LF、CR、U+0000、U+0001–U+001F、U+007F、U+2028、U+200B、組合字元、非 BMP 字元一律原樣輸出 |
| 全 BMP 往返 | U+0000–U+FFFF（除代理區）切成 16 段，加上 emoji ZWJ、國旗、tag、`"`/`\`/GS/RS 後接 U+0301、`x` 後接 1000 個 U+0301 再接 `"`、CR LF TAB NUL：`osascript -s s` → 解析，碼元逐一相同 |
| descriptor 轉換 = `osascript -s s` | 同一份腳本，`NSAppleScript` 執行後轉換的文字與 `osascript -s s` 的 stdout（去掉結尾換行）位元組相同（190,485 bytes） |
| `missing value`、整數、空 list | `missing value`、`42`、`-7`、`{}`、`{{}}` |
| 超過 AppleScript 整數範圍的數 | `2147483647` 印成 `2.147483647E+9`（AppleScript 整數只有 ±2^29），`123456789012` 印成 `1.23456789012E+11`；`3.5`、`true` 原樣 |
| 錯誤訊息 | `-s s` 不改變錯誤輸出：仍是 `execution error: … (-1700)`，`appleScriptErrorCode` 與 dangle 判斷不受影響 |

線性（同一份資料放兩處，字串長度 2^17、2^20、2^23 個單位；單位分別是 `a`、`"\`、U+0301、RS+GS、😀）：

| 單位 | 2^17 | 2^20 | 2^23 |
|---|---|---|---|
| `a`：`osascript -s s` / 解析 / descriptor 轉換 | 0.106 s / 0.000 s / 0.001 s | 0.116 / 0.001 / 0.006 | 0.154 / 0.010 / 0.047 |
| `"\`（最壞跳脫） | 0.115 / 0.003 / 0.003 | 0.188 / 0.026 / 0.021 | 0.770 / 0.204 / 0.188 |
| U+0301 | 0.109 / 0.001 / 0.001 | 0.124 / 0.004 / 0.007 | 0.206 / 0.031 / 0.051 |
| RS+GS | 0.112 / 0.000 / 0.001 | 0.125 / 0.002 / 0.011 | 0.211 / 0.016 / 0.087 |
| 😀 | 0.113 / 0.001 / 0.002 | 0.138 / 0.008 / 0.014 | 0.278 / 0.063 / 0.118 |

每個格子裡 descriptor 轉換的輸出都與 `osascript -s s` 位元組相同。`osascript` 的時間含約 0.1 s 的程序啟動。對照：fac190c 的 handler 在 `x` + 65,536 × U+0301 上要 9–11 s。

替代方案：

- **(b) JXA `JSON.stringify`**（`osascript -l JavaScript`，以 `runScript` 執行同一份 AppleScript 再 `JSON.stringify`）：跳脫正確，孤立代理以 `\ud83d` 保留；2^23 的 `"\` 0.454 s，小輸入比 `osascript -e` 多約 0.05 s 啟動。不採用：daemon 端需要第二個執行引擎（`NSAppleScript` 跑不了 JXA），等於丟掉現有的編譯快取；錯誤訊息的形狀也會變（`Error: …`），#362 的錯誤分類要重寫。
- **(c) daemon 直接走 descriptor 產生 Swift 值**：daemon 與 client 之間仍只能傳字串（`output` 欄位），值還是得序列化；與其另立 JSON 格式，不如序列化成 stateless 本來就產生的 source form，讓解析器只有一個，並能以真的 `osascript` 對照測試。本設計即 (c) 配 (a)。
- **長度前綴**（在 AppleScript 裡寫 `length of tabName`）：AppleScript 的 `length` 數的是組合字元序列（一個基底字加 100,000 個組合符號算 1），與 Swift 的計數單位不保證一致；不採用。

### 孤立代理依 osascript 的規則截斷

`osascript -s s` 對含孤立代理的字串不是整段丟掉：它在 `"` 與 `\` 處把字串切成幾段，每一段在第一個孤立代理處截斷（`A` U+D83D `B` → `"A"`；`"` U+D83D `"` → `"\"\""`；`A` U+D83D U+DE00 `B` U+D800 → `"A😀B"`）。這個規則以 3,000 個隨機字串（字母表：A、B、`"`、`\`、U+D83D、U+DC00、成對的 U+D83D U+DE00、U+0301、RS、LF，長 1–12）對真的 `osascript` 驗證，全部相符。`NSAppleScript` 的 descriptor 保留孤立代理（`41 d83d 42`），所以 descriptor 轉換照同一規則截斷，兩條路徑才會解出相同的值。

截斷發生在引號之內，產生的仍是封閉的字串常值，所以不是偽造紀錄的途徑。

**真機上確實會出現孤立代理**（orchestrator 2026-11-09 以 v2.9.0 量測，issue 留言 6743483662）：Safari 把 `name of tab` 截在 1000 個 UTF-16 單位，`name of window` 是「profile 名稱 + ` — ` + 截過的標題」；截斷不看代理對，所以 `"a" × 999 + 😀` 的標題回來是 999 個 `a` 加一個孤立高代理 U+D83D。v2.9.0 上這一個分頁從 `documents --json` 消失（2 列只剩 1 列，結束碼 0），`--url` 找不到它，而且該視窗每一筆紀錄都沒有 window id，`--window-id` 也找不到整個視窗。

原因已在本機（無 Safari，以 `«data utxt…»` 做出同樣的字串）重現：舊格式把整個列舉串成一個字串，`osascript` 輸出時在第一個孤立代理處截斷**整個字串**。孤立代理第一次出現在第一筆紀錄的視窗名稱欄（視窗名稱帶著目前分頁的標題），所以第一筆紀錄停在視窗名稱之後（6 欄，沒有 window id），之後的紀錄全部消失：舊解析器因此列出 1 列、window id 為 nil。不是 AppleScript 串接或轉型失敗；AppleScript 這邊的字串是完整的（`NSAppleScript` 拿到的 descriptor 仍是 1000 個單位，最後一個是 `d83d`），丟失發生在 osascript 把結果轉成 UTF-8 時。orchestrator 另外量到：AppleScript 的 `id of` 對這種字元回傳 71680 而不是 55357，`character id 55357` 直接 -1700；本變更的腳本不對網頁文字呼叫 `id of`，所以不受影響。

新格式下，同一個標題只影響它自己的字串常值：stateless 路徑 `-s s` 把該段截在孤立代理處，標題成為 999 個 `a`；視窗名稱成為 `個人 — ` 加 999 個 `a`；window id 是另一個元素，不受影響。daemon 路徑照同一規則截斷，結果相同。

**daemon 端不得經過 Swift `String` 取碼元**：量到 `descriptor.stringValue` 轉成的 Swift `String`，其 `utf16` 檢視在這個 1000 單位的字串上已經把 `d83d` 換成 `fffd`（`utf8` 為 `ef bf bd`），只有 `as NSString` 取回原本的 `NSString` 時才還看得到 `d83d`，而這取決於橋接是否保持惰性。所以 `AppleScriptSourceForm.render` 直接讀 descriptor 的 `utxt` 位元組（必要時先 `coerce(toDescriptorType: typeUnicodeText)`），不經過 `String`。

ASSUMPTION: 依「兩條路徑解出相同結果」的要求，daemon 路徑刻意照 osascript 的規則丟掉孤立代理（以及同一段裡它之後的字元），而不是換成 U+FFFD。`"a" × 999 + 孤立高代理` 的標題在兩條路徑都顯示為 999 個 `a`。這個規則由對照真 `osascript` 的測試釘住，Apple 若改變 osascript 的行為，測試會失敗。

### 只有被要求時 daemon 才轉成 source form

client 在 `applescript.execute` 的 params 加 `"resultForm": "sourceForm"`，daemon 才轉換；沒有這個欄位時照舊回 `stringValue`。其他腳本的輸出不受影響（它們不回傳 list，但「看到 list 就轉換」會讓兩條路徑對同一份腳本的行為取決於結果型別，不如明說）。`resultForm` 有出現但不是字串 `"sourceForm"` 時，handler 回 `status: error`（`errorKind: badRequest`），client 當成 AppleScript 失敗，不 fallback。

in-process 的 `exec.runScript` 另外裝一個 `DaemonRequestContext.appleScriptSourceFormRunner`（與 `appleScriptRunner` 由同一個 helper 一起裝）。`SafariBridge.runAppleScriptSourceForm` 依序找：source form runner → `appleScriptRunner`（測試假 Safari 走這裡，它們自己回 source form 文字）→ router（daemon 帶 `resultForm`，stateless 用 `-s s`）。生產環境只在 `exec.runScript` 裝 runner，而兩個一起裝；萬一只裝了 `appleScriptRunner`，它回的是 list 的 `stringValue`（量過是 nil → `""`），解碼器拒絕空字串，指令失敗而不是列出零個視窗。

### daemon 以握手宣告 source form 能力

**Supersedes**: structured-window-enumeration / 只有被要求時 daemon 才轉成 source form（verify 第二輪加入的「空回覆送出後重跑」）

握手**不**保證 daemon 認得 `resultForm`：有 stamp 的 build 以 commit 區分、dirty build 永遠不相符，但沒有 stamp 的 build（純 `swift build`、沒有 `.git` 的原始碼封存）一律回報 `1.0.0+unknown(source)`，#304 之前的已安裝 release 不論有沒有戳記也宣告同一個身分，所以 #355 之前的這兩種 daemon 都會通過握手（#320）；實際最可能遇到的是已安裝的舊 release。它不認得 `resultForm`，照舊回 list 的 `stringValue`（`""`）；更糟的是 `exec.runScript`：它在 daemon 內用舊的 GS/RS 列舉跑完整份腳本，回的是正常結果，client 完全看不出來（verify 第三輪 F2/F4/F6）。

所以 daemon 在 v2 握手的 `protocol` 物件加一個選用欄位 `capabilities`（字串陣列），這個 build 宣告 `["sourceForm"]`，做法比照 #202 的 `maxRequestLineBytes`：舊 daemon 沒有這個欄位、舊 client 忽略它；欄位存在但不是字串陣列時握手無效。client 在版本檢查之後、寫出任何請求位元組之前檢查：帶 `resultForm: "sourceForm"` 的 `applescript.execute` 與所有 `exec.runScript` 都需要 `sourceForm`。沒有宣告就丟 `DaemonClient.Error.missingCapability`，它是送出前的錯誤，fallback 行寫「the running daemon predates sourceForm (#355); run `safari-browser daemon stop` and then `safari-browser daemon start` to replace it」（沒有任何東西會自動啟動 daemon，與 `DaemonProtocol.mismatchNote` 的說法一致）：source form 請求由 router 改走 `osascript -s s`，`exec` 改成逐步以子行程執行。每一步是獨立的指令，自己的請求自己檢查能力，所以 `exec` 會印一行（被擋下的 `exec.runScript`），再加上每個要列舉視窗的步驟各一行。能力檢查排在 #202 的請求大小檢查之前：對沒有能力的 daemon，超量的 `exec` 改成逐步執行，而不是 `requestTooLarge`。能力清單是功能宣告，不是呼叫端身分驗證，不改變「IPC trust model — filesystem permissions only」。

第二輪的「daemon 回空字串就送出後重跑」拿掉了：現在送出之前就知道 daemon 認不認得，送出之後不再重跑任何東西，也就不再需要「source form 只用於唯讀腳本」這個前提。宣告了能力的 daemon 若仍回空字串，那是錯誤：空字串交給解碼器，解碼器拒絕（`windowEnumerationCorrupt`），不印 fallback 行。

`resultForm` 有出現但不是字串 `"sourceForm"`（其他字串、數字、布林、null）時，handler 回 `status: error`、`errorKind: badRequest`（verify 第二輪 F18：原本非字串的值被當成沒有這個欄位）。

### 解碼器保留與丟掉的檢查

`decodeWindowEnumeration(_:)` 取代 `parseWindowEnumeration(_:)`，並且會丟錯。檢查（任何一項不過就丟 `windowEnumerationCorrupt`）：

1. 輸出能以 source form 解析，且整體是一個 list（空字串不行；沒有視窗是 `{}`）。
2. 每一項是 6 個元素的 list。
3. 第 1 個元素是整數，等於它在 list 中的位置（1, 2, 3, …）。
4. window id 是整數或 `missing value`（→ nil）；winName 是字串或 `missing value`（→ `""`）。
5. currentIdx 是整數；`urls`、`names` 是 list，長度相同，元素都是字串或 `missing value`（→ `""`）。
6. 分頁數為 0 時 currentIdx 必須是 0；大於 0 時 currentIdx 至少是 1。
7. 不是 nil 的 window id 不重複。

分頁數大於 0 而 currentIdx **大於**分頁數時不丟錯（verify 第二輪 F5/F7/F9；第三輪 F7 把範圍收窄成只放行大於分頁數：有分頁時 `index of current tab` 不會小於 1，小於 1 是腳本產生不了的清單，仍然失敗）：在 `count of tabs` 與 `index of current tab` 兩次讀取之間開新分頁並成為目前分頁（Cmd+T、頁面的 `window.open`），currentIdx 會是分頁數 + 1，整批讀取因長度不符而不穩，逐分頁退路只讀到原本的分頁。這個視窗照樣列出所有分頁，沒有目前分頁（每個 `isCurrent` 為 false），`currentTabIndex` 為 0。不能是 1：解析器在 `--window-id W --tab-in-window 1` 等處以 `currentTabIndex == tab` 判斷要不要切換分頁，誤當 1 是目前分頁就會不切換，動作落在真正的目前分頁上。#355 之前（v2.9.0）舊解析器在這種情況同樣沒有標目前分頁、照樣列出視窗，但把 `currentTabIndex` 設為 1，正有這個問題；所以對使用者而言的變化是 `--window-id W --tab-in-window 1` 與 `.resolvedTab` 現在會切到 tab 1。`--profile` 下 `--window-id` 的未命中清單，這種視窗顯示 `(unknown)`（只有沒有分頁的視窗才是 `(0 tabs)`）；`documents` 圖例不再說每個視窗都有一個 `*`。`documents` 不標 `*`、`is_current` 全為 false；`--window N` 單獨使用時仍指該視窗（每個 Apple event 當下的目前分頁）；錨定目標（`anchoredCurrentTab`）用自己的錨定腳本讀目前分頁，不讀 `currentTabIndex`。

重複的 window id 仍然失敗即關閉。視窗穩定時腳本不會產生它；列舉途中開啟或提起視窗時會：同一個視窗在兩個 z-order 位置被讀到，失敗比把列配給錯的視窗好（關閉視窗則讓 `count of tabs of window w` 丟 -1719，是 `appleScriptFailed`，不是這個錯誤）。`windowEnumerationCorrupt` 的建議依原因分三種（verify 第三輪 F8/F17，`WindowEnumerationProblem`）：重複的 window id 說視窗在讀取途中改變、再執行一次；window id 是實數（`.real`：osascript 的 `3.5`／`5.36870912E+8` 與 daemon 轉換的 `«class doub»`；id 達 2^29 就變成實數）說明 AppleScript 整數的上限是可能的原因，不建議重跑（verify 第四輪 F8/F9：只限實數，布林、原始資料、`«class …»`、字串、list 都屬形狀問題）；其他原因說清單讀不出來、再執行一次、一直失敗才回報。`WindowEnumerationDecoderTests.testTheMessageMatchesTheReason` 斷言三種文字。

e8eb695 的檢查裡，「超過 7 欄」「同一個位置出現兩次」「視窗編號倒退」「分頁編號不從 1 連續」「同一視窗的紀錄對名稱或 id 不一致」在新格式下不可能發生（位置由 list 的順序決定、名稱與 id 每個視窗只出現一次），所以丟掉；「長度不同」「id 不是整數」改成上面第 4、5 項；verify 第一輪提到的 window id 唯一性（第 7、8 項發現）加成第 7 項。舊解析器對「少於 4 欄」「位置不是整數」的紀錄靜默丟棄的容忍也一併移除：新格式沒有這種紀錄，任何不符形狀的東西都讓指令失敗。

錯誤訊息只寫位置、數量與型別（例如 `window 2 has 3 URLs and 4 titles`、`item 4 of window 1 is not an integer`），不寫字串內容。原子（數字、`missing value` 以外的 bareword、`«…»`）的文字不進訊息，所以 `osascript -s s` 印的 `3.5` 與 descriptor 轉換印的 `«class doub»` 會得到同一個錯誤。

### 錯誤沿用 windowEnumerationCorrupt

恢復 e8eb695 的 `SafariBrowserError.windowEnumerationCorrupt(reason:)`，說明改寫（不再說「分隔字元會被換成 U+FFFD」）。恢復 6c07d65 拿掉的四處：`enumerationFailureNote` 的種類「the list came back malformed」、`EnumerationFailureNoteTests` 的那組案例與不含原因文字的斷言、CHANGELOG #362 那一行的「a malformed list」、`document-targeting` 規格那一句。

### 測試假資料由單一 helper 產生

`Tests/SafariBrowserTests/FakeEnumeration.swift` 提供 `FakeEnumeration.sourceForm(_ windows: [FakeEnumeration.Window])`，自己實作跳脫（只跳脫 `"` 與 `\`），不呼叫產品的轉換器，當作獨立的對照；一個測試確認 helper 的輸出 = descriptor 轉換的輸出 = 真 `osascript -s s` 的輸出。所有以 GS/RS 假造列舉的測試改用它；`WindowPinFakeSafari.isEnumeration` 仍以 `set windowCount to count of windows` 認出列舉腳本，所以腳本保留這一行。

## Implementation Contract

**行為**

- `listAllWindows()` 回傳的 `[WindowInfo]` 與舊版在「標題、網址、視窗名稱不含 U+001C–U+001F」時相同：`windowIndex`、`currentTabIndex`（0 分頁視窗為 1；有分頁而目前分頁索引大於分頁數時為 0，沒有分頁標為目前；有分頁而索引小於 1 則失敗）、`tabs`（`tabIndex` 1…n、`url`、`title`、`isCurrent`）、`profile`（由視窗名稱解析）、`windowID`。含這些字元時，值原樣保留（不再換成任何東西），列數等於真實分頁數。
- `documents --json` 的鍵、列的形狀與順序不變。
- 解碼器拒絕的輸出讓指令以 `windowEnumerationCorrupt` 失敗（非零結束碼），訊息不含任何標題、網址或視窗名稱，建議依原因而定（見「解碼器保留與丟掉的檢查」）。握手沒有宣告 `sourceForm` 的 daemon 收不到 source form 請求與 `exec` 腳本：每個被擋下的請求印一行 `[daemon fallback: …]`（含 `safari-browser daemon stop` 與 `safari-browser daemon start`）；`exec` 印一行給被擋下的 `exec.runScript`，每個要列舉視窗的步驟再各一行，`--window N --profile P` 在父行程以 `pinWindowAtStart` 列舉時也再一行；改走 stateless／逐步執行。

**介面**

- `SafariBridge.listAllWindowsScript`：回傳 `{{w, winID, winName, currentIdx, urls, names}, …}`；0 分頁視窗 `{w, winID, winName, 0, {}, {}}`；沒有視窗 `{}`。
- `SafariBridge.decodeWindowEnumeration(_ text: String) throws -> [WindowInfo]`。
- `SafariBridge.runAppleScriptSourceForm(_ script: String, timeout: TimeInterval) async throws -> String`。
- `AppleScriptValue`（`list` / `text` / `integer` / `real` / `missingValue` / `other`）、`AppleScriptSourceForm.parse(_:) throws -> AppleScriptValue`、`AppleScriptSourceForm.render(_ descriptor: NSAppleEventDescriptor) -> String`。
- daemon：`applescript.execute` params 可帶 `"resultForm": "sourceForm"`；`ExecutionResult` 多一個 `sourceForm: String?`（只在被要求時算）；`DaemonRequestContext.appleScriptSourceFormRunner`。

**驗收**

- 不需 Safari 的測試：parse 的單元測試；descriptor 轉換與真 `osascript -s s` 位元組相同（全 BMP、孤立代理、整數、`missing value`、巢狀 list；位元組相同只對列舉會回傳的這幾種值成立，實數、布林、原始 `utf8`/`TEXT` 資料兩條路徑寫法不同，但實數兩邊都解成 `.real`、其餘都解成 `.other`（daemon 端原始 `doub` 資料也會解成 `.real`，與 `«data long…»` 同屬分不出來的例外），整數型別的原始資料 `«data long…»` 在 daemon 端與整數分不出來）；以 AppleScript 常值做出含 GS/RS、`"`、`\`、CR、LF、組合字元的視窗清單，經兩條路徑解出相同的 `[WindowInfo]`、列數等於分頁數；解碼器每一項檢查各一個測試；`""` 被拒絕；`applescript.execute` handler 帶 `resultForm` 的輸出等於 `osascript -s s`；in-process helper 同時裝好兩個 runner；腳本能編譯；結構釘選改寫後仍釘住同樣的意圖。
- 10^5 / 10^6 字元的成本為線性（本文件的表）。
- 完整 `swift test` 通過；每個新加的檢查各拿掉一次，指出會失敗的測試。
- 真 Safari 驗收（偽造標題的 fixture 重讀、長標題）由 orchestrator 執行，本變更不碰 Safari。

**範圍**

- 在內：列舉腳本、解碼器、source form 解析與轉換、兩條路徑的接線、錯誤、測試假資料、文件。
- 不在內：#363、#364、#366、#369（text-mode 輸出的控制字元跳脫）；exec 的錯誤碼對應。

## Risks / Trade-offs

- [`osascript -s s` 的格式是觀察到的行為，不是文件化的契約] → 對照真 `osascript` 的測試（全 BMP、孤立代理、各種值）在每次 `swift test` 都跑；Apple 若改變格式，測試失敗而不是靜默解錯。解析器對看不懂的東西失敗即關閉。
- [daemon 路徑照 osascript 規則截斷孤立代理，丟掉資料] → 兩條路徑一致比保留資料更重要（同一個 `--url` 在兩條路徑選到同一個分頁）；截斷不會跨出引號。記錄在本文件。
- [`stringValue` 為 nil 的 list 在接線遺漏時變成 `""`] → 解碼器拒絕空字串；in-process 的兩個 runner 由同一個 helper 安裝並有測試。
- [輸出變大：`"` 與 `\` 變兩個位元組，外加引號與逗號] → 線性。daemon 路徑上，頁面控制的每個反斜線在 wire 上佔 4 bytes（source form 寫成 `\\`，daemon 的 JSON 回覆再加倍；舊格式是 2 bytes），所以 #174 的 128 MiB 回覆上限大約在 32 Mi 個反斜線碰到，餘裕約為舊格式的一半。網址不截斷，頁面可用 `location.hash` 放原始反斜線；Safari 能否保留這麼長的網址沒有量過。超過上限時 daemon 路徑是結果未知、不 fallback（#174），stateless 路徑不受影響。
- [不合法的 window id（實數、字串）以前降級成 nil，現在讓指令失敗] → 真的 Safari 回整數；0 分頁視窗讀不到 id 時是 `missing value`，仍是 nil。符合「通不過檢查就失敗」的決定。AppleScript 的整數只到 ±(2^29 − 1)：window id 達到 2^29（536,870,912）就變成實數（`osascript -s s` 印 `5.36870912E+8`，descriptor 轉換印 `«class doub»`），兩條路徑都解成 `.real`，整個列舉失敗；以前 `Int("5.36870912E+8")` 為 nil，視窗只是沒有 id。Safari 的 window id 實際上很小，記錄在此以免這個代價發生時看不出原因。
- [Safari 截斷標題時切開代理對，產生孤立代理] → 新格式下只影響該字串；兩條路徑丟掉同一個碼元；以 `«data utxt…»` 做出同樣字串的測試釘住（`WindowEnumerationTransportTests`）。
- [真 Safari 上沒跑過新腳本] → 結構釘選 + 編譯檢查 + 兩條路徑的對照測試；真機驗收留給 orchestrator。

## Migration Plan

沒有資料遷移。有 stamp 的 build 之間，執行中的舊 daemon 因版本不符而 fallback 到 stateless，stateless 用新格式。沒有 stamp 的 build 分不出新舊（#320），但舊 daemon 的握手沒有 `capabilities`：client 不把 source form 請求與任何 `exec.runScript`（不論步驟會不會列舉視窗）送給它，每個被擋下的請求印一行 `[daemon fallback: …]`，指向 `safari-browser daemon stop` 再 `safari-browser daemon start`，改走 stateless／逐步執行；不需要能力的其他請求（例如 `exec` 逐步執行時各步驟的文字形式 `applescript.execute`）照舊由它服務。沒有任何指令會自動啟動 daemon：只靠 socket 存在而啟用 daemon 的人，`daemon stop` 之後就一直走 stateless；設了 `SAFARI_BROWSER_DAEMON=1` 或 `--daemon` 的人則每次多一行 `connect:` fallback，直到 `daemon start`。回退即還原本變更的 commit。

## Open Questions

- 已由 orchestrator 量到（2026-11-09，v2.9.0）：Safari 把 `name of tab` 截在 1000 個 UTF-16 單位、`name of window` 是 profile 名稱加 ` — ` 加截過的標題；網址不截斷（500,043 字元的網址完整回來，百分比編碼不變，沒有原始控制字元）。所以 10^5 / 10^6 的線性要求對網址仍然重要，對標題則上限約 1000 單位。截在代理對中間的標題見「孤立代理依 osascript 的規則截斷」。
- 修正後的真機驗收（偽造標題 fixture、長標題、截在代理對中間的標題）由 orchestrator 執行。
