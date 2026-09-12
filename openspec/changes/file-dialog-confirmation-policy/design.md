## Context

成功的 runner 丟棄 AppleScript log；同一 catch 包含查找與 click，無法區分是否已送出動作。既有 PDF 流程已合成一個腳本，必須保留；目前 GUI 鎖定。

## Goals / Non-Goals

Goals：可見 trace、不重播已 dispatch 的 click、明確 PDF 覆寫授權。Non-Goals：不宣稱 Save AX 已實測，不替換尚未證實等價的 Go to Folder 鍵盤路徑，不執行 Print 探測。

## Decisions

### Confirmation traces

新增 SafariBridge.runFileDialogScript(script, timeout, warnWriter optional)，只供 PDF、native upload 及 navigateFileDialog 使用。底層 runShell 新增 optional stderrWriter，runProcessWithTimeout 兩個 pipe 同時排空；成功、失敗與 timeout 都將已捕獲 stderr 送 callback 後再保留原結果／錯誤。FileDialogDiagnostics 用 TerminalText 跳脫整段 trace，限制 4096 個 rendered scalars，單一 `file dialog trace: ...` 行，明示截斷。writer 在呼叫執行緒選定：自訂 writer、DaemonRequestContext.emit 或 stderr。trace 在子程序結束後傳回，不冒充即時公告；原 keyboard warning 仍在 GUI 操作前。

### No replay after dispatch

initial defaultBtn 查找／title read 與 click 分離。只有查找階段失敗能走原 Return fallback，前提是 Safari frontmost、sheet 存在且沒有新的 nested sheet；必須記錄 fallback。click 呼叫開始前設 attempt 狀態，之後任何錯誤直接傳出，不再送 Return。Go to Folder 的 Return 不變。

### Explicit PDF overwrite

新增 --overwrite，預設 false。完整目的路徑已存在且未授權時在 target resolution／GUI 前拒絕。exportScript 參數 overwrite=false；後續 nested replacement 若未授權也拒絕，避免初始檢查後才出現的檔案。授權時只找唯一具名 Replace/取代按鈕，找不到或不唯一皆拒絕；click 失敗不重播、不以 Return 猜測。--overwrite 不取代 --allow-hid。

### Native confirmation exception

文件與 non-interference 具名記錄使用者指定檔案操作授權 initial confirmation，保留原 upload system-grant 例外；覆寫另外授權。PDF spec 修改既有 Export page as PDF requirement；operation inventory 維持未測量 Save AX 的 untested。將「fallback 僅查找失敗」與「全部替代可刪」分開：前者是本次安全修正，後者待真實驗收後裁定。

## Implementation Contract

runFileDialogScript 回傳原 stdout；非檔案 caller 預設不新增 stderr。trace 不輸出控制字元、不改錯誤類型／timeout語意；兩個 pipe 大輸出不能造成假 timeout。PDF 未 --overwrite 不確認 replacement。實際 Open/Save/Replace 的 fixture 應使用自有 window、nonce URL、目錄與檔案；成功／故障都確認清理，未確認則不算 PASS。AX fallback 等價性只以該實測裁定，不用單元或編譯結果冒充。

## Risks / Trade-offs

GUI 鎖定使目前只能驗證程序 I/O、腳本建構與編譯；保留實機 gate。舊版 PDF 已存在路徑會新增拒絕，使用 --overwrite 明確恢復覆寫意圖。固定英文／繁體中文 Replace 名稱不涵蓋其他語系，未知名稱拒絕而不猜測。現有英文 Export as PDF menu 仍需在實機檢查，不宣稱跨語系成功。

## Subprocess execution evidence

並行排空採 Dispatch stderr reader；Process.run 到 waitUntilExit 之間不引入 async suspension。開發時 async let 曾使 Foundation 在不同執行緒 wait 卡住；恢復原執行緒 launch/wait 後，原有 timeout 與 MCP process 測試均通過。新控制流程測試只把查找／click／Return 外部操作換成純 AppleScript 效果，實際執行產生的 try/catch；另以 osacompile 編譯四個 production scripts，皆不執行 Safari GUI。預檢亦拒絕目錄、NUL 與無法查驗的目標，lstat 將 dangling symlink 視為既有項目。
