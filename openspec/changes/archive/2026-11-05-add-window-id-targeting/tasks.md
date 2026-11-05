## 1. 旗標與驗證（TDD：先寫失敗的測試）

涵蓋 requirement「Target a window by its stable id」的旗標、互斥與值域部分。

- [x] 1.1 `--window-id <W>` 是 `TargetOptions` 的選項；與 `--window`、`--url`、`--url-exact`、`--url-endswith`、`--url-regex`、`--tab`、`--document` 同時給時，`validate()` 以點名雙方的錯誤拒絕；`--tab-in-window` 可配 `--window` 或 `--window-id`；值小於 1 拒絕。驗證：`WindowIDTargetingTests` 的 validation 測試（每一組互斥、`--tab-in-window` 單獨仍要求 `--window` 或 `--window-id`、0 與負數）
- [x] 1.2 `TargetOptions.hasExplicitTarget` 計入 `--window-id`（以及原本漏掉的 URL 旗標仍在其中）；`resolve()` 對 `--window-id W` 回 `.windowID(W)`，配 `--tab-in-window T` 回 `.windowID(W, tabInWindow: T)`（verify 第二輪起；原文的 `.resolvedTab` 見第 7 組）。驗證：resolution 單元測試斷言回傳的 `TargetDocument`

## 2. `TargetDocument.windowID` 的解析

涵蓋 requirement「Target a window by its stable id」的解析與 fail closed；design「`--window-id` 的 `TargetDocument`：新增 `.windowID(Int)`，非同步錨定時轉成 `.anchoredCurrentTab`」與「profile 檢查放在解析時」。

- [x] 2.1 新增 `TargetDocument.windowID(Int)`，`resolveDocumentReference` 回 `document of window id W`；其餘 switch 處逐一處理（參照一律 `window id W`，不出現 `front window` 或位置）。驗證：參照字串的單元測試，以及以 fake `appleScriptRunner` 跑 `get url --window-id 4711` 與 `click --window-id 4711 <sel>`，斷言送出的 AppleScript 含 `window id 4711`、不含 `front window`
- [x] 2.2 `resolveToAnchoredTarget` 遇到 `.windowID(W)` 以 `readWindowAnchor(windowID: W)` 轉成 `.anchoredCurrentTab`；讀不到 → `documentNotFound`。驗證：fake runner 讓 anchor 讀不到時 `js --window-id 9999 "1"` 以 `No Safari document matches` 失敗，且沒有送出任何 `do JavaScript`
- [x] 2.3 native resolver（`pickNativeTarget`）以 id 找視窗：找到 → 那個視窗；找不到 → `documentNotFound`，不退回 front window。驗證：`pickNativeTarget(.windowID(...), in:)` 的純函式測試（找到、找不到、零分頁的視窗）
- [x] 2.4 `--window-id W --profile P`：W 不屬於 P 時以 `documentNotFound` 失敗，訊息不列別的 profile 的分頁網址；屬於時照常解析。驗證：以 fake 列舉（兩個 profile 的視窗）的測試，涵蓋 `.windowID` 與 `.resolvedTab` 兩種形狀

- ASSUMPTION（實作時決定，verify 時請挑戰）：
  - `TargetDocument.windowID` 帶一個可選的分頁序號（`windowID(Int, tabInWindow: Int? = nil)`），`--window-id` 一律解析成它。`.resolvedTab` 在各處都被當成已驗證過，驗證之後才收斂（第 7 組）。
  - 不在本表的三處也改了，否則 `--window-id` 會被安靜地丟掉：`tabs`（自己由 `--window` 組目標；現在 `--window-id` 走解析器，且 `--url-exact`／`--url-endswith`／`--url-regex` 也和 `--url` 一樣被拒，以前是被忽略）、`screenshot` 的本地 `hasExplicitTarget`（只加 `--window-id`；URL 旗標的同類缺口是 #233）、`wait` 的 `--url` 改名提示。

