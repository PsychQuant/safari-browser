## Context

#110 的 MCP façade 已驗證並合併，這個分支先將其完成的四項規格同步到 mcp-cli-facade。MCPSession 目前只有一個 business-call slot；MCPProcessRunner 每次 posix_spawn 新 __mcp-exec、保留 group leader 到最後訊號後才 reap。stdio pump 與 tool worker 分離，故 discovery、取消及輸出背壓不能因常駐化而退化。

基準與量測定義見 proposal。診斷實驗限定 wait 0，三份暫時修改的原始碼均已 byte-for-byte 還原。約 0.18 ms 是 spawn syscall，不能把 30 ms 都稱作 spawn；可重用程序主要避免約 5 ms loader、外層解析及約 12 ms 退出／回收，CLI 內層解析仍約 10 ms。

## Goals / Non-Goals

Goals：正常工具呼叫重用實際 CLI worker；保留全公開 catalog／parser／命令行為、單筆執行、每筆狀態／stdio 隔離、取消與不重播；加入 idle retirement、crash 後下一筆重建及暖 worker 的磁碟版本失效。使用同一 build 的 isolated/persistent 量測 cold/warm p50/p95 與成功率。

Non-Goals：不將 MCP 轉派給普通 daemon、不複製 CLI 業務邏輯、不跨 request 快取 Safari／AX／目標狀態、不保證取消回滾既有效果、不新增公開 MCP tools、網路傳輸或 TCC 權限。SIGKILL 與檔案 syscall 的核心排程不能宣稱硬即時；userspace 的等待必須有截止，無法證明清理時回報不完整，不能偷偷接納更多 worker。

## Decisions

### 常駐 pair 與單一接納

MCPCommand 預設使用 MCPPersistentRunner；新增 --worker-mode persistent|isolated（預設 persistent）及 --worker-idle-timeout（預設 30 秒、有限且在 0.001...86400）。isolated 是明確選擇的比較／相容模式，不是失敗後重試。

每個 host 最多一組 supervisor + actual worker，仍只有一筆 business invocation；MCPSession 的 busy 拒絕維持。runner 在自己的單一 I/O owner 上序列化 PID、fd、start/run/retire；取消只提交停止意圖並喚醒 owner，不能從其他執行緒任意 close 或 reap。新 request 若碰到正在退休的 generation，必須先等其有界清理或得到 not-executed 失敗；不開第二組來掩蓋清理失敗。

host 實作補充：取消以鎖保護的 intent 傳遞，I/O owner 透過至多 10 ms 的 poll 間隔及每輪有界 drain 重驗。這是上述喚醒／停止處理的具體機制，不從 cancellation callback close FD 或 signal PID，也不另添可與 close 競爭的 wakeup descriptor。Busy admission 在入 I/O queue 前拒絕；完成後先釋放 admission，呼叫端才收到結果。

idle timer 由 host 管理，generation 綁定；新 request 取消舊 timer，期限到且仍 idle 才退休。worker 崩潰、協定失效或不適合重用時，當筆不重播，下一筆才新建一組。MCPCommandRunning 增加有預設空實作的 async shutdown，MCPSession 在 EOF／output failure 時同時清理 active 與 idle worker。

### 監督程序與存活管線

只靠 worker 自己觀察 parent exit 無法涵蓋 SIGSTOP 或不回應的執行程序。因此 host 用 POSIX_SPAWN_SETPGROUP 啟動 __mcp-supervise，pid 同時是專屬 PGID；supervisor 不執行任何 CLI，另以同 executable 啟動 __mcp-worker，明確繼承這個 group。一般 CLI 子程序沿用 MCPCommandProcess 的 group 繼承；使用者明確啟動的 daemon 仍自行 setsid，不受 request cleanup 影響。

host 保有 lifetime pipe 的唯一 write end；supervisor 只拿 read end，在獨立 dispatch source 觀察 EOF。host 被 SIGKILL 時 OS 也會關閉 write end；supervisor 不依賴卡住的 actual worker，對自己的 live PGID 發 SIGKILL。write end 不得被 supervisor／worker／後代繼承。supervisor 先確認自己是 group leader、父程序與預期相符，才啟用這條路徑。

