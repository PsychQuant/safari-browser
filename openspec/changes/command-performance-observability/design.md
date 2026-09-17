## Context

#167 建立可比較的量測，供 #168–#172 使用。CLI 與 MCP workers、daemon handlers 是不同請求生命週期；NSAppleScript cache 僅能在 main actor 操作。main 前的 loader 成本只能靠外部 wall-clock 觀察。

## Goals / Non-Goals

Goals：預設無輸出變更，顯式啟用後取得有界、不含操作內容的 request-local 計時；可重跑 cold／warm 情境並保留失敗／SKIP。

Non-Goals：不在本張改快取策略、刪除 UI 檢查、建立 worker pool、重播操作或更動安裝的 binary。原生上傳新路線在 #101／#169 完成前不列為本分支可重複操作的 benchmark。

## Decisions

1. `SAFARI_BROWSER_TRACE_TIMING=1` 才啟用。每次 CLI request 產生 collector，以 TaskLocal context 傳遞父 span；跨 DispatchQueue 明確攜帶 context。預設不取 timing clock、不建立 collector、不輸出摘要。
2. 一行 stderr 前綴 `[safari-browser timing] ` 後接 JSON。schemaVersion=1；requestID 為新 UUID，producer 附 processID（正的 Int32）供外部 benchmark 辨識 root／child；單筆舊 summary 可缺省；status=`ok|error`；totalNanoseconds 為 main 入口之後的 elapsed；spans 至多 64 筆，按 id 排序；droppedSpans 為有界飽和計數。每個 span 只有 id、可省略或 null 的 parentID、phase、durationNanoseconds、outcome=`ok|error|unfinished`。
3. phase 是固定白名單：`command`、`target.resolve`、`target.native`、`applescript.direct`、`applescript.daemon`、`applescript.inprocess`、`process.spawn`、`process.wait`、`file-dialog.run`、`ax.wait`、`ax.inspect`、`daemon.request`、`daemon.compile`、`daemon.execute`、`daemon.cache_hit`、`exec.run`。不接受自由文字 tag／error message，不能將 source、URL、selector 或檔案路徑混入。摘要上限 64 KiB。
4. root finish 只輸出一次；尚未完成的子 span 標 unfinished，晚到 worker 結果不再改動已輸出的紀錄。父子時間是 inclusive，不相加作為總耗時。測試注入 monotonic clock，但正式實作用 DispatchTime。
5. `daemon __serve`／`mcp` 常駐 host 不建立跨請求 collector；子 CLI worker 各自建立。daemon 的 `applescript.execute`／`exec.runScript` 接受 optional literal-Boolean `timing`，只有 true 啟用個別 handler collector；response 可附 `timing` 摘要。舊 server 沒有 metadata 視為 unavailable，不為取得計時而重送。
6. client 匯入 remote summary 時只接受同 schema、白名單 phase、合法父子關係／有限非負數及筆數上限，重編 id 掛在當次 RPC span。缺失／格式錯誤只影響 telemetry，不改命令結果。服務端 compile／execute 由 main actor 同步 span 量測，cache hit 另標示；不記 source/key。
7. benchmark 為 `scripts/benchmark-performance.py`，只提供固定唯讀／零等待情境：startup help、wait 0、exec wait batch、自己的 daemon namespace 與 MCP wait worker；GUI get-title／get-url 另需 `--live`，只建立並清理自己的 localhost fixture。不得接受任意修改命令重複執行。沒開 GUI 模式或環境不足列 SKIP；禁止 Print。
8. benchmark 用外部 monotonic wall time，fresh-process 與 warm service 分開命名；不宣稱已清除 OS 檔案快取。輸出 executable digest／OS build／architecture、樣本數／warmups、每次狀態、nearest-rank p50／p95、trace 摘要與 SKIP 原因。exec 可轉送多個 child trace，benchmark 以實際 Popen.pid 選 root，不猜時間最大或最後一筆。stdout 丟棄，stderr 有界讀取，只保留經 schema 篩選的 timing 資料，不輸出實際 fixture URL／私人 executable 路徑。逾時只清理自有 process group／namespace，結果未知不重試。

## Implementation Contract

核心位於 `Utilities/PerformanceTrace.swift`：同步／async span wrapper 必須只執行 body 一次並保留原回傳值／錯誤。collector thread-safe，但不持有 Safari／AX node；測試可傳入 clock／sink。CLI、bridge、router、AX worker、daemon 與 exec 只加計時 hooks，不改原有決策。

測試先以原 CLI 在 env=1 缺少摘要重現，再驗證預設關閉、成功／錯誤、並行隔離、事件上限、晚到 worker、remote metadata 畸形不改結果、daemon profile 不跨請求、stdout 與 public MCP catalog 不變。Benchmark 的統計、timeout/group cleanup、redaction 與 SKIP 使用 fake executables／protocol fixtures 測；真實執行用受限場景。

## Risks / Trade-offs

計時與監測本身有成本，保留 on/off 對照。程序被強制終止時不保證 final summary，報告須保留 missing。服務端無新 metadata 時只呈現 transport wall time。GUI availability 及使用者搶焦點會影響成功率，不能刪掉失敗樣本。64-span 上限可能截斷大量 polling；droppedSpans 必須顯示。資料最小化採白名單而非事後刪字。