## 3. `open`

涵蓋 requirement「Open URL in new tab」與「Open with a window id names a target」；design「`open` 的三條路」。

- [x] 3.1 [P] `open`（非 `--new-tab`）以 `TargetOptions.hasExplicitTarget || profile != nil` 判斷有沒有指定目標：`open --window-id W <url>` 導航那個視窗的目前分頁，`open --url-endswith S <url>` 導航符合的分頁（safari-browser#233），都不開新分頁。驗證：fake runner 測試斷言送出的是 `openURL` 的導航腳本（`window id` 參照），沒有 `make new tab`
- [x] 3.2 [P] 由 `local/351`（`b5ab06b`）帶入 `SafariBridge.NewTabWindow` 與 `openURLInNewTabScript`，加 `activate` 開關：`--window-id W` → `tell window id W`、無 `activate`、仍 `set current tab`；`--window N` → 先 `set _w to id of window N` 再 `activate` 再 `tell window id _w`；無目標 → front window 照舊。驗證：腳本文字測試與 `NSAppleScript` 編譯測試（三種形狀都編得過）
- [x] 3.3 `open --new-tab --profile P [--window k]` 以 `resolveNativeTarget` 回傳的 `windowID` 建分頁（`.id`，保留 `activate`）；沒有 id 時退回 `.index(<全域編號>)`；解析不出一個視窗時失敗。`--new-tab` 的驗證接受 `--window`、`--window-id`、`--profile`，拒絕其他目標旗標（訊息列出可用的三個）。驗證：fake 列舉＋fake runner 的測試，斷言腳本是 `tell window id <列舉時的 id>`，以及驗證錯誤的測試

## 4. exec 與 `documents`

涵蓋 requirement「Machine-readable JSON output」與「Target a window by its stable id」的 exec scenario；design「exec」「`documents --json`」。

- [x] 4.1 [P] exec：`CommandDispatch` 的允許旗標含 `--window-id`，`ScriptInterpreter` 重組參數時帶上它；in-process 與 subprocess 兩條路對 `--window-id` 解析出相同目標。驗證：exec 的參數重組測試與 in-process dispatcher 測試
- [x] 4.2 [P] `documents --json` 每列加最上層 `window_id`（與 `blocking_dialog.window_id` 同值，讀不到為 `null`），其餘欄位不變。驗證：`documents --json` 的序列化測試（有 id、無 id 各一）

## 5. 文件與驗收

- [x] 5.1 CHANGELOG（Unreleased）、`CLAUDE.md` 的 multi-window 段落、`--window-id` 的 `--help` 說明：寫明 `--window-id` 的語意、與 `--window N` 的差別、`open --url-endswith` 行為改變（#233）、#351 已含在內。驗證：內容檢查，`safari-browser --help` 與 `safari-browser get --help` 出現 `--window-id`（實作時更正：頂層 `--help` 只列子指令、不列任何目標旗標，改以 `safari-browser get url --help` 與 `open --help` 驗證）
- [x] 5.2 全套測試通過（`swift test`），新增保護各做一次 mutation（拿掉互斥、拿掉 profile 檢查、`.windowID` 退回 front window、`--window-id` 時加回 `activate`、`open` 的 `hasExplicitTarget` 漏算），每個都有具名測試抓到。驗證：`swift test` 結果與 mutation 紀錄
- [ ] 5.3 真機驗收（需維護者同意開分頁）：多個視窗、Safari 不在前景時，`open --new-tab --window-id W` 與 `tab new --window-id W` 開在視窗 W、不搶前景；`get url --window-id W` 讀到 W 的目前分頁；#351 的原始情境（`open --new-tab --window 1` 與 `--profile P`，三次都開到別的視窗）重跑一次；`open --window-id <不存在>` 回 `No Safari document matches`；`open --window-id W --tab-in-window 99` 回 `No Safari document matches`；`open --window-id W` 在空白分頁或 Favorites 分頁、以及載入中的頁面上能導航（`get name of <ref>` 不會擋住）；`make new tab` 與 `set current tab` 打在不存在的 id 回什麼碼（`runNewTabScript` 靠 -1728／-1719 翻譯，都還沒在真機量過）。驗證：真機紀錄寫進 issue；未獲同意時在 Implementation Complete 照實標為未做
  - 2026-11-05 狀態：**未做**。真機驗收要在維護者的 Safari 開分頁，本次 session 未取得同意；以 fake runner 與 `NSAppleScript` 編譯測試涵蓋腳本形狀，多視窗、Safari 不在前景時的實際行為仍未證明。

