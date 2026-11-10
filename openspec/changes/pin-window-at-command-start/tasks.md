## 1. 釘住步驟與 `.windowID` 的 `pinnedFrom`（TDD：先寫失敗的測試）

涵蓋 requirement「Window number resolved to its id at command start」的讀 id 與退回；design「釘住步驟回傳改寫過的 `TargetOptions`」「讀 id 沿用 `js` 的兩個小查詢」「讀不到 id 時維持位置語意」「`.windowID` 多帶 `pinnedFrom`，以私有選項 `--pinned-from-window` 傳遞」。

- [x] 1.1 `TargetDocument.windowID` 加第三個可選值 `pinnedFrom`（預設 nil），逐一更新所有比對處；`TargetOptions` 加私有選項 `--pinned-from-window`（`.private`，需要 `--window-id`、值 ≥ 1），`resolve()` 把它帶進 `.windowID`，`ScriptInterpreter.encodeTargetArgs` 含它（`targetFlagNames` 不含，見 design）。驗證：`WindowPinTests` 的解析與驗證測試（`--window-id 4711 --pinned-from-window 2` → `.windowID(4711, nil, pinnedFrom: 2)`；沒有 `--window-id`、0 → 驗證錯誤；`--help` 不列出）
- [x] 1.2 `TargetOptions.pinWindowAtStart()`（requirement「Window number resolved to its id at command start」）：沒有 `--profile` 時 `--window N` 以 `readWindowAnchor(index:)`、`--window N --tab-in-window M` 以 `readTabAnchor(windowIndex:)` 加範圍檢查讀 id；有 `--profile` 時以 `resolveNativeTarget` 列舉一次；回傳 `window` 清空、`windowID`／`pinnedFromWindow` 設定好的副本；讀不到（含越界、零分頁、無 id 的舊式列舉、任何錯誤）回傳原副本；取消往外拋；其他旗標不送 Apple event。驗證：以 fake `appleScriptRunner` 的單元測試逐一涵蓋上述每一種輸入，並斷言送出的腳本數
- [x] 1.3 失敗訊息寫出 `--window N`：`runTargetedAppleScript` 的 `.windowID` 分支、`checkWindowID`（新增 `pinnedFrom` 參數，預設 nil）、`pickNativeTargetCore` 的分頁越界；`resolveToConcreteTarget` 的 `--profile` 分支收斂成 `.windowID` 時保留 `pinnedFrom`。驗證：fake Safari 讓釘住的視窗在第二步消失，斷言 pattern 為 `window 2 (window id 4711 at command start)`（`--profile` 時加 `(profile: …)`，分頁時 `window 2 tab 3 (…)`），且不列其他視窗的分頁

## 2. 指令接上釘住步驟

涵蓋 requirement「Window number resolved to its id at command start」的封閉列舉與 `--mark-tab`；design「`--mark-tab` 先釘住再包標題」「`open` 只在導航路徑釘住」「`upload` 只在 JavaScript 路徑釘住」。

- [x] 2.1 [P] 每個範圍內指令的 `run()` 第一行 `let target = try await self.target.pinWindowAtStart()`（`TabUnmarkCommand`、`TabIsMarkedCommand` 用自己的屬性名）：back、check／uncheck、click、console、cookies 三個子指令、dblclick、drag、errors、fill、find、focus、forward、get 所有子指令、highlight、hover、is 所有子指令、mouse 所有子指令、pdf-cache get、press、reload、save-image、scroll、scrollintoview、select、set media、snapshot、storage 所有子指令、tab is-marked、tab unmark、type。驗證：fake Safari 測試對 `get url`、`get text`、`click`、`storage local get`、`snapshot`、`tab is-marked` 斷言讀 id 之後沒有腳本含 `window 2`、途中換順序後仍打 `window id W`
- [x] 2.2 `click --mark-tab` 先釘住再 `markTabIfRequested`：包上、點擊、拆下都是 `window id W`。驗證：fake Safari 在第一個腳本之後把另一個視窗換到第 2 位，斷言讀 id 的腳本在第一個 `set name`／標題寫入之前，之後沒有 `window 2`
- [x] 2.3 [P] `open`（requirement「Open URL in current tab」）：`--replace-tab` 與有目標旗標的導航路徑先釘住再 `resolveProfileScoped()`；`--new-tab`、`--new-window` 與 focus-existing 不變。驗證：fake Safari 斷言 `open --window 2 <url>` 送出 `get name of document of window id W`、導航、最後 `activate`；零視窗時仍是 `make new document`；`open --new-tab --window 2` 的腳本不變
- [x] 2.4 [P] `upload`：只有 JavaScript 路徑在解析目標前釘住，native 路徑不動（#353）。驗證：`upload --js` 的 fake Safari 測試斷言 `window id W`；native 路徑的既有測試不變
- [x] 2.5 形狀檢查防止新指令退回位置：組合 `TargetOptions` 的每個指令 struct 都呼叫 `pinWindowAtStart()`，或在已知清單上（寫明原因與 issue）。驗證：`WindowPinCommandTests.testEveryCommandStructWithATargetPinsTheWindowExceptTheKnownOnes`；把任一指令的釘住拿掉時它失敗（struct 層級：同一 struct 的第二條路看不到，由 driven 測試負責）

