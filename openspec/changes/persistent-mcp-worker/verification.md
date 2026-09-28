# 元件實作證據（2026-09-28）

目前完成 tasks 1.1、1.2、1.3、2.1、2.2、2.3、2.4、2.5、3.1、3.2（10/11）；其餘未完成。這份紀錄不是完整 #172 驗收，目前開發分支的 public MCP 已預設 persistent；仍待同 build 效能驗收與最終獨立審查。

## 私有 wire codec（1.2）

- Stub 可編譯，初始 8 tests 出現 25 次預期行為失敗。
- 最終 10 wire tests 通過：literal fixtures、closed shapes、UUID／decimal／base64、精確 frame／stdin／chunk／argv 邊界、截斷與任意 binary output、12-byte termination record。
- 8 項變異均被抓到並還原：frame limit、closed fields、decimal、base64、raw LF、stdin limit、chunk limit、termination status。
- UUID request 關聯與 partial-stream 狀態仍由未完成的 I/O owner 負責；codec 不假裝已有 session 生命週期。

## Executable image probe（1.3）

- Stub RED：11 個 identity tests 出現 17 次預期行為失敗，既有 4 個 worker tests 仍通過。
- 最終 15 個 identity tests 與原 4 個 worker tests 通過；包含實際 loaded executable、8 GiB sparse file、超過 32-bit offset、精確邊界、symlink retarget 與 atomic replacement。
- 8 項變異均被抓到並還原：filetype、CPU type、duplicate UUID、slice count、command budget、overlap、duplicate architecture、legacy acceptance。
- CPU type 變異最初揭露測試缺口；補上相同 subtype／不同 CPU 的 fixture 後確實 RED，再還原 GREEN。
- 舊 thin parser 的接受範圍與固定錯誤保留。UUID 不代表簽章認證，也不保證後續路徑替換與執行原子化。

## Supervisor／PID reservation（2.1）

- Stub 可編譯，4 個初始程序測試均因未實作的 launch 行為失敗。
- 最終 9 個 supervisor tests 通過：worker 繼承 group、私有 lease/status descriptor 不繼承、控制程序 SIGKILL、已確認 SIGSTOP 的 worker 與一般後代真正終止、另一 owned group 不受影響、actual worker exit status、失去 reservation、短 cleanup deadline、重複 close 的 fd 重用、bootstrap EOF、錯誤 parent、父程序 stdio 已關閉時的 fd mapping。
- 使用同一份 production supervisor／launcher 編譯獨立 fixture；測試 custodian 持有 supervisor 的 direct-child reservation，另一個 controller 獨佔 lifetime writer。這是 production EOF primitive 的真實程序驗證，不冒充完整 MCP host SIGKILL 端到端測試。
- 初版在已退出群組的 signal EPERM 上失敗；改以 reservation 及群組已無執行中成員的 snapshot 證據決定能否 reap，沒有單靠 errno 宣告成功。
- 短截止測試揭露晚醒後仍再做清理的問題；每輪先檢查 deadline，pending 保留尚未 reap 的 owner，可再接續清理。程序可能已成為 zombie，pending 不表示程序必須仍執行。
- 5 項變異均被抓到並還原：停用 lease monitor、錯置 worker status、移除 parent identity、保留 bootstrap streams、遺失 reservation 不記錄 terminal state。
- Parent identity 變異最初存活；補上合法數字但非實際 parent 的案例後抓到，保留原非法 PID 案例。

## 元件階段局部回歸（bf6b7b2）

在上述最終原始碼執行 `swift test --filter MCP`：99 tests，0 failures。`git diff --check` 與 Spectra validation 通過。

此階段的後續隔離與 hidden command 證據見下文；persistent runner、公開模式切換與整體驗收仍未完成。


## Request scope／CLI／stdio 元件（73bbb72 階段）

73bbb72 當時先保留 task 2.2 未勾選，等待 worker 迴圈的 AX quiescence 不重用決策；該整合現已完成，見下節。