## 6. verify 第一輪的修正（2026-11-05）

- [x] 6.1 `tab <N>`／`tab new`／`tab focus` 接受並使用 `--window-id`（HIGH：原本被丟掉、改用前景視窗）；`tab` 帶 `--profile` 時用列舉讀到的 id；`tab new --window N` 先讀 id 再 `activate`；`tab` 拒絕所有指名分頁的旗標。驗證：`WindowIDRound2Tests` 的 tab 測試
- [x] 6.2 `open --new-tab --window-id <不存在>` 在送出前以 `documentNotFound` 失敗；`open --window-id W <url>` 沒有視窗時不建新視窗。驗證：`WindowIDRound2Tests` 的 open 測試
- [x] 6.3 `js`／`wait` 的 target-changed 訊息以 id 指名 `--window-id` 目標；anchor 讀不到的訊息不再斷言「視窗不存在」。驗證：`WindowIDRound2Tests` 的 js／wait 測試
- [x] 6.4 `--window-id` 配 `--profile`、而該 profile 沒有開著的視窗時，錯誤不列其他 profile 的分頁；零分頁視窗與 profile 路徑上 `--tab-in-window` 越界的測試補上。驗證：`WindowIDRound2Tests`
- [x] 6.5 spec：修正「目前分頁在開頭讀一次」「不讀其他視窗」兩句；以 MODIFIED delta 改主 spec 中與本變更衝突的 requirement（document-targeting 的旗標分組與 `--tab-in-window`、navigation 的 Open URL in current tab、tab-management 的兩個 requirement）；proposal 明列「`--window N` 一律在開頭解析成 id」與 focus-existing 的 raise 路徑不在範圍內。驗證：`spectra validate`
- [x] 6.6 文件：`--help`、README、CHANGELOG、CLAUDE.md、`TargetOptions` 開頭註解、`save-pdf` 訊息不再宣稱 `close`／`screenshot`／`pdf`／`upload --native` 以 id 動作；CHANGELOG 寫明 #351 的修正尚未在真機多視窗下跑過，以及 `open --new-window`／`tab` 新增的拒絕。驗證：內容檢查

## 7. verify 第二輪的修正（2026-11-05，維護者授權第 3 輪）

- [x] 7.1 `--window-id W --tab-in-window T` 一律解析成 `.windowID`：`open` 沒有視窗時不建新視窗，`tab focus` 與 native 路徑檢查分頁範圍。驗證：`WindowIDRound3Tests` 的 open 與 tab focus 測試
- [x] 7.2 `js`／`wait`／`save-pdf` 開頭以 id 確認視窗與分頁存在，不存在或越界 → `documentNotFound`，沒有送出 JavaScript。驗證：`testAMissingWindowOrTabIsATargetingMissForJSWaitAndSavePDF`
- [x] 7.3 `--window-id W --profile P` 不把列舉當下的分頁序號固定下來，仍是視窗的目前分頁。驗證：`testAWindowIDWithAProfileStaysTheWindowsCurrentTab`
- [x] 7.4 找不到 id 不列舉、不列別的視窗，提示指向 `documents --json`；檢查之後才關掉的視窗：`tab`、`tab new`、`open --new-tab` 回 `documentNotFound`，`--profile` 的翻譯只列該 profile。`open --window-id` 導航成功才 `activate`。驗證：`WindowIDRound3Tests`
- [x] 7.5 spec：script-exec、pdf-cache、save-pdf、tab-management〈List all tabs〉的 MODIFIED delta；navigation 的 scenario 與 new-tab 文字；document-targeting 的「其他指令」與 native 上傳路徑的封閉列舉；design、proposal（含 #305）。驗證：`spectra validate`
- [x] 7.6 文件：CHANGELOG（`tab --profile` 的舊行為寫錯、exec 句刪除）、README、CLAUDE.md（三處舊句）、`--help`、pdf-cache 與 save-pdf 的 help。驗證：內容檢查

