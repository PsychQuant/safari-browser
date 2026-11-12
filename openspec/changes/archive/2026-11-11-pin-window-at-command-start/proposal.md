## Why

`--window N` 以視窗的前後順序指定視窗。`js`、`wait`、`save-pdf` 在指令開頭把它解析成視窗 id 一次（#180），其他指令卻在每個 Apple event 重新查 `window N`：dialog probe、派送、`--mark-tab` 的包上與拆下、分段讀取、`exec` 的每一步。一個指令的兩步之間只要有視窗被拉到前面，後面的步驟就打到另一個視窗，可能是別人的 profile（#354）。#352 已經讓使用者能用 `--window-id` 直接指定穩定的 id，但 `--window N` 在大多數指令上仍會漂移。

## What Changes

- `TargetOptions` 新增一個可重複使用的步驟 `pinWindowAtStart()`（非同步）：在指令開頭把 `--window N` 解析成那個視窗的 id `W`，回傳一份 `--window N` 已換成 `--window-id W` 的 `TargetOptions`；`--window N --tab-in-window M` 換成 `--window-id W --tab-in-window M`（開頭先確認視窗 N 有第 M 個分頁）。
  - 沒有 `--profile`：用 `js` 已在用的兩個小查詢（`readWindowAnchor(index:)`、`readTabAnchor(windowIndex:)`），不列舉。
  - 有 `--profile`：用那個 profile 的列舉讀到的 id 一次；這次列舉就是整個指令的 profile 檢查，之後不再逐次列舉（verify 第一輪）。
  - 讀不到 id（沒有這個視窗、零分頁的視窗、分頁序號越界、舊式列舉沒有 id；沒有 `--profile` 時還包括沒有回應的查詢）：維持原本的位置語意並印一行 note，`--profile` 下列舉逾時或失敗則是指令的錯誤、不退回（verify 第一輪），第一步照舊以 #87／#97 的訊息失敗（`js`／`wait` 的前例，維護者決定）。取消照樣往外拋。
  - 其他目標旗標（`--url` 系列、`--document`、`--tab`、`--window-id`、沒有旗標）原樣回傳，不送任何 Apple event。唯一例外：帶著 `--pinned-from-window` 到達、又有 `--profile` 的 `--window-id`（`exec` 交給步驟的形狀），在這裡對 profile 檢查一次（一次列舉），檢查過才記下證明（verify 第二輪）。
- 釘住之後，後續每一步都跟 `--window-id W` 完全一樣：沒有 `--tab-in-window` 時是那個視窗在每個 Apple event 當下的目前分頁，有 `--tab-in-window M` 時是第 M 個分頁。視窗在指令途中關掉 → 以 `documentNotFound` 失敗，**絕不**改用現在排在第 N 的視窗。
- 釘住後的失敗訊息寫出使用者打的 `--window N`：`window 2 (window id 4711 at command start)`。為此 `TargetDocument.windowID` 多一個可選值 `pinnedFrom`，並以不顯示在 `--help` 的私有選項 `--pinned-from-window N` 讓 `exec` 的子行程與 daemon 也帶著它。這個選項只管訊息文字：「id 已對過 profile」另記在不經命令列的屬性，接手的行程一律自己再檢查（verify 第二輪）。
- 呼叫這個步驟的指令（封閉列舉）：`back`、`check`、`uncheck`、`click`、`console`、`cookies get`／`set`／`clear`、`dblclick`、`drag`、`errors`、`fill`、`find`、`focus`、`forward`、`get` 的所有子指令、`highlight`、`hover`、`is` 的所有子指令、`mouse` 的所有子指令、`open` 的導航路徑（不含 `--new-tab`、`--new-window`）、`press`、`reload`、`save-image`、`scroll`、`scrollintoview`、`select`、`set media`、`snapshot`、`storage` 的所有子指令、`tab is-marked`、`tab unmark`、`type`、`upload` 的 JavaScript 路徑（`--js`，以及沒有 Accessibility 時的預設），以及 `exec`。
- `click --mark-tab`（與 `exec` 在 daemon 上的整段標記）先釘住、再包標題，包上、動作、拆下用同一個 id。
- `exec`：在分派路線之前釘住一次，daemon 的 `exec.runScript` 與子行程路徑都收到 `--window-id W`；步驟自己帶的 `--window N` 在 in-process 路徑同樣先釘住。
- `open --window N <url>`：改走 `openURL` 以 id 指定視窗的分支（先讀參照、導航、最後才 `activate`）；開頭時沒有任何視窗則維持建立新文件。

## Non-Goals (optional)

(design.md 的 Goals / Non-Goals 記載範圍外的項目與不採用的做法。)

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `document-targeting`: 新增「`--window N` 在指令開頭解析成視窗 id 一次」的 requirement（釘住、途中關閉的 fail closed、讀不到 id 時維持位置語意、`--profile`、失敗訊息寫出 `--window N`、呼叫者的封閉列舉）。
- `script-exec`: 修改〈Shared target resolution〉：`exec` 層級的 `--window N [--tab-in-window M]` 在整段執行開始前釘成 `--window-id W` 一次，兩條路徑都以它解析每一步。
- `navigation`: 修改〈Open URL in current tab〉：`open --window N <url>` 在開頭釘住後，像 `--window-id` 一樣先讀參照、導航後才 `activate`；開頭沒有視窗時仍建立新文件。

## Impact

- Affected specs: `document-targeting`、`script-exec`、`navigation`
- Affected code:
  - `Sources/SafariBrowser/Commands/TargetOptions.swift`（`pinWindowAtStart()`、`--pinned-from-window`、`resolve()`）
  - `Sources/SafariBrowser/SafariBridge.swift`（`TargetDocument.windowID` 的 `pinnedFrom`、`targetDescription`、`checkWindowID`、`pickNativeTargetCore` 的分頁越界訊息、`resolveToConcreteTarget` 保留 `pinnedFrom`）
  - 上列各指令的 `run()`：`Sources/SafariBrowser/Commands/{Back,Check,Click,Console,Cookies,Dblclick,Drag,Errors,Fill,Find,Focus,Forward,Get,Highlight,Hover,Is,Mouse,Open,Press,Reload,SaveImage,Scroll,ScrollIntoView,Select,Set,Snapshot,Storage,Tab,Type,Upload,Exec}Command.swift`
  - `Sources/SafariBrowser/Exec/InProcessStepDispatcher.swift`、`Sources/SafariBrowser/Exec/ScriptInterpreter.swift`
  - `Sources/SafariBrowser/Utilities/Errors.swift`（釘住的 miss 的提示）
  - `.windowID` 的其他比對處：`Commands/JSCommand.swift`、`Commands/WaitCommand.swift`
  - 測試：新的 fake Safari 測試與形狀檢查；既有 `.windowID` 比對的測試
  - 文件：`CHANGELOG.md`、`CLAUDE.md`、`--window` 的 `--help`