- `MCPInvocationContext`：每次建立獨立 gate／trace；gate 優先序為 daemon request、MCP invocation、普通 process。成功與錯誤路徑均 cancel 並 await 已知輔助工作；一般 CLI 保持原 cancel-only 行為。SafariBridge 的 watchdog 與 System Events waiting-message 已接上此邊界。
- `BoundedAXWorker.isQuiescent`：只讀狀態，不因呼叫端 timeout 提早重設 allowance。測試以受控背景工作證明真正返回前仍不可重用。
- `CLIExecution`：普通 main 與 persistent 執行共用 parser／run／diagnostics；只有 main 退出程序。保留 help、validation、silent ExitCode、glued-flag hint 與 trace 格式。Persistent 模式拒絕執行 hidden/MCP commands。
- `MCPRequestStdio`：一個 worker process 只有一個 stdio owner；每筆獨立管線、4 MiB input cap、兩個 8192-byte relay 與 stdin feeder。清除 libc stdin 殘留／EOF，flush 後轉回 null，非阻塞地等待 relay 全部結束；output failure 或 seal deadline 未完成永久拒絕該 owner 的後續呼叫。Relay 自己關閉 descriptor，不從其他執行緒關閉尚在使用的 fd。
- Scope 的 owned RED：14 tests／15 個行為失敗；CLI stub RED：4 tests／22 個失敗；stdio stub RED：5 tests／20 個失敗。各自實作後 GREEN。最終相關範圍 141 tests 通過。
- 11 項新增變異全部被抓到並還原：gate isolation、auxiliary join、AX quiescence、diagnostic newline、stdin purge、stdout flush、poisoned reuse、input cap、relay join、writer failure、process lifetime claim。
- 使用重構前後兩個實際 executable，比較 90 條公開 help 路徑與 8 個其他案例：98/98 的 stdout、stderr、exit code 完全相同。這是此次 CLI 入口抽取的比較；後續新增明示 MCP 模式選項與 hidden metadata 時，需另按預期差異驗證。
- 原 `Tests/mcp-stdio.py` 10 項端到端測試通過（含 77 個公開 tool help、stdin、cancel／EOF／backpressure、nested group、explicit daemon、binary replacement）。目前仍使用原 isolated runner，不把它當作常駐 backend 的驗收。
- 還原所有變異後 `make test-all` exit 0：1,516 XCTest、38 Swift Testing、66 smoke；簽章 49 PASS／2 SKIP（缺少所需簽章身分）。GUI harness 明確 SKIP，沒有新的 Safari GUI 驗收。

此階段的下一步是 worker 整合，結果見下節。Public MCP 尚未改成 persistent，沒有新的效能改善宣稱。


## 實際 worker 迴圈（完成 2.2／2.3）

