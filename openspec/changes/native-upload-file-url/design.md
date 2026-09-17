## Context

#101 已有 macOS/Safari 27.0 的非 HID 完整上傳實證。既有 nativeUploadEffects 把開啟面板的 JavaScript 與原生流程分開；新的單一腳本須先固定視窗／頁面，再開啟與確認同一個檔案面板。

## Goals / Non-Goals

Goals：取代上傳鍵盤導航，保留 targeting、大檔路徑、具名確認與干擾警告；保存剪貼簿並驗證 input 實際選取結果。
Non-Goals：不修改 PDF 導航、不重寫 JS DataTransfer、不新增平台／語系、不安裝使用者 binary、不自動重試不明結果。

## Decisions

### 有界剪貼簿 lease

新增上傳專用 FileURLClipboard，使用 AppKit 保存全部項目與型別（資料上限 64 MiB），在完整快照與穩定 changeCount 後寫入一個 NSURL。同程序以 pasteboard identity registry、一般剪貼簿跨程序以 Darwin confstr 每使用者私有暫存目錄的非阻塞 advisory lock 拒絕重疊 lease，避免把另一筆暫時內容當成原始快照；所有終態及 init 失敗／解構都釋放鎖。暴露寫入後 changeCount 給腳本檢查。結束時僅在仍為本次 changeCount 時還原；其他內容保留並警告。NSPasteboard 沒有跨程序 CAS，明示最後檢查與寫入間的競爭、SIGKILL／程序崩潰無法保證還原。

### 單一原生腳本

NativeUploadScript.make 接受 selector、absolute path、fileSize、modificationTimeMilliseconds、clipboardChangeCount、window（可選 index）、timeout 與 nonce。target preparation（包含 System Events recovery 與依 stable window ID 切換指定 tab）在排他 lease 內。Swift 在 spawn 前計算 absolute uptime deadline，從原本的程序 timeout 內預留 min(3 秒, timeout/4) 給 best-effort cleanup；外部 watchdog 不延長。腳本先固定 window ID、目前 tab 的頁面 nonce 與 URL，確認沒有既有 sheet；啟動 input 前檢查元素為 file input。所有 AX 動作只指向該視窗的唯一原生 sheet，檢查前景、頁面身分、剪貼簿 changeCount 與單一 deadline。以 AXPress 開啟 Edit 選單、按唯一可用 Paste；選單追蹤期間僅使用 AX owner／title／sheet、clock 與剪貼簿檢查，禁止 Safari AppleEvent／JS；Paste 後對同一選單單次 AXCancel，成功後如仍需檔案確認則恢復完整頁面 owner 檢查；若已交付則轉為快照完成檢查。如 sheet 尚在且無巢狀 sheet，再按唯一可用具名 Upload/Open/上傳/打開/開啟。初始按鈕確認維持 #107 的 stderr trace，不送鍵盤、不碰 default button、不重試。

### 實際選取完成

在固定頁面上保留原 input 的 JavaScript reference，交付前逐次確認仍為同一元素及文件。本次捕捉 input／change 事件作為新選取證據，避免 Cancel＋舊匹配檔案誤判；未觀察新事件的相同檔案重選明確失敗且不清空舊 input。待 sheet 消失後，檢查事件當下 exactly one File 的快照，其 NFC 正規化檔名、size 與 lastModified（毫秒值允許 1 ms 精度差，或恰為朝零截斷到整秒的值；不接受一般 ±1 秒範圍）符合開始時檔案 metadata；交付前頁面／元素改變、事件快照數值不符或截止則失敗；可信交付後的同文件頁面處理依下方 R2 修正。metadata 是結果一致性檢查，並非所有檔案內容的密碼學證明；實測 fixture 另驗證內容。頁面私有 nonce 變數在可安全存取原頁面時清理。

## Implementation Contract

