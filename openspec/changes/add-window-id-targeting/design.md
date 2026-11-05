## Context

`--window N` 是視窗的前後順序。`TargetDocument` 內部已有以視窗 id 錨定的兩個 case：`.resolvedTab(windowID:tabInWindow:rematch:profile:)`（參照 `tab T of window id W`，#79）與 `.anchoredCurrentTab(windowID:tabInWindow:profile:)`（#180：每一步在同一段 AppleScript 裡檢查該序號仍是那個視窗的目前分頁）。`SafariBridge.readWindowAnchor(windowID:)`（`SafariBridge.swift:453`）以一次往返讀出視窗 id 與目前分頁序號，且確認 id 相符。缺的只是使用者層的旗標。

`open --new-tab` 另走 `SafariBridge.openURLInNewTab`：v2.8.0 先 `activate`、再 `tell window N`，`--profile` 時 `OpenCommand.profileWindow()` 經 `resolveToConcreteTarget` 得到 `.windowIndex(<全域編號>)`——`concreteTarget`（`SafariBridge.swift:369`）只在知道分頁序號時才回 `.resolvedTab`，視窗層級的解析把列舉時已有的 id 丟掉。本機 commit `b5ab06b`（#351）已加了 `NewTabWindow`（`.front`／`.index`／`.id`）與可測的 `openURLInNewTabScript`，其中 `.index(N)` 在 `activate` 之前讀 `id of window N`；它對 `--profile` 的病因說明是錯的（`.resolvedTab` 對應永遠走不到，見 #351 更正），程式碼可沿用、對應要改。

## Goals / Non-Goals

**Goals:**

- `--window-id W` 在所有組合 `TargetOptions` 的指令上可用，單獨使用或配 `--tab-in-window`。
- 視窗 id 不存在、或不屬於 `--profile` 指定的 profile 時一律失敗，不退回 `front window`。
- `open --new-tab` 的三種指定方式（`--window-id`、`--window`、`--profile`）都以視窗 id 建分頁；`--window-id` 時不 `activate`。
- exec 的 in-process 與 subprocess 路徑對 `--window-id` 行為相同。
- `documents --json` 每列有最上層的 `window_id`。

**Non-Goals:**

- `close`、`screenshot`、`pdf`、`upload --native`（#353）。
- 分頁身分（#188）、`--window N` 多視窗警告（#287）、不帶 `--window-id` 時的 `activate`（#350）。

## Decisions

### `--window-id` 的 `TargetDocument`：新增 `.windowID(Int)`，非同步錨定時轉成 `.anchoredCurrentTab`

- 30 個指令檔直接呼叫同步的 `TargetOptions.resolve()`（`grep -rln "target.resolve()"`），單獨的 `--window-id` 需要讀 Safari 才知道目前分頁序號，同步的 `resolve()` 給不出 `.anchoredCurrentTab`。要它們全部改走非同步入口，等於改 30 個檔案。
- **採用**：新增 `TargetDocument.windowID(Int)`，`resolveDocumentReference` 回 `document of window id W`——它本身就以 id 錨定，同步呼叫端不必改。`--window-id W --tab-in-window T` 回 `.windowID(W, tabInWindow: T)`。`.resolvedTab` 在各處都被當成已驗證過，使用者的旗標不產生它：驗證之後才收斂（verify 第二輪：直接回 `.resolvedTab` 時，`open` 沒有視窗仍建新視窗，`js`／`wait`／`save-pdf` 把不存在的 id 報成 target changed）。
- 非同步錨定入口 `resolveToAnchoredTarget`（`js`、`wait`、`save-pdf`）遇到 `.windowID(W)` 時以 `readWindowAnchor(windowID: W)` 轉成 `.anchoredCurrentTab`，套上 #180 的每步目前分頁檢查；遇到 `.windowID(W, T)` 時以 `readTabAnchor(windowID: W)` 確認視窗與分頁存在後轉成 `.resolvedTab`；讀不到或越界 → `documentNotFound`，之後的遺失才是真的 target changed。這是討論結論的做法，只用在已經是非同步錨定的那條路。
- 其他 switch 處（共 9 處）照 `.windowIndex` 的寫法處理 `.windowID`，但參照一律是 `window id W`；native resolver（`pickNativeTarget`）以 id 找視窗，找不到 → `documentNotFound`，不退回 front window。
- 取捨：多一個 case 要逐處處理；換來 30 個同步呼叫端不動，且每個參照都以 id 錨定。

