## Context

`TargetOptions.resolve()` 是同步的，把 `--window N` 對應到 `.windowIndex(N)`、`--window N --tab-in-window M` 對應到 `.windowTab(N, M)`，兩者都以位置參照（`document of window N`、`tab M of window N`）呈現。指令把這個值交給每一次 bridge 呼叫，所以每個 Apple event 都重新查一次 `window N`（dialog probe、派送、`--mark-tab` 的包上與拆下、`get text` 的長度與分段讀取、`exec` 的每一步）。

已經在開頭釘住的路徑：

- `js`、`wait`、`save-pdf` 經 `resolveToAnchoredTarget` 讀視窗 id 與目前分頁（#180、#255），並在每一步檢查那個分頁仍是目前分頁。
- `tabs --window N`、`tab focus` 列舉一次後以 id 讀取。
- `--profile` 的 `resolveProfileScoped` 已保留列舉讀到的 id（#351）。

#352 新增的 `--window-id W` 解析成 `.windowID(W, tabInWindow:)`，參照一律是 `window id W`；沒有 `--profile` 時不列舉，視窗不見了在腳本裡出錯，由 `runTargetedAppleScript` 回報 `documentNotFound`，不退回任何位置。

維護者決定（#354，2026-11-09）：`--window N` 在指令開頭解析成視窗 id 一次，之後的步驟像 `--window-id` 一樣跟著那個視窗的目前分頁；開頭讀不到 id 就維持位置語意；這個步驟要做成 `TargetOptions` 上可重用的一步，讓 #353（`close`、`screenshot`、`pdf`、`upload --native`）接著用。

## Goals / Non-Goals

**Goals:**

- 一個指令內，`--window N` 只在開頭依位置查一次；之後每一步都以 id 指定同一個視窗。
- 釘住後的行為與 `--window-id W` 在每條路徑上相同（有無 `--profile`、有無 `--tab-in-window`）。
- 釘住的視窗在途中關掉時 fail closed，訊息寫出使用者打的 `--window N`。
- 讀不到 id 時，錯誤與現在逐字相同（#87、#97）。
- `exec` 每次執行只釘一次，daemon 與子行程兩條路徑都是。

**Non-Goals:**

- `close`、`screenshot`、`pdf`、`upload --native`／`--allow-hid` 這些視窗層級的動作（#353；它們之後呼叫同一個步驟）。
- `js`、`wait`、`save-pdf`：已經釘住，而且多了「目前分頁不能換」的檢查，不改成本變更的語意。
- `tabs`、`tab new`、`tab focus`、`open --new-tab`：自己先讀視窗 id 再動作；`tab <N> --window N`（沒有 `--profile`）在單一 Apple event 裡以位置指定視窗；`open --new-window`、`documents`、`wait <ms>` 不讀分頁。
- `pdf-cache get`：只透過測試可注入的 seam 讀一次分頁網址，之後不再指定視窗（verify 第一輪：釘住會繞過 seam 讀 Safari）。
- 不帶旗標的預設目標（#287）：把 `.frontWindow` 也釘住會改變 `open` 在零視窗時建立新文件的路徑。
- 兩個指令之間：第二個指令開始時 `--window N` 仍指當下排第 N 的視窗。
- 分頁的穩定身分（#188）：`--tab-in-window M` 在釘住的視窗內仍是位置。
- 統一「每個 Apple event 的目前分頁」與 `js`／`wait` 的「開頭的目前分頁」兩種語意（維護者保留）。
- 使用者自己輸入的 `--window-id W --profile P` 仍在每次呼叫對 profile 檢查一次（每次呼叫一次列舉），與釘住前相同，不在此改；只有本行程釘住的 id 不再逐次檢查。

## Decisions

### 釘住步驟回傳改寫過的 `TargetOptions`