- 註冊 hidden `__mcp-supervise`／`__mcp-worker`，沿用 production supervisor 的 group／lease／status pipe。Worker 驗證 parent／PGID／私有 socket，將原 control FD 標記 CLOEXEC，bootstrap stdio 在 ready handshake 前釋放。
- `MCPPersistentWorkerLoop` 是 production 實際使用的單筆執行迴圈：typed frames、UUID-tagged output、每筆 image guard、capture 全部收尾後才 complete；stream／execution failure 或未確認的 descendants 產生 retire 並停止取下一筆。AX 未 quiescent 則回傳當筆完整結果、reusable=false 並結束 worker。
- `MCPWorkerControlWriter` 的鎖涵蓋整個 frame 的全部 partial writes。最多兩個 relay 同步背壓，不用每 chunk 新建非同步 task queue。I/O 失敗後停用 sender，peer 斷線不觸發 SIGPIPE。
- Actual binary 的初始 RED：3 tests 因入口尚不存在而失敗；loop stub RED：4 tests／6 failures。實作後全部通過。
- Actual binary 證據：20 次 `wait 0` 的 trace PID 全部等於 hello 中的 actual worker PID，且 20 個 requestID 不同；77 個公開 tool help 都由該 worker 執行。help／exec invalid+valid stdin／負值 wait／hidden recursion rejection 後，下一筆正常命令沒有殘留輸出。
- Actual binary 證據：暖 worker 的 private executable copy 原子替換為另一 LC_UUID 後，下一筆 code64、not-executed/restart 指引、reusable=false、control EOF；沒有重播。Malformed／partial frame 終止，bootstrap EOF、缺少 lease context、錯 parent／PGID 的拒絕也通過。
- 分層故障證據：production loop 使用真正的 BoundedAXWorker 受控未完成 read，回覆 complete(false)，排隊的第二筆保持未執行；另外注入未封閉 stream、未知 descendants、execution/image failure，證明同一 loop 的 retirement 分支停止後續接納。這些是同一 production state machine 的故障測試，沒有冒充 Safari GUI／真正卡住 AX service 的驗收。
- 小 socket send buffer 與兩個並行 relay 的實際 partial writes 測試：24 個 8192-byte output frames 保持完整、不混流；斷線寫入可回報錯誤。
- 新增 8 項變異全部被抓到並還原：AX retirement、stream retirement、descendant retirement、image-before-execute、disk image check、parent guard、group guard、whole-frame lock。
- 還原後 `make test-all` exit0：1,530 XCTest、38 Swift Testing、66 smoke；簽章 49 PASS／2 身分限制 SKIP，GUI harness SKIP。之後只將 missing-parent 測試明確清除 ambient parent keys，該單項重跑 PASS；production source 沒有再改。

下一步是 task 2.4 的 host runner：owner admission、idle generation、cancel/deadline/cap、crash/partial/wrong-id/no-replay、清理 pending 時保留 reservation 並拒絕新 pair。尚未切換公開 MCP backend，也尚未進行同 build 的完整效能驗收、最終六方審查或宣告 verified。


## Host runner（2.4）

- `MCPPersistentRunner` 以 admission lock 與單一 I/O queue 管理每組程序／FD；取消只發布 intent，owner 在有界 poll/drain 迴圈處理。正常 sequential calls 重用實際 worker，busy 立即拒絕；idle epoch／generation 擋掉舊 timer。
- 崩潰、partial／wrong-id／超長 frame、cap 或 deadline 一律不重播。實際 append marker fixtures 每筆只留下單次 effect，下一筆獨立呼叫才重建。保留 prefix；business exit17 不會被 worker process0 或 supervisor signal 覆蓋。
- cleanup pending 保留同一 reservation／generation；ownership lost 永久停止該 owner 的 signal／新接納。Shutdown 能取消 active／isolated fallback 並清理 idle，回報未確認清理。
- 原實作在 idle EOF 且 supervisor 尚存活時錯誤拒絕下一筆；實際 fixture RED 後改為僅在新請求零 byte 送出前清理／重建。
- 大參數測試依本機 ARG_MAX=1 MiB 取得 half-boundary，分割為 4096-byte argv，與原 runner 的 kernel 接納結果比對；另以 started marker 證明 legacy route 的 active cancellation。
- 暖 launch path 消失後持續要求 restart，即使路徑恢復也不偷偷重用原 instance；舊 idle deadline 跨越 active call 與下一筆呼叫時 PID 維持正確。
- 實測 waitid 回報 si_pid、CLD_STOPPED、SIGSTOP，證明只查 PID 會誤判退出；新增事件種類守衛。另一個自有 direct child 在首次 KILL 後加入仍受保留的 group，原本存活而 cleanup pending；現持續 KILL 至 quiescent 再 reap。測試以兩個 direct-child reservations 安全收尾，不對失去所有權的 PID 發訊號。
- 最終 focused：25 tests PASS（15 runner／10 supervisor）。12 個新增變異全被攔截並還原：replay、correlation、output cap、cancel、deadline、sticky image、kernel route、cleanup failure、idle generation、frame cap、stopped event、repeat group kill。
- 中斷前 full suite 沒有完成，原 handle 消失且無測試程序後才重新執行；不把中斷紀錄當 PASS。完整結果另以恢復後的 exit code 為準。