- CLI flags、JS 10 MB 上限與 native routing 保持；--allow-hid 作相容旗標，native 不再控制鍵盤。
- FileURLClipboard 在主執行緒使用，init(fileURL:pasteboard:) 預設 general，可用私人 pasteboard 測試；ownedChangeCount 為 Int；restore() 回傳 restored 或 preservedNewer，還原失敗拋出錯誤。defer／catch 涵蓋 script 錯誤與逾時。
- NativeUploadScript.make 為純 Swift script builder，字串使用既有 escaping 與 selector.resolveRefJS。前景／owner／deadline／clipboard 等拒絕均為明確 AppleScript error，交由既有有界 runner 傳回；沒有 HID fallback。
- performNativeUpload 是可測的實際生命週期：warning → 取得排他 lease／剪貼簿快照 → target preparation → 單一 script → restore。既有 NativeUploadEffects 改由這個流程取代；開啟面板不能留在先前獨立 JavaScript 呼叫。
- stdout 不新增除錯資料。stderr 先警告原生面板、焦點及剪貼簿干擾；具名按鈕 trace 由既有 runner 經控制字元清理後轉送。
- 測試先行：private pasteboard 多型別／錯誤／較新內容測試、script compile 與實際 interpreter 順序／錯誤傳遞、輸入結果判定。完整測試與實際特殊路徑、大檔、拒絕／逾時案例需完成，再進六方 review。

## Risks / Trade-offs

- Paste 有時直接接受、有時需確認 → 觀察同一面板是否仍在，至多一次具名確認。
- 焦點／剪貼簿共享 → 每次動作重新檢查；有不明結果即停，不補按 Return。
- metadata 相同不保證內容相同 → 明示限制，GUI fixture 檢查實際 bytes；本功能仍以使用者指定的 file URL 交給 native chooser。
- 原生對话框仍干擾使用者 → 保留精確 stderr 警告，不宣稱完全無干擾。

## Migration Plan

既有 CLI 參數維持；合併後使用新 native 流程。需要回復時回復本 PR 的 runtime 變更，保留實測紀錄；不在運行時默默切回 HID。

## Open Questions

無待使用者裁決事項；實作中若 metadata 或 Safari 操作觀察與設計不同，以新的實測修正 artifact 並記錄。

正常輪詢到期會先進腳本錯誤清理；清理 AppleEvents 各使用 1 秒上限。Stalled IPC、SIGKILL 或清理期間失去 owner 仍不能保證選單／頁面狀態被移除，這時不重送操作，需使用者檢查殘留面板。

本機公開 WKUIDelegate 無視窗測試提供真實 File：原樣本 1789595607627 ms 被回報為 1789595607000 ms；正負時間及秒邊界均呈現朝零截斷。NativeUploadWebKitTests 直接將真實 File 交給正式 validator，補足假 DOM 模型的缺口；此測試不涵蓋 Safari AX／選單整段流程。

## R2 審查修正

- 以 window capture listener 在一般 input／change handler 前保存第一次可信事件的檔案 metadata；事件當下仍檢查原文件、URL、selector、input 身分與模式。先前守衛維持於所有會再送檔案的 AX 動作；sheet 關閉後只讀取快照並檢查原視窗／分頁與文件 nonce，不再要求已消耗的 input 留在 DOM 或同文件 URL 不變。完整換頁仍因原文件證據消失而無法確認，不自動重試。
- 初始化及每次交付前 owner 檢查都拒絕 webkitdirectory；multiple 保留，仍只交付一個指定 regular file。這項拒絕不代表普通面板的非同步 Paste 時序已完成 GUI 驗收。
- 毫秒換算朝零取整，使負時間小數毫秒不先跨到前一個整秒；精確毫秒誤差仍限 1 ms，整秒表示仍要求完全相等。
- 無視窗 WebKit 回歸測試實際包含同步清空 input、替換 input、更新 URL 與負時間邊界。這些測試不操作 Safari、AX 或 Print。

## R3 事件順序與關閉等待