`TargetOptions.pinWindowAtStart() async throws -> TargetOptions` 回傳一份副本：`window` 清空、`windowID` 設為讀到的 id、`tabInWindow` 保留、`pinnedFromWindow` 記下 N，其餘欄位不變。每個範圍內指令的 `run()` 第一行是 `let target = try await self.target.pinWindowAtStart()`，之後原本的 `target.resolve()`、`resolveProfileScoped()`、`resolveFirstMatchOnce()`、`resolveWithFirstMatch()` 一行都不必改，因為它們讀到的已經是 `--window-id W`。

不採用的做法：回傳 `TargetDocument` 並逐一改掉約 62 個呼叫點。那樣每個呼叫點都可能和 `--window-id` 的路徑分岔，而副本的做法讓「行為與 `--window-id` 相同」由結構保證。#353 的指令只要加同一行。

### 讀 id 沿用 `js` 的兩個小查詢

- 沒有 `--profile`、只有 `--window N`：`SafariBridge.readWindowAnchor(index: N)`（一次 round trip，讀 id 與目前分頁）。零分頁的視窗在這裡讀不到，維持位置，`#97` 的訊息照舊。
- 沒有 `--profile`、`--window N --tab-in-window M`：`readTabAnchor(windowIndex: N)`，`1 ≤ M ≤ 分頁數` 才釘住；越界維持位置，由列舉照舊回報 `#87` 的訊息。
- 有 `--profile`：`resolveNativeTarget(from: .windowIndex(N) 或 .windowTab(N, M), profile:)` 一次，取 `windowID`；舊式列舉沒有 id 時維持位置。

不採用只讀 id 的 `readWindowID(index:)`：它在零分頁的視窗也讀得到 id，`document of window id W` 之後的失敗會變成 `.windowID` 的訊息，丟掉 `#97` 的說明。與 `js` 用同一組查詢也讓兩邊的邊界一致。

### 讀不到 id 時維持位置語意

讀不到 id 時回傳原本的 `TargetOptions`，並印一行 note 說 `--window N` 會在每一步依位置查：沒有 `--profile` 時是錨點查詢沒有回答（沒有這個視窗、零分頁、越界、逾時）；有 `--profile` 時是列舉回答 not found（找不到第 N 個視窗或第 M 個分頁）或舊式紀錄沒有 id，第一步重新列舉，拋出與現在相同的錯誤。verify 第一輪：`--profile` 下列舉逾時或失敗直接拋出（不讓第一步再等一次 30 秒），取消也拋出。

### `.windowID` 多帶 `pinnedFrom`，以私有選項 `--pinned-from-window` 傳遞

`TargetDocument.windowID(Int, tabInWindow: Int? = nil, pinnedFrom: Int? = nil)`。`TargetOptions.resolve()` 對 `--window-id W` 把 `pinnedFromWindow` 帶進去。會產生 `.windowID` 失敗訊息的三處以它改寫 pattern：

- `runTargetedAppleScript` 對 `.windowID` 的 object-not-found：`window 2 (window id 4711 at command start)`，清單說視窗已不在、不改用其他視窗。
- `checkWindowID`（native resolver 與已釘住 id 在指令開頭的 profile 檢查）：同一個 pattern 加上 `(profile: "P")`。
- verify 第一輪：`runTargetedAppleScript` 對釘住的 id 另外列出清單——分頁不見而視窗還在時列那個視窗的分頁；視窗不見且呼叫者旁帶 profile 時列那個 profile 的分頁（#362 的格式與 `--window-id` 提示）；其餘只有一則說視窗已不在的 note。`js`／`wait`／`save-pdf` 的錨定失敗也寫出 N。
- `pickNativeTargetCore` 的分頁越界：`window 2 tab 5 (window id 4711 at command start)`。

`resolveToConcreteTarget` 的 `--profile` 分支收斂成 `.windowID` 時保留 `pinnedFrom`。