- 恢復後 `make test-all` exit0：1,546 XCTest／38 Swift Testing／66 smoke；簽章 49 PASS／2 身分限制 SKIP，GUI harness SKIP。


## 公開 MCP 整合（2.5）

- `mcp` 預設 persistent；明示 isolated 保留原 runner。Idle timeout 預設 30 秒、有限且 0.001...86400。Mode／idle parser 的初始 stub RED 為 3 tests／10 failures，包含 session 尚未呼叫 runner shutdown 的缺口。
- `MCPCommandRunning.shutdown` 有預設空實作；session 先取消／等待 active，再以同一 cached shutdown task 清理 runner，涵蓋 idle 與 concurrent/repeated shutdown。清理失敗可經 terminalFailure 送到 CLI error path。
- 原 atomic executable test 在新 host-side guard 上 RED：failure 欄位有指引但 stderr 空白。已補原 CLI diagnostic 與 exit64，保留 stderr restart／not-executed 指引；此呼叫仍未送出 private request。
- `make test-mcp` 兩模式皆執行。新增無 mode flag 的真實預設 PID reuse、明示 isolated 的 fresh PID、actual idle exit/new PID/EOF cleanup。Nested test 在 persistent 模式檢查 supervisor／worker／nested CLI 每層 parent 與 supervisor PGID，backpressure case 等到 actual worker 存在。
- 測試 cleanup 移除依 ps 結果盲目補送 PID kill：普通子程序交由持有 reservation 的 host 清理；explicit daemon 使用自有唯一 instance 的 stop RPC，失敗保留 fixture 目錄。
- Focused 26 tests PASS；兩模式各 12 項 end-to-end PASS。4 個公開整合變異均被攔截並還原：default mode、idle bounds、shutdown wiring、cleanup failure surfacing。最後一項初始變異無法編譯，不計為行為證據；改成合法的忽略 failure 變異後，確實得到 assertion RED。
- README／CLAUDE／CHANGELOG 已同步模式、生命週期、版本失效與 no-replay 語意；尚未宣稱固定加速倍數。

- 還原後 `make test-all` exit0：1,549 XCTest／38 Swift Testing／66 smoke，persistent 與 isolated 各 12 個 MCP end-to-end；簽章 49 PASS／2 SKIP，GUI harness SKIP。Task 3.1 的回歸與關鍵變異條件已完成；3.2／3.3 仍未完成。


## 同 build 效能驗收（3.2）

- Benchmark 明示 `--mcp-worker-mode both|isolated|persistent`（預設 both）；mode-specific cold/warm labels，identity 只由成功 measured command traces 計算。Trace-off 未觀察就回 null，不以 host PID 假裝 worker PID。
- 新增模式／identity tests 先有 3 項行為 RED，補上實作；完整 50 tests PASS（保留原 46 項）。一個既有 test factory 需轉傳新參數，原 no-replay／單 host 斷言保留。4 個 mode forwarding／unique PID／successful-only／mode selection 變異被攔截並還原，還原後 4 項 focused PASS。
- Runtime source c70f25a，同一 debug binary SHA256 `aebf3434841cb2fe4aec321445ae445d7482e15d780272769b663af5ea58612c`；arm64、Darwin 26B5091g。20 samples／3 warmups／3 秒截止，timing both，所有 18 個非 GUI 場景 20/20 成功；GUI rows 全 SKIP。
- 初次 trace-off warm isolated p50/p95=34.98/55.62 ms，persistent=18.12/20.24 ms；cold=260.49/273.09 與 282.39/296.95 ms，cold 代價如實保留。
- 反向順序 warm20 中 persistent p95 86.15 ms 高於 isolated54.77 ms，未刪掉此 cohort。追加兩 host 常駐、AB/BA 交錯 warm60 同條件比較：trace-off isolated55.50/194.43 vs persistent20.13/101.59 ms；trace-on42.70/95.97 vs20.82/62.12 ms。各自60/60成功，trace-on為60個isolatedPID vs1個persistentPID，60個requestID各自獨立。
- 尖峰多在 command trace 外；這包含 IPC、排程、image／stream／退出處理，不能據此認定單一原因。接受範圍是固定 wait0 的同 build／交錯比較之 warm p50與p95改善、成功率未減少，不宣稱每一輪／每次GUI呼叫或固定倍數。
- 三次成功呼叫後的 readonly process-tree／RSS snapshot：isolated無resident child，persistent兩個；host+children RSS總和22,688 vs43,760 KiB。含共享頁、不是unique memory或母體估計。Idle退出另有實際測試。
- `docs/performance.md` 與 `docs/benchmarks/mcp-worker-2026-09-28.json` 保留三個 cohorts 全部 wall samples、分位數、identity counts、冷啟動與resident成本。尚待3.3獨立審查／交付，未宣告verified。


