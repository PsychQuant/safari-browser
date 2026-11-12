## Why

`close`、`screenshot`、`pdf`、`upload` 的 native 路徑，以及 `open` 把既有分頁帶到前面的那條路，解析完目標之後仍然用視窗的前後位置（`window N`）下後續的 Apple event。解析結果其實已經帶著那個視窗的穩定 id，只是沒有被用上。兩個 Apple event 之間只要有視窗被拉到前面，後面的步驟就落在另一個視窗：關錯分頁、把鍵盤輸入送進別的視窗、截到別的視窗（#353）。`close` 另有一個獨立的錯誤：它先把目標分頁切成目前分頁，再關「目前分頁」，所以關的是切換之後剛好在前面的那一個，而且切換本身就改變了使用者看到的分頁（#348）。

#354 已經讓其他指令在開頭把 `--window N` 換成視窗 id，並明寫這四個指令留給本變更；#355 之後，讀不到視窗 id 的情況只剩零分頁的視窗與沒有回應的查詢。現在補上最後這一段。

## What Changes

- **共同規則**：這五條路徑解析出目標之後，後續每一段 AppleScript 都以 `window id W` 指稱目標視窗，不再出現 `window N`；`front window` 只用來比對 `id of front window` 是不是 `W`。
- **`--window N`**：`close`、`screenshot`、`pdf`、`upload`（native 路徑）在指令開頭呼叫 #354 的 `pinWindowAtStart()`，把 `--window N` 換成那個視窗的 id 一次。讀不到 id 時照 #354 的規則：維持位置、印一行 note。
- **`close`**（修正 #348）：一段 AppleScript 完成。解析出特定分頁時關 `tab T of window id W`，否則關那個視窗的目前分頁。**不再切換分頁。** **行為改變**：`close --url X` 關背景分頁時，使用者正在看的分頁不變。
- **以網址比對出來的目標**（`--url` 系列，以及 `open` 要開的網址）：第一段對那個分頁動手的 AppleScript（關閉、切成目前分頁、把視窗拉到前面）先在同一段裡比對分頁現在的網址與解析時讀到的網址，不同就以 `targetTabChanged` 失敗、不動手，也不重新解析重試。
- **`pdf`**：切換分頁併進匯出腳本，整段以 id 進行（確認視窗還在、切分頁、讀網址、拉到前面）。
- **`upload` 的三條 native 路徑**（`--native`、`--allow-hid`、有 Accessibility 時的預設）：切換分頁、事前檢查、點擊 file input 都以 id 指定；dialog 腳本以 id 把視窗拉到前面，並在第一個按鍵之前、之後每一個按鍵與確認之前，檢查 `id of front window` 是 `W`。**行為改變**：視窗不在最前面時，原本會把按鍵送進別的視窗，現在失敗且不送任何按鍵。
- **`screenshot`**：改讀 `window id W` 的 bounds 與標題（一段 AppleScript），之後照舊以 bounds 加標題在 Accessibility 的視窗清單裡找出要截的視窗。不拉視窗、不切分頁。
- **`open` 帶出既有分頁**：比對時留下視窗 id；同視窗切分頁、跨視窗拉到前面都以 id 在一段 AppleScript 裡完成，並先比對網址。
- **視窗在途中關掉**：以 `documentNotFound` 失敗，不關任何分頁、不送任何按鍵、不截圖；由 `--window N` 釘住的視窗，訊息寫出 `window N (window id W at command start)`。
- **不變的部分**：沒有任何目標旗標（也沒有 `--profile`）時，四個指令照舊對最前面的視窗動作（#287 另案）。讀不到視窗 id 時，同一批腳本改以位置指稱視窗。
- 規格文字同步：`document-targeting` 一個 scenario 把 `close --url` 寫成「關掉那個視窗」，改成關掉那個分頁。

## Non-Goals (optional)

（範圍外的項目與不採用的做法記在 design.md 的 Goals / Non-Goals。）

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `document-targeting`: 新增「視窗層級的指令以解析到的視窗 id 動作」的 requirement；修改 native 路徑解析、切換分頁、`--window-id`、`--window N` 在開頭釘住（三份封閉清單）與 `WindowOnlyTargetOptions removal` 的 scenario。
- `navigation`: 修改〈Close current tab〉：關的是解析出來的那個分頁，一段 AppleScript，不切換分頁。
- `screenshot`: 修改〈Screenshot command accepts full TargetOptions〉：以 id 讀 bounds 與標題。
- `human-emulation`: 修改〈Spatial interaction gradient〉：第 2、3 層以視窗 id 在一段 AppleScript 裡完成，先比對網址。
- `pdf-export`: 修改〈PDF export command accepts full TargetOptions〉：匯出腳本以 id 進行，切換分頁併入同一段。
- `file-upload`: 修改〈Upload command accepts full TargetOptions on all execution paths〉：native 路徑以 id 進行，按鍵之前檢查最前面的視窗。
- `non-interference`: 修改〈Tab auto-switch classified as transitively authorized interference〉（以 id 切換）與〈Spatial interference gradient for focus-existing〉（第 2、3 層的寫法）。
- `window-enumeration`: 修改〈The enumeration decoder fails closed〉的一個 scenario：它把 `close` 列為會切換分頁的指令，改成 `close` 以位置關閉那個分頁、不切換。

## Impact

- Affected specs: `document-targeting`、`navigation`、`screenshot`、`human-emulation`、`pdf-export`、`file-upload`、`non-interference`、`window-enumeration`
- Affected code:
  - `Sources/SafariBrowser/Commands/CloseCommand.swift`、`PdfCommand.swift`、`UploadCommand.swift`、`ScreenshotCommand.swift`、`OpenCommand.swift`
  - `Sources/SafariBrowser/SafariBridge.swift`：`ResolvedWindowTarget`（多帶比對到的網址）、`pickNativeTarget` 的網址分支、`performTabSwitchIfNeeded`、`closeCurrentTab`／`closeCurrentTabScript`、`resolveWindowForCapture`／`getWindowIDViaAX`、`findExactMatch`／`findExactMatchingTab`、`focusExistingTab`、`activateWindow`、`fileDialogNavigationScript`、`runTargetedAppleScript` 的 not-found 轉換
  - `Sources/SafariBrowser/Commands/TargetOptions.swift`：`--window`、`--window-id` 的說明與 `pinWindowAtStart` 的註解
  - 測試：`WindowPinCommandTests`（封閉清單）、`WindowPinFakeSafari`、`PDFNativeCompletionTests`、`FileDialogScriptSharingTests`、`FileDialogConfirmationPolicyTests`、`InterferenceWarningTests`、`GUISessionTests`、`ZeroTabWindowGuardTests`、`WindowIndexResolverTests`、`ResolverConvergenceTests`、`Issue28RegressionTests`，以及新的測試檔
  - 文件：`CLAUDE.md`、`CHANGELOG.md`
- 呼叫端：以 `close` 加網址鎖關自己分頁的腳本（PsychQuant/Akashic-Library#769）拿到的是「只關那個分頁」；MCP facade 暴露同一批子指令，行為一起改變。
- 範圍說明：本變更碰八個 capability、十四條 requirement，超過一般拆分門檻。它們描述的是同一件事（解析之後以視窗 id 動作），拆成數個 change 會讓〈Window number resolved to its id at command start〉的封閉清單在中間狀態自相矛盾，所以維持一個 change。