`--pinned-from-window N` 是 `TargetOptions` 的 `@Option`，可見度 `.private`（不在 `--help`、不在 MCP 的工具 schema），只在有 `--window-id` 時有效、值須 ≥ 1。用選項而不是不經命令列的屬性，是因為 `exec` 把目標重新編成命令列參數（`ScriptInterpreter.encodeTargetArgs`）交給子行程與 daemon，屬性會在那裡遺失。它只影響訊息文字，使用者自行傳入也只會改變訊息。「這個 id 已對過 profile」則反過來，刻意放在不經命令列的屬性 `TargetOptions.profileCheckedAtStart`（進 `TargetDocument` 後是 `PinnedFrom.check`，內含被檢查的視窗 id 與 profile，改了其中之一的副本就沒有這份紀錄）：它在重新編碼時遺失，接手的行程因此必須自己再檢查一次，而不是相信送來的文字（verify 第二輪：第一輪把跳過逐次檢查的條件寫成「`pinnedFrom` 不是 nil」，於是這個選項本身就關掉了 profile 檢查，直接送給 daemon 的 `exec.runScript` 可以讀到別的 profile 的視窗）。它**不**列入 `TargetOptions.targetFlagNames`：script-exec 的目標旗標是十個的封閉列舉，而這個選項只由 `encodeTargetArgs` 寫進共用參數，不會出現在使用者寫的步驟參數裡（ASSUMPTION：使用者自己在步驟裡寫它，該步驟不會在 in-process 執行，交給子行程照常解析）。

不採用「訊息只寫 window id W」：使用者打的是 `--window 2`，只看到 4711 無法知道是哪個視窗關了；這正是診斷列出的風險。

### `--mark-tab` 先釘住再包標題

`ClickCommand.run()` 先釘住，`markTabIfRequested` 的包上、`perform`、拆下都收同一個 `.windowID`。daemon 的 `exec.runScript` 收到的已經是 `--window-id W`，整段標記同樣以 id 指定。

### exec 在分派路線之前釘住一次

`ExecCommand.execute` 先解析腳本（含 `--max-steps`），有步驟用到共用目標（沒有自己的目標旗標、不是 `documents`）或要標記分頁時才呼叫 `pinWindowAtStart()`，得到一份釘住的 `ExecCommand`（verify 第一輪）：

- daemon 路線：`viaDaemon` 收到釘住的指令，`daemonEnvelope` 編出的 `targetArgs` 是 `--window-id W [--tab-in-window M] --pinned-from-window N`。
- 子行程路線：`ScriptInterpreter.run(source:target:)` 收到釘住的目標，每一步的共用參數是同一組。`execute` 新增 `stepDispatcher` 參數（預設 `SubprocessStepDispatcher()`），讓測試不必真的開子行程。
- client 端讀不到 id 時：daemon 的 `exec.runScript` 若要標記分頁，在包標題之前再釘一次，並以 `InProcessStepDispatcher(pinsSharedWindowOnFirstNeed: false)` 讓步驟不再嘗試（否則包在位置上的標記會與後來讀到 id 的步驟分岔）；否則由 `SharedWindowPin` 在第一個需要共用目標的步驟再試一次，整個 request 共用結果。已釘住的 id 到 daemon 時不再讀（`--profile` 的檢查由 client 的列舉完成）。
- in-process 步驟自己帶的 `--window N`：`InProcessStepDispatcher` 對有自己目標旗標的步驟先釘住再 `resolveToConcreteTarget`；共用參數不在 dispatcher 裡釘（已由 `ExecCommand.execute` 釘成 `--window-id`），以免直接收到未釘參數的呼叫者每步多一次列舉。

`viaDaemon` 的型別改為 `(ExecCommand, [ScriptStep])`，三個既有測試照著改。

### `open` 只在導航路徑釘住