先監聽可信 input，再以 change 作為相同 listener 的第二個入口，兩者共用第一次交付快照。Paste 後先讀完成結果；若已交付，即使 sheet 尚在也不再按 Upload。確認後的等待只有視窗／分頁、前景、原面板單一／無巢狀檢查，不重新要求 input／URL 維持交付前狀態。普通面板的選取就緒證據仍需 GUI 實測，不能把固定延遲或事後檢查當成事前證明。

## #169 確認前選取證據

### 有界原生選取讀取器

NativeUploadSelectionProbe.check(windowID: Int, expectedPath: String, deadlineUptime: Double) -> String 回傳 MATCH 或明確非成功狀態。C AX 僅執行讀取，不含 AXPress。透過 BoundedAXWorker 每次最多 0.8 秒、每次 IPC 不超過剩餘額度，最多 256 節點、18 層、32 視窗及每個結構陣列最多 64 個元素；AXCopyAttributeValues 的 count 查詢必須先限額，避免一次配置無界 children。明確驗 Safari 前景、CGWindowID、唯一 open-panel；搜尋只沿有限結構節點，不展開 AXWebArea、sidebar 或未選取 rows。ColumnView 經 columns／contents／selectedChildren；ListView 經 selectedRows；IconView 經 selectedChildren。葉節點必須帶 AXSelected=true 及 file-reference/path URL；file-reference 以 NSURL.filePathURL 解析。每個檢视群組先核對選取數量；祖先資料夾不是最終選取，多個選取或多個候選檔案一律拒絕。結果要與 canonical absolute regular-file path 完全一致；必要的檔案系統查詢留在唯讀 worker、受外部程序 watchdog 約束。測試使用 provider adapter 重現三種模式與大小／深度／時間／歧義邊界。

### 固定請求的內部上傳 worker

NativeUploadRequest 為 Codable/Sendable，欄位為 version=1、selector、path、fileSize、modificationTimeMilliseconds、clipboardChangeCount、window、timeout、nonce、windowID、tabIndex、deadlineUptime；含 parent image UUID 的隱藏 __native-upload 入口只接受一筆至多 128 KiB 的 base64 JSON。驗 schema、合理長度／範圍、穩定 windowID/tabIndex、剩餘 deadline、實際父程序 proc_pidpath 與自身 executable 相同、parent image UUID 等於目前載入 image，才接觸剪貼簿或 UI。固定 builder 於 child 主執行緒產生腳本；絕不接受任意 AppleScript source。橋接 class SBNativeUploadBridge 使用 TaskLocal request context；selectionForWindow: 只允許 request 綁定視窗和路徑。logger 明確寫 stderr 以保留既有確認公告。worker 不取得第二份 clipboard lease；parent 持有原 lease 至 child 結束。直接 shell 呼叫或不符身分的 child 在 UI 前失敗。版本 guard 不是 macOS 權限替代品，父程序路徑 guard 也不宣稱防禦惡意同使用者程序。

### 原生證據與確認整合

保留 performNativeUpload 的生命週期，以 NativeUploadRequest 傳遞固定參數。NativeUploadScript.make 的正式 builder 在具名確認前呼叫 SBNativeUploadBridge，非 MATCH 一律不確認；有限輪詢只重讀，不重送 Paste。每轮先讀交付狀態，已交付直接進唯讀完成階段。原有 verifyUploadPanel 在 probe 前後保留，最後 native MATCH 後立即作 clock／clipboard 檢查再 AXPress，盡量縮短非原子間隔。控制流程 adapter 測試明確證明未知／歧義／剪貼簿變更／已交付不送確認。父程序沿用 runShell 逾時與 MCP owned group，child trace 用 #167 schema 驗證後合併，診斷不包含重複 trace；元素不存在及 timeout 維持既有對外錯誤。

實測證據：ColumnView 82 節點、ListView 35 節點、IconView 28 節點均讀出自有隱藏 Unicode／空白／單引號路徑。先切模式後 Paste 的列表／圖像探測 files count=0，偏好、剪貼簿及視窗清理完成。這只證明讀取拓樸，完整上傳與效能驗收仍是 3.1／3.2 的未完成工作。