## 3. exec

涵蓋 script-exec 的 MODIFIED〈Shared target resolution〉；design「exec 在分派路線之前釘住一次」。

- [x] 3.1 `ExecCommand.execute` 一開始釘住（requirement「Shared target resolution」）；`viaDaemon` 改收 `(ExecCommand, [ScriptStep])`，`daemonEnvelope` 編出釘住的 `targetArgs`；子行程路線把釘住的目標交給 `ScriptInterpreter`，`execute` 新增 `stepDispatcher` 參數；三個既有測試照著改。驗證：daemon 路線測試斷言 envelope 的 `targetArgs` 是 `--window-id W --pinned-from-window N`；子行程路線以記錄用 dispatcher 斷言每一步的共用參數相同、整段只讀一次 id
- [x] 3.2 `InProcessStepDispatcher` 對有自己目標旗標的步驟先釘住：步驟自己的 `--window N` 在那一步開頭釘住；共用參數不在 dispatcher 裡釘（`ExecCommand.execute` 已釘成 `--window-id`）。驗證：in-process 測試（步驟自帶 `--window 2`、共用 `--window-id`）

- ASSUMPTION（實作時決定，verify 時請挑戰）：
  - `--pinned-from-window` 不列入 `targetFlagNames`：script-exec 的目標旗標是十個的封閉列舉，這個私有選項只由 `encodeTargetArgs` 寫進共用參數。
  - `pdf-cache get` 只讀一次分頁網址，仍在讀之前釘住：讀網址前還有 dialog probe，兩者原本各查一次 `window N`。（verify 第一輪推翻：釘住會繞過注入的 seam，改為不釘、列為例外，見 5.4。）
  - 標 `[P]` 的任務依序完成，未分派平行 agent：每個都要改 `TargetOptions` 與 `SafariBridge` 已定下的介面，平行改同一批呼叫點容易互相覆蓋。
  - `spectra` CLI 以 git 的共用目錄定位專案（會寫到另一個 checkout），本變更的 `spectra analyze`／`validate` 在只含 `openspec/` 的暫存鏡像中執行，產出只寫在這個 worktree。

## 4. 規格、文件與驗收

- [x] 4.1 [P] `--window` 的 `--help` 說明「在指令開頭解析成視窗 id」；`CHANGELOG.md`（Unreleased）與 `CLAUDE.md` 的 multi-window 段落寫明語意、範圍、例外、`open --window N` 的行為改變與已知限制。驗證：內容檢查
- [x] 4.2 全套 `swift test` 通過；mutation 各做一次並有具名測試抓到：拿掉釘住、釘住移到 `--mark-tab` 包上之後、`exec` 不釘、拿掉「讀不到維持位置」。驗證：`swift test` 計數與 mutation 紀錄
  - 2026-11-09：`swift test` 2488 個 XCTest（13 個略過）與 38 個 Swift Testing 全過。mutation（各在本機改一次、跑 `WindowPinTests`／`WindowPinCommandTests`、還原）：拿掉 `get url` 的釘住 → `testReadCommandsFollowTheWindowThatWasNNotThePosition`、`testAMissOnAPinnedWindowNamesTheWindowNumberTheUserTyped` 等 6 個失敗；`--mark-tab` 包標題改用未釘住的目標 → `testClickMarkTabPinsBeforeTheWrap`；`exec` 不釘 → `testExecSendsTheDaemonTheWindowIDReadOnceBeforeRouting`、`testExecGivesEveryLocalStepTheWindowIDReadOnce`（與形狀檢查）；讀不到 id 時改為報錯 → `testAnUnreadableIDKeepsThePosition`、`testAnUnreadableIDLeavesTheOldPositionalScripts`、`testOpenWithAWindowNumberAndNoWindowStillMakesANewDocument` 等 4 個。