`open` 的 `--replace-tab` 與有目標旗標的兩條導航路徑先釘住再 `resolveProfileScoped()`；`--new-tab` 的 `newTabWindow()` 讀的是 `self.target`，維持 #351 的「`activate` 之前讀 id」腳本。釘住後 `openURL` 收到 `.windowID`，走「先 `get name of` 參照、導航、最後 `activate`」的分支。開頭沒有任何視窗時讀不到 id，維持 `.windowIndex`，仍建立新文件。

### `upload` 只在 JavaScript 路徑釘住

`upload` 的 native 路徑（`--native`、`--allow-hid`、有 Accessibility 時的預設）屬於 #353；只有走 JavaScript 的分支在解析目標前釘住。

### 形狀檢查防止新指令退回位置

測試讀 `Sources/SafariBrowser/Commands` 中每個組合 `TargetOptions` 的指令 struct，要求它呼叫 `pinWindowAtStart()`，或是已知清單上的例外（各自寫明原因：`js`／`wait`／`save-pdf` 自己錨定、#353 的三個 struct（`close`、`screenshot`、`pdf`；`upload` 在 JavaScript 路徑有釘住，所以以 struct 層級通過）、`tabs`／`tab switch`／`tab focus`、`documents`、`pdf-cache get`；`tab <N>` 與 `tab new` 同在 `TabSwitchCommand`，該 struct 本身在已知清單上；與有釘住的路徑共用 struct（`OpenCommand`）的是 `open --new-tab`，以 struct 層級看不出來）。它是形狀檢查，不是證明；行為由 fake Safari 的測試保證。

## Implementation Contract

**Behavior**

- 範圍內的指令帶 `--window N`：在自己的參數檢查之後、送出任何東西之前，送一個小查詢讀 id（有 `--profile` 時是一次列舉，也是整個指令的 profile 檢查），之後送出的 AppleScript，凡是指定目標視窗的，都以 `window id W` 指定，不以位置指定它（列出所有視窗的列舉不算指定目標視窗）。
- 帶 `--window N --tab-in-window M`：之後的參照是 `tab M of window id W`。
- 途中把另一個視窗拉到前面：後續步驟仍在視窗 W。
- 途中視窗 W 關掉：`documentNotFound`，pattern 以 `window N (window id W at command start)` 開頭（有分頁時 `window N tab M (window id W at command start)`），只有兩種情形在後面加 ` (profile: "P")`：(1) 指令開頭對 profile 的檢查失敗（該 id 不是這個 profile 的視窗；`exec` 步驟或 daemon 對別的 profile 的 id 回報的就是這個）；(2) `--profile` 下 `js`／`wait`／`save-pdf` 讀不到該視窗的目前分頁。釘住之後才關掉的視窗不加；沒有任何步驟打到現在排第 N 的視窗，也不出現 `front window`。
- 開頭讀不到 id：送出的腳本與錯誤訊息和本變更之前相同。
- `exec --window N`：整段執行只讀一次 id；每一步的共用參數是 `--window-id W`。

**Interface**

- `TargetOptions.pinWindowAtStart() async throws -> TargetOptions`
- `TargetOptions.pinnedFromWindow: Int?`（CLI `--pinned-from-window`，`.private`）
- `SafariBridge.TargetDocument.windowID(Int, tabInWindow: Int? = nil, pinnedFrom: PinnedFrom? = nil)`，`PinnedFrom { window: Int; check: ProfileCheck? }`、`ProfileCheck { profile: String; windowID: Int }`（`wasChecked(windowID:against:)` 是兩處跳過逐次 profile 檢查的唯一條件）
- `TargetOptions.profileCheckedAtStart: PinnedFrom.ProfileCheck?`（不是選項；只有 `pinWindowAtStart()` 在檢查之後設定）、`awaitsProfileCheckAtStart`
- `InProcessStepDispatcher(sharedTarget: TargetOptions? = nil)`（request 已先處理好的 exec 層目標）
- `SafariBridge.checkWindowID(_:profile:in:pinnedFrom:)`（`pinnedFrom` 預設 nil）
- `ExecCommand.execute(source:pacingEnabled:daemonOptedIn:viaDaemon:note:environment:stepDispatcher:)`，`viaDaemon: (ExecCommand, [ScriptStep]) async throws -> String?`

