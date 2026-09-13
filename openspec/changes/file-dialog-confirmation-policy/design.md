## Context

成功的 runner 丟棄 AppleScript log；同一 catch 包含查找與 click，無法區分是否已送出動作。既有 PDF 流程已合成一個腳本，必須保留。

## Goals / Non-Goals

Goals：可見 trace、不重播已 dispatch 的 click、明確 PDF 覆寫授權。Non-Goals：不以單一候選否定所有 AX 路線，不替換尚未證實等價的 Go to Folder 鍵盤路徑，不執行 Print 探測。

## Decisions

### Confirmation traces

新增 SafariBridge.runFileDialogScript(script, timeout, warnWriter optional)，只供 PDF、native upload 及 navigateFileDialog 使用。底層 runShell 新增 optional stderrWriter，runProcessWithTimeout 兩個 pipe 同時排空；成功、失敗與 timeout 都將已捕獲 stderr 送 callback 後再保留原結果／錯誤。FileDialogDiagnostics 用 TerminalText 跳脫整段 trace，限制 4096 個 rendered scalars，單一 `file dialog trace: ...` 行，明示截斷。writer 在呼叫執行緒選定：自訂 writer、DaemonRequestContext.emit 或 stderr。trace 在子程序結束後傳回，不冒充即時公告；原 keyboard warning 仍在 GUI 操作前。

### No replay after dispatch

實機顯示檔案面板按鈕位於 AXSplitGroup，舊 AXDefault 查找實際走 Return。改為從 sheet 直接 buttons 與 splitter groups 的 buttons 找唯一且 enabled 的具名 Open/Upload/Save／打開/開啟/上傳/儲存按鈕；確認前檢查 Safari frontmost、sheet 存在且沒有 nested sheet。查找失敗、不唯一、disabled、click 錯誤均直接傳出，不再送 Return。Go to Folder 的鍵盤步驟不變。PDF opener 同時修正為具名 File/檔案 → Export as PDF…/輸出為PDF⋯，不支援的語系明確失敗，沒有 Print fallback。

### Explicit PDF overwrite

新增 --overwrite，預設 false。完整目的路徑已存在且未授權時在 target resolution／GUI 前拒絕。exportScript 參數 overwrite=false；後續 nested replacement 若未授權也拒絕，避免初始檢查後才出現的檔案。授權時只找唯一具名 Replace/取代按鈕，找不到或不唯一皆拒絕；click 失敗不重播、不以 Return 猜測。--overwrite 不取代 --allow-hid。

### Native confirmation exception

文件與 non-interference 具名記錄使用者指定檔案操作授權 initial confirmation，保留原 upload system-grant 例外；覆寫另外授權。PDF spec 修改既有 Export page as PDF requirement；operation inventory 分別記錄具名確認與目的地輸入的證據；移除已驗證可替代的 confirmation Return，不擴張為可移除路徑導航 HID。

## Implementation Contract

runFileDialogScript 回傳原 stdout；非檔案 caller 預設不新增 stderr。trace 不輸出控制字元、不改錯誤類型／timeout語意；兩個 pipe 大輸出不能造成假 timeout。PDF 未 --overwrite 不確認 replacement。實際 Open/Save/Replace 的 fixture 應使用自有 window、nonce URL、目錄與檔案；成功／故障都確認清理，未確認則不算 PASS。AX fallback 等價性只以該實測裁定，不用單元或編譯結果冒充。

## Risks / Trade-offs

程序 I/O、建構與編譯不能代替實機驗收，兩種證據分開記錄。舊版 PDF 已存在路徑會新增拒絕，使用 --overwrite 明確恢復覆寫意圖。固定英文／繁體中文 Replace 名稱不涵蓋其他語系，未知名稱拒絕而不猜測。Export opener 只支援英文與實測繁體中文名稱，不宣稱所有語系成功。

## Subprocess execution evidence

並行排空採 Dispatch stderr reader；Process.run 到 waitUntilExit 之間不引入 async suspension。開發時 async let 曾使 Foundation 在不同執行緒 wait 卡住；恢復原執行緒 launch/wait 後，原有 timeout 與 MCP process 測試均通過。新控制流程測試只把查找／click／Return 外部操作換成純 AppleScript 效果，實際執行產生的確認控制流程；另以 osacompile 編譯四個 production scripts，皆不執行 Safari GUI。預檢亦拒絕目錄、NUL 與無法查驗的目標，lstat 將 dangling symlink 視為既有項目。

審查補正：lstat 後對 symlink 再 stat 目標，拒絕 symlink→directory 與無法查驗的目標；dangling link 仍視為既有項目。late replacement 拒絕訊息明示手動取消面板後再重試。固定 0.5s 偵測與副檔名補齊是既有待量測項，#106/#102 實機驗收必須比對真正輸出路徑及面板清理，不以 exit 0 假定成功。

## 2026-09-13 實機重新判定

GUI 已可使用。舊 production native upload 在自有頁面確實取得正確 file name/content 並輸出 Return fallback trace。Save 具名 AXPress 可存檔，但將完整路徑直接寫入檔名欄＋AXConfirm 會把斜線換成冒號、落在原目錄；僅這項目的地候選被實測否定，不能宣稱所有 AX 路線均無解。上述證據取代先前 GUI 鎖定下暫留查找 fallback 的決定；最終具名 production Open/Save/Replace 已在 macOS 27.0 / Safari 27.0 完成；頁面檔案內容、PDF 真正落點、sentinel 覆寫與 late refusal 原內容保留皆確認，所有自有面板／視窗已清理。使用者目前沒有隔離 macOS 測試環境，Print 實驗保持未完成。