私有 fd mapping：control socket 3；supervisor lifetime-read 4；supervisor exit-status-write 5。actual worker 只繼承 control 3 與 bootstrap stdio；4、5 及 parent 的 pipe write end 都不傳入。所有來源 descriptor 預先保留在 6 以上，避免 dup2 target 與 close action 衝突。supervisor 在 worker 退出後，以固定 12-byte status record（magic、workerPID、wait status，各 32-bit little-endian）回報，再終止其餘 group；host 不把 supervisor 的 signal status冒充 CLI exit code。

host 對 group 的訊號只用自己 posix_spawn 得到、仍 live／unreaped 的 supervisor PID。最後 group signal 在 waitpid 釋放 reservation 前發出；ECHILD／失去 reservation 時不再 signal。清理保留 SIGTERM、150 ms grace、SIGKILL 與有界 drain／exit observation；若無法在 cleanup budget 內確認，回報 failure、保留尚未退休的 owner，禁止再 spawn，不能宣稱已清乾淨。

實作驗證補充：在本機，已退出但尚未 reap 的群組收到 signal 可能回 EPERM。這個 errno 本身不是清理成功證據；owner 保留 reservation，以有界 proc_listpids／proc_pidinfo snapshot 確認群組已無其他執行中成員，才 reap。snapshot 超過 4096 個 PID 或無法讀取成員時保守回傳未確認。retire 每輪開始重驗 userspace deadline，逾時保留同一 owner，後續呼叫延續原 TERM／KILL 狀態。

runner 實測補充：waitid 的 si_pid 非零不是退出證據；只接受 CLD_EXITED／CLD_KILLED／CLD_DUMPED，CLD_STOPPED 保留為尚未退出。第一次 KILL 後若仍觀察到 live group members，在 leader reservation 尚未釋放時繼續 group KILL；確認 quiescent 才 reap。固定 cleanup deadline 到期保留 pending owner，後續呼叫不得用新 pair 掩蓋它；ownership lost 則永久停止該 owner 的 signal。

閒置 worker 的控制通道若在下一筆任何 byte 送出前已 EOF，可清理舊 generation 後為該新請求建立一組；送出任何 byte 後的 crash／partial／wrong-id 則只回報不完整，不重播。不同 image、缺檔或解析失敗會使此 runner 持續要求 restart，即使稍後路徑恢復。Termination record 是 worker process 的診斷，不得覆蓋 valid complete 的 business exit code。

### 私有有界協定

MCPWorkerWire.swift 使用 JSON-lines；stdin 以 canonical base64 放在 request，CLI 輸出以帶 id 的 output chunks 回傳，絕不拿原始 stdout 當控制 frame。parent request 最大 8 MiB；server frame 最大 64 KiB；stdin 最大 4 MiB；單 output chunk 最大 8192 bytes。每筆用 parent 產生的 UUID，輸出及完成訊息須完全對應，未知／過期 id 不得套到下一筆。

固定型別：ClientMessage.request(id: UUID, arguments: [String], input: Data)、shutdown；ServerMessage.hello(image: String, workerPID: Int32, supervisorPID: Int32)、output(id: UUID, stream: stdout|stderr, bytes: Data)、complete(id: UUID, exitCode: Int32, reusable: Bool)、retire(id: UUID, reason: descendants|io|scope|image, exitCode: Int32?)。protocol version 固定文字 "1"，PID／exit code 在 JSON 內用 canonical decimal string，避免 Foundation numeric coercion。codec 用單次 typed 解讀、closed keys／enums，拒絕 NUL argv、非法 base64、數值型別／範圍及長度；錯誤不回顯 request。

API：encodeClient/decodeClient、encodeServer/decodeServer；輸入／輸出 Data 均不含 LF，framing 層負責 LF。MCPWorkerWire.TerminationRecord 提供固定 record encode/decode；reported PID 僅供關聯／診斷，不作 host 發 signal 的授權。

host 只在有效 complete 及此前所有 output chunks 完成時回報 capture_complete。控制 frame 中斷、丟失、錯 id 或 worker 崩潰都保留 unknown／incomplete；已寫入任何 request byte 後不得重播。output bytes 在 host 保留每流上限 2 MiB，超量立即退休 group，保存已捕捉 prefix 並標 truncated。