### profile 檢查放在解析時

`--window-id W --profile P`：以 `listAllWindows()` 的結果找 id W 的視窗，比對它的 `profile`；找不到 → `documentNotFound`，profile 不符 → `documentNotFound`（訊息說 window W 不屬於 P，不印別的 profile 的分頁；P 沒有開著的視窗時也一樣）。檢查之後目標仍是視窗的目前分頁（`document of window id W`），不把列舉當下的分頁序號固定下來，與 `--window N --profile` 相同。原因：`resolveToConcreteTarget` 對 `.resolvedTab` 直接回傳、不檢查 profile（`SafariBridge.swift:337`），不能依賴它。

### `open` 的三條路

- `OpenCommand` 的本地 `hasExplicitTarget` 加 `target.windowID != nil`。改成直接用 `TargetOptions.hasExplicitTarget || profile != nil`，並讓 `TargetOptions.hasExplicitTarget` 計入 `--window-id`，一次修掉 safari-browser#233 的同類缺口（`--url-exact`／`--url-endswith`／`--url-regex` 也因此被計入）。這會改變 #233 描述的行為：`open --url-endswith S <url>` 從「開新分頁」變成「導航符合的分頁」，與 spec「targeting flag 指定要改哪個分頁」一致；記在 CHANGELOG。
- `--new-tab`：驗證允許 `--window`、`--window-id`、`--profile`（及其組合 `--profile`＋`--window`），其他目標旗標拒絕。`--window-id W` → `NewTabWindow.id(W)`，腳本不含 `activate`，仍 `set current tab to newTab`。`--window N`（無 profile）→ `.index(N)`（`b5ab06b` 的腳本：先讀 id 再 `activate`）。`--profile P [--window k]` → 以 `resolveNativeTarget`（它回 `ResolvedWindowTarget`，含 `windowID`）取得 id → `.id`；沒有 id（舊列舉）→ `.index(<全域編號>)`。
- `.id` 時 `activate` 的取捨：只有 `--window-id` 不 `activate`（維護者裁決）；`--profile` 走 `.id` 時保留 `activate`，維持現有使用者看到的行為。`NewTabWindow` 加一個 `activate: Bool`。

### exec

`CommandDispatch` 的允許旗標清單加 `--window-id`；`ScriptInterpreter` 的參數重組加 `options.windowID`。in-process 路徑的目標解析與單一指令共用同一個 `TargetOptions`，無需另寫。

### `documents --json`

在每列物件加 `"window_id"`，值取自列舉時的 window id（與 `blocking_dialog.window_id` 同源），沒有時為 `null`。純加欄位，既有欄位不動。

## Implementation Contract

- `safari-browser get url --window-id <W>`：W 存在 → 印那個視窗目前分頁的網址；不存在 → 非零結束、`No Safari document matches` 開頭的錯誤，沒有列舉視窗，提示指向 `documents --json` 而不是 `--window N`。舊版 binary 對這個旗標回 ArgumentParser 的 unknown option（結束碼 64）——呼叫端（Akashic `fetch`）拿它當唯讀的能力檢查。
- `open --new-tab --window-id <W> <url>`：腳本是一段 AppleScript，`tell window id W` 內 `make new tab` 並設為目前分頁，**不含** `activate`；W 不存在時腳本失敗，不建任何分頁。
- `open --new-tab --window <N> <url>`：腳本先 `set _w to id of window N`，再 `activate`，再 `tell window id _w`。

## Risks / Trade-offs

- [`TargetOptions.hasExplicitTarget` 計入所有 URL 旗標後，`open --url-endswith` 的行為改變] → 舊行為正是 #233 回報的缺陷；寫進 CHANGELOG 與 spec。
- [新 case 在某個 switch 漏處理、退回位置或 front window] → 每個 switch 寫 `.windowID` 的分支（Swift 的窮舉檢查會擋下遺漏的 `switch`，但 `if case` 不會）；測試以 fake runner 斷言 `get url`、`click`、`js`、`wait` 在 `--window-id` 時送出的 AppleScript 參照含 `window id W`、不含 `front window`。
- [profile 檢查多一次列舉] → 只在 `--window-id` 與 `--profile` 同時出現時。
- [真機行為] → 多視窗、Safari 不在前景的情境只有真機能證明；列為驗收項，需維護者同意開分頁。

## Migration Plan

純新增旗標與 JSON 欄位；`--window N` 語意不變。無資料遷移。

## Open Questions

(none)