**Failure modes**

- 取消：釘住步驟往外拋 `CancellationError`。
- 讀不到 id（見〈讀不到 id 時維持位置語意〉）：不報錯，維持位置，stderr 一行 note。
- `--profile` 下的列舉逾時或失敗：拋出。
- `--pinned-from-window` 沒有 `--window-id`、或值 < 1：驗證錯誤。

**Acceptance**

- fake Safari 測試：視窗途中換順序、途中關閉、讀不到 id、`--profile`、`--tab-in-window`、`click --mark-tab`、`exec` 兩條路徑、`open --window N`。
- 形狀檢查通過。
- mutation：拿掉釘住、把釘住移到 `--mark-tab` 包上之後、`exec` 不釘、拿掉「讀不到維持位置」，各有具名測試失敗。
- `swift test` 全過（已知不穩的 MCP 計時測試單獨重跑）。

**Scope**

- 範圍內：proposal 列出的指令、`exec`、上述訊息。
- 範圍外：Goals / Non-Goals 的 Non-Goals 各項。

## Risks / Trade-offs

- [成本（verify 第一輪更正）] 沒有 `--profile`：釘住前每次 bridge 呼叫都先讀一次 `get id of window N`（`readWindowID`），釘住後只在開頭讀一次，單一呼叫的指令不多也不少，多次呼叫的指令變便宜，`--tab-in-window` 從每次列舉變成一次小查詢。有 `--profile`：釘住的列舉取代第一步的列舉，之後不再逐次列舉，所以不比釘住前多；只有讀不到 id（not found）時第一步會再列舉一次。`save-image` 以一次 `index of window id` 小查詢檢查釘住的視窗，不列舉。
- [`open --window N <url>` 的行為改變：`activate` 移到導航之後；開頭與導航之間視窗關掉會失敗而不是建立新文件] → 寫進 navigation 的 MODIFIED requirement 與 CHANGELOG。
- [未來新指令忘了呼叫釘住步驟，安靜退回位置] → 形狀檢查。
- [只解析一次 profile 的指令（`get text`、`get html`、`save-image`、`upload --js`、`open`）之後的呼叫不帶 profile，釘住的視窗不見時只列一則 note，不列 profile 的分頁] → 記為已知限制。
- [真正的失敗只在真機多視窗、Safari 不在前景時出現] → fake Safari 測試涵蓋腳本形狀；真機驗收列為維護者的任務，未做時照實標示。
- [`--pinned-from-window` 可被使用者自行傳入，也可寫進直接送給 daemon 的 request，而釘住的 id 在 `--profile` 下不再逐次檢查歸屬] → 跳過逐次檢查的條件不看這個選項，只看本行程做過的檢查（`PinnedFrom.check`）。帶著它到達的 `--window-id W --profile P`：會釘的指令在開頭由 `pinWindowAtStart()` 檢查一次；daemon 的 `exec.runScript` 每個 request 檢查一次（`SharedWindowPin`，有標記時在包標題之前）；`js`／`wait`／`save-pdf` 的錨定照舊檢查；其餘指令照 `--window-id` 的逐次檢查。成本：經 daemon 的 exec 在 `--profile` 下共列舉兩次（client 的釘住、daemon 的檢查）。
- [`exec` 的子行程 `js`／`wait` 步驟收到釘住的 `--window-id W` 後，錨點讀取逾時會直接失敗，而不是像 `--window N` 那樣退回位置] → 失敗關閉，寫進 CHANGELOG 的行為改變。
- [讀不到 id 時安靜退回位置] → 印一行 note；daemon 上的 exec 在第一個需要的步驟再試一次。