### CLI request scope 與 stdio 封閉

worker 每筆都以 SafariBrowser.parseAsRoot 建立新的 command struct；抽出不退出 process 的 CLI 執行／錯誤格式化邊界，普通 main 與 worker 共用，保留 help、validation、glued-flag hint、stdout/stderr 及 exit code。persistent 入口拒絕 MCP 自身與 hidden commands；原 __mcp-exec 仍服務 nested daemon start 與 isolated 模式。

control FD 3 與 CLI 0/1/2 分開。worker idle stdio 指向 /dev/null；每筆建立 private stdin/stdout/stderr pipes，dup2 後關閉多餘 ends。stdin feeder 在背景提供有界 input，結束即 EOF；兩個 relay 同時讀 stdout/stderr，每次最多 8192 bytes，透過序列化 control writer 傳送 token-tagged chunks。命令結束／error formatting／trace emission 後 fflush，將 stdio 還原到 idle null、完成 feeder 與 relay，才送 complete。setup 或收尾失敗不接受下一筆，retire frame 後由 host 清理 group；不以不完整輸出冒充成功。

stdio owner 在 process lifetime 只能建立一次；以獨立 relay-owned descriptor 避免 timeout 後從外部 close 尚在使用的 fd。seal 以 dispatch completion 與預設 1 秒 deadline 仲裁，不阻塞 Swift cooperative executor；任一路徑失敗永久停用同一 owner。在綁定新 pipes 前，先把 idle 期間的 libc output flush 到 null；這不代表未知 live writer 已被安全 join。除了 FD 置換，也清除 libc stdin 的未讀緩衝與 EOF 狀態，避免留下上一筆 input。

每筆新的 MCPInvocationContext 包含新的 BlockingDialogGate 與 PerformanceTrace collector；shared gate 在這個 context 下解析，不能借用 processGate 的先前快取／warning budget。SafariBridge 的 subprocess watchdog 與 System Events waiting-message task 在 persistent context 下 cancel 後等待真正結束，避免晚到 stderr 跨越 stdio boundary。既有 GCD pipe readers 已在返回前 join。

BoundedAXWorker 增加只讀 quiescence 查詢；若 command 返回時仍有 AX 工作，完整結果可回傳但 reusable=false，整組退休，絕不把未完成工作交給下一筆。背景 AX 只觀察而不按按鈕的既有契約維持。若 group snapshot 不能確定只有 supervisor／worker，回報 retire，不把未知後代的輸出當完整；正常 helper 已 wait/reap 才允許重用。新增可能晚到的工作必須納入這個 request 邊界，不能只清掉計數假裝完成。

### Executable 身分與原 argv 邊界

MCPExecutableIdentity.swift 將既有 thin Mach-O UUID parsing 共用化，新增有界 file probe（含 FAT32/FAT64 與當前 loaded architecture 選擇）。MCPWorkerContext.imageIdentifier 的既有 API／拒絕條件保留；readImage(at:architecture:) 只讀有界 header/load commands，不執行檔案，不把 UUID 當 code-signing 認證。拒絕截斷、溢位、重複／含糊 slice、未知格式，支援原始 launch path 的 symlink retarget 觀察。

host 在每次 dispatch 前檢查磁碟 image 與 catalog loaded image；worker 在執行前再驗 loaded／disk 身分。worker-only 失效以 typed retire(image) 回報；host 收到即設定 sticky invalidation。失效即退休並回報既有 executable-changed／not-executed 指引，要求 restart MCP host；不把舊 catalog 轉派到新引擎。檢查與後續檔案替換不是原子交易，但執行的 loaded worker image 永遠與 catalog 相同。

