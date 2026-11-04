## 1. 旗標與驗證（TDD：先寫失敗的測試）

涵蓋 requirement「Target a window by its stable id」的旗標、互斥與值域部分。

- [ ] 1.1 `--window-id <W>` 是 `TargetOptions` 的選項；與 `--window`、`--url`、`--url-exact`、`--url-endswith`、`--url-regex`、`--tab`、`--document` 同時給時，`validate()` 以點名雙方的錯誤拒絕；`--tab-in-window` 可配 `--window` 或 `--window-id`；值小於 1 拒絕。驗證：`WindowIDTargetingTests` 的 validation 測試（每一組互斥、`--tab-in-window` 單獨仍要求 `--window` 或 `--window-id`、0 與負數）
- [ ] 1.2 `TargetOptions.hasExplicitTarget` 計入 `--window-id`（以及原本漏掉的 URL 旗標仍在其中）；`resolve()` 對 `--window-id W` 回 `.windowID(W)`，配 `--tab-in-window T` 回 `.resolvedTab(windowID: W, tabInWindow: T, rematch: nil, profile:)`。驗證：resolution 單元測試斷言回傳的 `TargetDocument`

## 2. `TargetDocument.windowID` 的解析

涵蓋 requirement「Target a window by its stable id」的解析與 fail closed；design「`--window-id` 的 `TargetDocument`：新增 `.windowID(Int)`，非同步錨定時轉成 `.anchoredCurrentTab`」與「profile 檢查放在解析時」。

- [ ] 2.1 新增 `TargetDocument.windowID(Int)`，`resolveDocumentReference` 回 `document of window id W`；其餘 switch 處逐一處理（參照一律 `window id W`，不出現 `front window` 或位置）。驗證：參照字串的單元測試，以及以 fake `appleScriptRunner` 跑 `get url --window-id 4711` 與 `click --window-id 4711 <sel>`，斷言送出的 AppleScript 含 `window id 4711`、不含 `front window`
- [ ] 2.2 `resolveToAnchoredTarget` 遇到 `.windowID(W)` 以 `readWindowAnchor(windowID: W)` 轉成 `.anchoredCurrentTab`；讀不到 → `documentNotFound`。驗證：fake runner 讓 anchor 讀不到時 `js --window-id 9999 "1"` 以 `No Safari document matches` 失敗，且沒有送出任何 `do JavaScript`
- [ ] 2.3 native resolver（`pickNativeTarget`）以 id 找視窗：找到 → 那個視窗；找不到 → `documentNotFound`，不退回 front window。驗證：`pickNativeTarget(.windowID(...), in:)` 的純函式測試（找到、找不到、零分頁的視窗）
- [ ] 2.4 `--window-id W --profile P`：W 不屬於 P 時以 `documentNotFound` 失敗，訊息不列別的 profile 的分頁網址；屬於時照常解析。驗證：以 fake 列舉（兩個 profile 的視窗）的測試，涵蓋 `.windowID` 與 `.resolvedTab` 兩種形狀

## 3. `open`

涵蓋 requirement「Open URL in new tab」與「Open with a window id names a target」；design「`open` 的三條路」。

- [ ] 3.1 [P] `open`（非 `--new-tab`）以 `TargetOptions.hasExplicitTarget || profile != nil` 判斷有沒有指定目標：`open --window-id W <url>` 導航那個視窗的目前分頁，`open --url-endswith S <url>` 導航符合的分頁（safari-browser#233），都不開新分頁。驗證：fake runner 測試斷言送出的是 `openURL` 的導航腳本（`window id` 參照），沒有 `make new tab`
- [ ] 3.2 [P] 由 `local/351`（`b5ab06b`）帶入 `SafariBridge.NewTabWindow` 與 `openURLInNewTabScript`，加 `activate` 開關：`--window-id W` → `tell window id W`、無 `activate`、仍 `set current tab`；`--window N` → 先 `set _w to id of window N` 再 `activate` 再 `tell window id _w`；無目標 → front window 照舊。驗證：腳本文字測試與 `NSAppleScript` 編譯測試（三種形狀都編得過）
- [ ] 3.3 `open --new-tab --profile P [--window k]` 以 `resolveNativeTarget` 回傳的 `windowID` 建分頁（`.id`，保留 `activate`）；沒有 id 時退回 `.index(<全域編號>)`；解析不出一個視窗時失敗。`--new-tab` 的驗證接受 `--window`、`--window-id`、`--profile`，拒絕其他目標旗標（訊息列出可用的三個）。驗證：fake 列舉＋fake runner 的測試，斷言腳本是 `tell window id <列舉時的 id>`，以及驗證錯誤的測試

## 4. exec 與 `documents`

涵蓋 requirement「Machine-readable JSON output」與「Target a window by its stable id」的 exec scenario；design「exec」「`documents --json`」。

- [ ] 4.1 [P] exec：`CommandDispatch` 的允許旗標含 `--window-id`，`ScriptInterpreter` 重組參數時帶上它；in-process 與 subprocess 兩條路對 `--window-id` 解析出相同目標。驗證：exec 的參數重組測試與 in-process dispatcher 測試
- [ ] 4.2 [P] `documents --json` 每列加最上層 `window_id`（與 `blocking_dialog.window_id` 同值，讀不到為 `null`），其餘欄位不變。驗證：`documents --json` 的序列化測試（有 id、無 id 各一）

## 5. 文件與驗收

- [ ] 5.1 CHANGELOG（Unreleased）、`CLAUDE.md` 的 multi-window 段落、`--window-id` 的 `--help` 說明：寫明 `--window-id` 的語意、與 `--window N` 的差別、`open --url-endswith` 行為改變（#233）、#351 已含在內。驗證：內容檢查，`safari-browser --help` 與 `safari-browser get --help` 出現 `--window-id`
- [ ] 5.2 全套測試通過（`swift test`），新增保護各做一次 mutation（拿掉互斥、拿掉 profile 檢查、`.windowID` 退回 front window、`--window-id` 時加回 `activate`、`open` 的 `hasExplicitTarget` 漏算），每個都有具名測試抓到。驗證：`swift test` 結果與 mutation 紀錄
- [ ] 5.3 真機驗收（需維護者同意開分頁）：多個視窗、Safari 不在前景時，`open --new-tab --window-id W` 開在視窗 W、不搶前景；`get url --window-id W` 讀到 W 的目前分頁。驗證：真機紀錄寫進 issue；未獲同意時在 Implementation Complete 照實標為未做