## 8. verify 第三輪的修正（2026-11-05）

- [x] 8.1 `concreteTarget` 對視窗層級的解析有 id 就回 `.windowID`：`open --profile`、`get text`、`get html`、`save-image`、`upload` 不再依位置重查（Blocking，#351 Expected）。驗證：`testAProfileAloneKeepsTheEnumerationsWindowID`
- [x] 8.2 `open --window-id` 導航前先 `get id of window id W`，缺視窗回 `documentNotFound` 而不是 -10006（Blocking）；帶 `--profile` 收斂成 `.resolvedTab` 時同一支腳本。Fake 依真機量到的 -10006 改寫。驗證：`testOpenWithAMissingWindowIDIsATargetingMiss`
- [x] 8.3 沒有 `--profile` 時 miss 不列任何視窗。驗證：`testAMissOnTheEnumeratingPathsListsNoOtherWindow`
- [x] 8.4 `tab focus`、`tabs` 把檢查後才關掉的視窗回報為 targeting miss；`tabs` 拒絕 `--tab-in-window`；hint 依列表內容決定；native resolver 的列表守住 carried profile。驗證：`WindowIDRound4Tests`
- [x] 8.5 spec：document-targeting〈Document not found〉、document-listing〈Discovery aid〉、wait〈Wait for URL pattern〉的 MODIFIED delta；navigation 的無視窗文字與 URL 旗標 miss；pdf-cache 的 profile 註記。驗證：`spectra validate`
- [x] 8.6 文件：還原誤刪的 CLAUDE.md #21 那行；README 的 window-level 段落；CHANGELOG 收窄、真機註記涵蓋全部、不列沒有發布過的 bug。驗證：內容檢查

## 9. 第四輪 verify（縮小版）的修正（2026-11-05）

- [x] 9.1 `open` 導航前讀參照本身（`get name of <ref>`），不是只讀視窗：`--tab-in-window` 指到不存在的分頁時回 `documentNotFound`。驗證：`testOpenWithAMissingTabIsATargetingMiss`
- [x] 9.2 `--profile` 收斂成 `.resolvedTab` 的目標走同一支腳本。驗證：`testOpenWithAProfileAndATabChecksTheTargetAndActivatesLast`
- [x] 9.3 撤掉 `announceUnprobed`：探測在腳本之前跑，分不出失效的 id 與活著的視窗，靜音會連有效視窗一起靜音。失效的 id 前面會多一行 dialog 探測警告，呼叫端比對 stderr 時要跳過 `⚠` 開頭的行。驗證：`testAWindowIDKeepsTheProbeWarning`
- [x] 9.4 `tab focus` 比照 `tab <N>`，以 `checkWindowID` 判斷視窗是否還在，不靠錯誤碼。Fake 把 `set current tab` 也當 -10006（假設，未量）。驗證：`testTabFocusReportsAWindowClosedAfterTheCheckAsATargetingMiss`
- [x] 9.5 lost `.resolvedTab` 的列表在該 profile 沒有視窗時據實說明。驗證：`testALostResolvedTabWithNoWindowOfItsProfileSaysSo`