常駐內部 framing 不能無意擴大或縮小原 OS argv/environment 的極限。以 argv／environment UTF-8 bytes、NUL 與 pointer storage 的保守估計決定路徑：接近 ARG_MAX（估計超過其一半）的 request，在任何私有 request byte 送出前退休 cached pair，交由原 MCPProcessRunner 執行一次，保留 kernel 接納與錯誤。私有 base64／JSON 編碼膨脹超過 frame cap 時，也只在零 byte 送出前選原 runner，以免收窄合法的 public input。兩種預先選路均沿用 admission 時的 absolute deadline，原 runner 在 spawn 前與執行迴圈重驗，不重新取得完整 timeout。此為預先選路，不是錯誤後 fallback；不把全部常用指令留在 one-shot 路徑。顯式 isolated 模式也沿用原 runner。

### 效能與完整驗收

同一 build 的 isolated／persistent，固定無 GUI fixture、相同 samples/warmups/deadline，分開比較 cold host 和 warm host。主要報告 trace off p50/p95、成功率及 actual worker PID 重用；trace on 另測觀測成本。要以成功率不退化及 warm p50/p95 改善證明收益；cold 啟動新增 supervisor 的代價如實列出，不承諾每個場景都變快。

#110 現有 77 個 public help／schema、實際 sync/async、stdin、取消、busy/ping、EOF、unread stdout、nested group、explicit daemon detach、binary replacement 全部保留。新增 idle、idle/call race、worker crash／partial reply／wrong id、不重播 marker、重複 requests state/stdio 隔離、large-argv 預先選路、暖 worker replacement 與 supervisor lease EOF。

controller-death fixture 用真實 controller process 持有 lifetime writer，測試 custodian 仍擁有 supervisor direct child 以便安全清理；殺 controller 並停住 actual worker，須觀察 worker 真正終止。這測同一個 EOF primitive，避免失敗時對已失去 reservation 的孤兒 PID 盲目發訊號。完整 MCP host 的正常 EOF／取消／背壓另跑 end-to-end；測試報告清楚區分層級。

## Implementation Contract

- 公開：mcp --worker-mode persistent|isolated，--worker-idle-timeout，原 --timeout／MCP schema 不變；default persistent，只有一個 business slot。runner shutdown 能回報未確認清理的固定 failure。
- 私有：__mcp-supervise／__mcp-worker 都 hidden；control 3、lifetime 4、status 5；健康 worker 真正執行多筆 CLI，不是常駐 broker 包住每次新 CLI。
- stdout/stderr 是 token-tagged binary chunks，只有 valid complete 能宣告完整；parent 的 2 MiB／4 MiB／8 MiB 上限維持。取消、EOF、大小錯誤、partial reply 一律不自動重試。
- 所有 signal、close、reap 有唯一 owner；最後訊號在 reservation 釋放前，parent death 清理不依賴 actual worker 執行緒。未確認清理不清空 registry、不接納第二組。
- 新 helper 的 API 與上述訊息／身分契約是 apply 的依據；integration 若揭露矛盾先 ingest，不靜默降低驗收。
- PR 與所有提交引用 #172。完整測試、效能對照、變異與六方審查通過後才 verified；本項不宣稱新的 Safari GUI 驗收。

## Risks / Trade-offs

- [兩個常駐程序的 cold／記憶體成本] → lazy 啟動、30 秒 idle 回收；與節省的 warm 成本一起量測。
- [共用 stdio 或晚到 callback 污染下一筆] → 每筆 private pipes、flush/seal/join、request gate/trace，不能證明 quiescence 就退休。
- [host 死亡、worker SIGSTOP] → 不執行 CLI 的 supervisor 觀察唯一 lifetime pipe EOF，清理自己的 live group；write end 不被後代繼承。
- [PID/fd 重用] → owner 序列化、保留 leader 到最後 signal；異常失去 reservation 時停止 signal 並回報 failure。
- [CLI parsing 仍占約 10 ms] → 不以不完整重新解析或 command-object cache 換取表面速度；先交付有實測支持的生命週期改善。

## Migration Plan

先保留 isolated engine 與回歸基準，完成 codec／identity／supervisor／scope／runner，再切換 default persistent 並跑全部兩模式對照。失敗路徑不自動降回 isolated；operator 可明確選擇模式。舊 MCP 呼叫格式完全不變，hidden helpers 不加入 catalog。

## Open Questions