- [ ] 4.3 真機驗收（需維護者）：多個視窗、Safari 不在前景時，在 `click --mark-tab --window 2` 的步驟之間把另一個視窗拉到前面，確認仍在原視窗；途中關掉視窗得到寫出 `--window 2` 的 `documentNotFound`；`open --window 2 <url>` 最後才 `activate`。驗證：真機紀錄寫進 issue；未做時照實標示
  - 2026-11-09 狀態：**未做**。需要真的 Safari（多個視窗、不在前景），本次無人值守的執行不碰真機；腳本形狀由 fake Safari 涵蓋，實際行為仍未證明。

## 5. verify 第一輪的修正（2026-11-10）

- [x] 5.1 `--profile` 下釘住的 miss 符合 #362 的 requirement「Document not found surfaces discoverable error」：釘住的列舉就是整個指令的 profile 檢查（`resolveScriptTarget` 與 `resolveToConcreteTarget` 不再為釘住的 id 列舉），視窗不見時 `runTargetedAppleScript` 列出 profile 的分頁並附視窗 id、提示指向 `--window-id`；分頁不見而視窗還在時列那個視窗的分頁；沒有 profile 且視窗不見時一則 note，提示說明視窗已關、未改用其他視窗。驗證：#362 的 `ProfileScopedMissTranslationTests`（未改期望）、`WindowPinTests.testAMissOnAPinnedWindowWithAProfileListsTheProfilesTabsByID`、`WindowPinRound1Tests` 的 wording 測試
- [x] 5.2 document-targeting 的 MODIFIED「Document not found surfaces discoverable error」：第 2 項的 `--window N` 呼叫者與大型結果後續讀取的例外只在開頭讀不到 id 時成立，新增第 8 項（釘住的 miss）；ADDED requirement 修正 `(profile: …)`、`tab <n>`、#287、`pdf-cache get`、「address the target window」的措辭；script-exec delta 補上 `documents` 例外與先解析再釘住；#362 的 CHANGELOG／CLAUDE.md「#354 would remove」改寫。驗證：`spectra validate`、內容檢查
- [x] 5.3 `runRaised()` 斷言指令完成（`is-marked` 斷言 exit 1），`--profile` 的測試改用多次呼叫的 `click --mark-tab` 並計算列舉次數。驗證：拿掉 `get url` 的釘住、或在 `--profile` 下逐次列舉時測試失敗
- [x] 5.4 `js`／`wait`／`save-pdf` 的錨定失敗保留 `pinnedFrom`；`save-image` 以一次小查詢檢查釘住的視窗；`scroll`／`set media`／`press`／`find` 先檢查參數、`exec` 先解析腳本再釘、沒有步驟用到共用目標時不釘；`--profile` 下列舉逾時直接拋出，只有 not found 退回；退回時印一行 note，daemon 上的 exec 在第一個需要的步驟再試一次；釘住不做 dialog probe；`pdf-cache get` 不釘。驗證：`WindowPinRound1Tests`
- [x] 5.5 文件：CHANGELOG 的成本、行為改變（含 exec 子行程 `js`／`wait` 錨點逾時直接失敗）、已知限制；README／CLAUDE.md：`--tab-in-window M` 在釘住的視窗內仍逐次是位置、讀不到 id 時 `--window N` 仍是位置、`tab <n>` 與預設目標（#287）不在範圍內。驗證：內容檢查