## R1 findings and R2 repairs

R1 六份報告均已收齊：五份 Claude CODE PASS（DA 附條件）、Codex CODE FAIL。Coordinator 對已重現的契約缺陷維持 aggregate FAIL，master comment 見 issue #172 的 5868165624。不以多數票消除缺陷。

- Worker-only image invalidation：actual host probe A → pre-send 置換 B → worker 拒絕 → 恢復 A → host 原本重新派送，RED。現用 typed retire(image) 設定 host sticky invalidation；不解析 stderr。
- Legacy timeout：1.2 秒 invocation 加上受控 0.6 秒 cached retirement，原本約1.93秒，RED；現從 admission 建立 absolute deadline，沿用至 isolated runner，spawn 前及 loop 都重驗。已過期 deadline 的自有檔案 marker 原本仍出現，修正後不執行。
- Private frame expansion：公開 JSON 約7MiB、stdin4MiB、470k控制字元argv，原 kernel runner接受但private base64/JSON超過8MiB被拒，RED。現在以獨立的 clientFrameTooLarge 錯誤在零 byte 前選原 runner，沿用相同deadline，沒有執行後 fallback。
- Idle C stdout buffer：自有fixture在兩個capture之間寫buffer，原本下一筆多出40bytes，RED；現在在新pipes綁定前flush至null。這不是未知live writer已join的宣稱。
- Closed diagnostic streams：actual舊binaryhelp/validation/trace保留0/64/0，新版原本三者SIGABRT；改回best-effort Swift寫入後，7項CLI測試PASS。
- Updated initialize instructions，清楚區分 per-call state isolation 與 persistent process reuse。
- 4項R2變異（worker-image sticky、inherited deadline、encoded-frame route、idle flush）被攔截並還原；full make test-all exit0：1555 XCTest／38 Swift Testing／66 smoke、兩模式各12 MCP，簽章49PASS/2SKIP、GUI harness SKIP。
- 交錯benchmark已成為可執行CLI選項，52項benchmark tests PASS。R2 final release SHA300d5a…在60樣本AB/BA下，off isolated17.70/50.97ms vs persistent2.52/7.77；on10.71/21.51 vs1.74/2.65，全部60/60成功。資料／兩個release cohorts／舊debug反例均保留，不宣稱普遍加速。
- 原始啟動分段的逐筆interval與暫時instrumentation patch已提交，補足R1reviewer可見性。原isolated cleanup限制獨立追蹤#209，沒有誤稱已修。

R2 `spectra validate` 通過；`spectra analyze` 的 Coverage／Consistency／Gaps／Localization 均無發現，21 項皆為補充 Example 的 Suggestion，沒有阻擋項目。具體反例及測試資料見本節與對應測試。

尚需以新的固定提交完成R2獨立審查及最終交付；仍未verified。