沒有需要使用者裁定的產品歧義。平台／lifetime 假設仍須由真實 owned-process fixtures 證明；量測實驗不是已完成的 worker。若 host／supervisor 自己被外部停止或核心不讓行程退休，必須如實記錄清理未確認，不宣稱無條件硬即時。

## R2 整合修正：一次性預選也受監督

此節補足「Executable 身分與原 argv 邊界」中「交由原 runner」的實作缺口：保留的是原 kernel 接納與新 CLI instance，並非保留無 supervisor 的生命週期。`1e0ad62` 的原 runner 不符合完整清理契約，不能作為最終驗收基準。#209 的 ownership 修正與 #172 序列整合。

### 保留 kernel 接納的 bootstrap

採用與原 one-shot 完全相同的 argv 及等位元組數的環境，先由同 executable 的私有入口啟動不執行業務的 supervisor。利用既有 `SAFARI_BROWSER_MCP_DIRECT` 的等長私有值區分 bootstrap 與真正 CLI，不能為監督功能另加 argv 或 environment 欄位。父程序身分以 inherited control FD 的固定有界 metadata 傳入；lease／status 沿用獨立 descriptor，不在參數內傳遞大型輸入。supervisor 必須驗證 descriptor 型別、預期父程序及自有 group，啟用 lifetime monitor 後才 spawn 真正 one-shot。真正 CLI 恢復原 direct context、相同 argv/environment 並保留 image guard。

這個選擇須先用原 kernel 邊界的接受／拒絕對照證明；若 bootstrap 會改變接納邊界，該實作不合格，不能調降公開上限。custom executable／workerPrefix 測試必須明示 supervisor executable，不能從 XCTest host 猜測程式位置。沒有增加公開 tool 或允許由 MCP caller 選擇 executable。

Bootstrap 實測補充：Foundation 會在 main 之前新增 `__CF_USER_TEXT_ENCODING`，直接把 supervisor 的 `ProcessInfo.environment` 傳給 child，會在原 kernel 邊界多出位元組而失敗。因此 FD3 先傳固定16-byte header（magic、parent PID、absolute deadline），再由 host 的同一 I/O owner 以非阻塞 write 傳遞原環境的 JSON string dictionary（最多8 MiB），EOF 封閉快照。Supervisor 先驗證 header／父程序並啟動獨立 lease monitor，再有界讀取環境；真正 child 使用這份快照，不使用已被 runtime 擴增的 environment。FD3／4／5 不傳入真正 CLI。child spawn 在配置argv後再次檢查同一deadline。

實測以直接 posix_spawn 的真正 CLI 找出 kernel 接納／拒絕相鄰邊界，再對照新 runner；空padding及8192-byte環境padding皆一致。初版沿用 supervisor environment 確實在邊界失敗，修正及退回快照的變異均由同一測試識別。Private context value只在helper階段使用2，真正CLI恢復1，字串位元組數不變。

### 一次性 owner 與狀態回傳

`MCPProcessRunner` 需委派至可跨呼叫存活的 serial owner；取消只發布 intent。owner 使用同一 reservation 的真退出判讀、重複 group 清理與非阻塞 reap。清理截止後保留 pending owner並拒絕新工作；lost ownership 永久停止訊號。所有啟動中途錯誤也要退休或保留已建立的 child，不遺失責任。

stdin／stdout／stderr 繼續獨立傳送，真正 CLI 的退出狀態透過固定 status record 傳回；supervisor 的終止碼不得冒充業務結果。absolute invocation deadline、原 capture cap、busy／cancel／EOF／shutdown／daemon detach 皆套用於預選及 explicit isolated。host 死亡後 monitor 必須清除實際 one-shot，而不是只觀察 host 已退出。

### 驗收及依賴順序

先固定原 runner 的 stopped／host-death RED，再驗 bootstrap kernel 接納與 lease／status，接著整合 pending ownership，最後跑所有正式呼叫端與 custom fixtures。private expansion 測試固定小環境，確保測到編碼膨脹而非先被 ARG_MAX 分支選走。修正後重新建置 release 並做兩模式交錯比較；先前數值保留為歷史，不套用到新 runtime。任務3.3必須在新增4.x驗收完成後才可完成。
