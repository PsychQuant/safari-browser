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

## R2 aggregate FAIL 與實際重現

固定版本 `1e0ad622f853942da844662527e94d7d13d7b30f` 已收齊六份獨立報告；四個初始 lens PASS，DA／Codex FAIL。總裁定見 https://github.com/PsychQuant/safari-browser/issues/172#issuecomment-5868747615 ，不採多數決，未打 verified tag／未開 PR。

- 真正公開 MCP persistent，大 argv 的 `wait 5000` 觸發 one-shot 預選；只終止本地持有的 host，半秒後 worker 仍為 sleeping 且 reparented，直到自然5秒結束才消失。沒有向 ps 觀察得到的 worker PID 發訊號。
- 一般 persistent pair 對照以 busy 拒絕確認 active call，終止 host 後半秒，supervisor 與實際 worker 均已消失。這補上普通非 stopped worker 的 raw host-death 證據；先前 SIGSTOP 情境仍是分層 fixture。
- 未修改的原 `MCPProcessRunner` 自有 SIGSTOP fixture：1秒 timeout，三次分別約54／27／24毫秒被 signal9 終止。僅在外部診斷複本補 si_code 真退出判斷，相同案例約1.02秒才回報 timeout／signal15。不是完整正式修正。
- #209 已有診斷 https://github.com/PsychQuant/safari-browser/issues/209#issuecomment-5868722871 ；late member、pending／lost ownership 及 bounded shutdown 仍需原 runner 的直接證據。
- 既有1555 XCTest等PASS仍代表該固定版本已跑的範圍，不能覆蓋新發現；4.x完成後必須重新驗證及量測，不得沿用R2PASS計數宣告完成。

## R3 task4.1／4.2 進度（未完成整體驗收）

- 新增自動回歸：原runner自停時1秒timeout卻約44ms終止，兩項斷言RED；真正公開MCP大argv的host-death測試RED。普通pair對照通過。
- 一次性執行新增same-argv／等長context值的supervisor bootstrap、固定parent/deadline header、唯一host lease及真正worker的status record；兩模式的host-death案例均GREEN。缺少合法inherited descriptors時拒絕bootstrap，舊binary退出0、新版退出64，已取得RED／GREEN。
- 精確kernel接納測試先抓到Foundation額外環境欄位導致的新邊界退化；改傳parent原始環境快照後，0及8192-byte padding的接受／拒絕相鄰邊界均通過。Python系統shim本身會再exec並改變邊界，已改用真正CLI的raw posix_spawn作獨立對照，未把shim失敗當產品缺陷。
- environment-snapshot及post-allocation-deadline兩項有效變異都造成具名行為失敗並還原。還原後focused與MCP family 152 XCTest通過；public MCP persistent／isolated各14項通過。這不是全repository test-all，也不是新release benchmark。
- 修正原runner的si_code判讀；但仍需4.3的stateful pending owner、late member重複清理及有界回收，不能宣稱#209完成。#172維持needs-fix、尚無新六方PASS。

- 新監督架構下，actual worker 的SIGSTOP不再等於host直接child的SIGSTOP；另補自有不合作supervisor自行停止的測試，直接覆蓋host的leader判讀。退回si_pid-only變異會再次在期限前失敗；還原後MCPProcessRunner family 11項通過。這避免架構改變後原斷言失去對si_code修法的辨識力。

## R3 task4.3 ownership（待全套與獨立審查）

- 原runner的shutdown／concurrent case取得6項具名RED，pending case取得3項RED。新serial owner會取消active call、拒絕並行副作用、保留未清理reservation、稍後完成同一owner退休。
- 只修改one-shot owner仍不足：persistent外層每筆新建runner，曾在舊pending存在時實際執行新exec並輸出66bytes。整合測試取得RED後，改為長期持有one-shot runner並在兩條engine前檢查舊owner，GREEN。
- 實際ECHILD（測試故意回收本地持有且已結束的direct child）會讓owner永久停止retirement及新launch。Shutdown對pending有界返回、可在原owner可退休後完成，但不重新開放已關閉runner。
- late-member測試走真正MCPProcessRunner：自停且忽略TERM的helper在第一次KILL後仍被保留，新自有member加入該group，再確認runner重複KILL並於釋放leader前清除member。Fixture member有獨立spawn reservation作失敗清理，不向ps／reply PID發訊號。
- 8項有效變異：late-group重複KILL、保留pending、lost-owner終止態、跨engine guard、active cleanup截止、retained cleanup截止、shutdown取消、image capture契約；全部具名行為失敗，還原後161項MCP XCTest通過。這是本階段驗證，不代替4.4的完整test-all、最終release量測與六方審查。
- README／CLAUDE／CHANGELOG已同步受監督one-shot、跨engine pending、環境快照及兩模式image error欄位差異；4.3完成，整體13/15。

## R3 完整回歸與最終 release（待六方審查）

- Runtime `a12ba03`：完整`make test-all`通過，1568 XCTest／38 Swift Testing／66 smoke，MCP persistent／isolated各14項，benchmark52與CLI trace7通過。簽章49 PASS／2身分SKIP，GUI harness SKIP。
- 第一輪full suite在daemon臨時harness的raw swiftc遇到SDK搜尋失敗，並非斷言失敗；指定Xcode工具鏈與SDKROOT後，daemon案例通過並重跑整個test-all得到exit0。中間一次續跑誤用了不存在的make target，已改回正式test-all；不將該命令錯誤列為產品缺陷。
- Release build通過；既有MCPCommandProcess captured-pid與MCPStdio字串constructor兩項編譯warning仍有揭露，本輪沒有修改這兩個runtime檔案。
- Final release SHA256 `7797668ff99fe7113fdb86d19f67de325fe591e28770dabe9736f357206f40d8`，同build／60 samples／3 warmups／3秒deadline／ABBA交錯。off warm isolated29.400/31.851ms vs persistent1.885/6.770；on30.498/33.294 vs2.386/14.009；全部60/60成功。trace-on觀察60 vs1 actual worker PIDs、兩模式各60 request IDs。
- cold off isolated59.113/63.115ms vs persistent50.725/59.361；新one-shot多了supervision，不能拿R2舊baseline宣稱同一runtime成本。所有scenario（含CLI／daemon）的wall samples／warmups及trace identity已保存，未跑live Safari。
- 另測三次成功呼叫後的process tree：isolated0個resident child、persistent2個；RSS加總17040 vs38000KiB，包含共享頁，僅為單次snapshot。不是unique memory或全場景效能推論。
- 實作、測試與量測證據現已備妥；4.4的獨立審查及3.3歸檔／PR尚未完成，不能標verified。

- 最後的caller契約核對另抓到R3重構將較晚inherited deadline直接採用、可能放寬configured timeout。原0.15秒設定配未來30秒deadline卻讓1秒fixture正常完成，兩項具名RED；改為兩者取min後約0.156秒timeout，23項相關測試GREEN。此為內部呼叫參數邊界修正；將重新建置、回歸及量測最終runtime，a12ba03資料保留為前一cohort。

- 最終全套在late-member測試遇到一次kernel觀察時序差異：runner已完成group清理後，單次waitid尚未給出exit；診斷當下proc_pidinfo沒有資料、getpgid為-1，50ms後同一reservation的waitid回報exited。測試改為在任何fixture清理訊號前，有界0.3秒等待真exit事件，並核對最終SIGKILL狀態。五次獨立重跑GREEN，移除repeat-KILL仍能抓到真正存活的late member；還原後ownership family通過。沒有改產品retirement或忽略失敗。

- 測試觀察修正後，最終完整`make test-all` exit0：1569 XCTest／38 Swift Testing／66 smoke、兩模式各14 MCP；簽章49 PASS／2身分SKIP，GUI harness仍SKIP。產品runtime仍是`7c585c3`；`f0432d6`只改測試與驗證紀錄。
- 最終release SHA256 `6d327f2b0ad928b69c024e259ea19a2bd120ce774507862a5093c6b2d7eee997`：60樣本ABBA、3 warmups／3秒deadline，off warm isolated24.475/27.471ms vs persistent1.129/1.765；on23.973/25.481 vs1.103/1.455；全部60/60成功，trace-on仍60 vs1 worker PIDs／各60 request IDs。所有scenario的wall／status／identity陣列已保存；舊a12cohort保留，不把跨cohort差異全歸因於deadline修正。
- 最終三次呼叫後resident snapshot：isolated0 child／18352KiB RSS，persistent2 children／38144KiB RSS；仍為包含共享頁的單次加總，非unique memory。

## R3 FAIL 與 R4 修正

R3六份報告已全文讀取，固定HEAD49ca317；master：https://github.com/PsychQuant/safari-browser/issues/172#issuecomment-5873322439 ，#209 pointer：https://github.com/PsychQuant/safari-browser/issues/209#issuecomment-5873323127 。TERM會先終止正式supervisor，grace／status與cleanup-grace host-death要求未完成，未打verified tag。

- 未插樁exact-source runner＋正式helper：0.3秒timeout、80ms收尾fixture只到TERM received，exitCode null，約0.318秒返回。正式100ms收尾回歸取得兩項RED（未完成／非143）。
- 真正MCP三路徑（persistent普通、isolated普通、persistent大argv）以自有fault injection在送TERM後暫停host，再只終止其Popen host，均重現sup先成zombie、worker持續存活到wait5000自然結束。Dyld插樁setup曾因缺SDK header／image0 UUID拒絕而失敗；那些不算產品RED。有效fixture只對齊自有library UUID並簽署，產品binary不變。
- 正式兩個supervisor現於spawn worker前忽略TERM；實際worker的spawn仍重設TERM預設。31項相關測試GREEN，100ms收尾與143恢復；公開三路徑GREEN，進一步含真正普通後代且在TERM後仍活著的前置條件。
- 新`Tests/mcp-termination-test.py`及自有C fixture納入test-all；舊R3release跑同一正式測試得到3個subcase RED。
- 背壓測試已改為兩模式都驗host→supervisor→actual CLI的parent／PGID／entry；SIGCHLD忽略launcher在兩模式2次呼叫均成功，該靜態假設未重現，未新增訊號重設。
- 新增5項bootstrap程序測試：實際大環境pump、8MiB cap在EOF/deadline前拒絕、讀環境期間lease EOF、錯誤／截斷metadata不得exec、missing/truncated/oversized/bad-status不得當成功。8項R4有效變異已攔截並還原，MCP family168項通過。Actual CLI TERM default的追加變異另驗。
- 尚待完整回歸、更新release量測與R4六方審查；不可沿用R3測試PASS或效能數值作新runtime完成證據。

- 第9項R4變異移除actual worker的TERM預設恢復，既有self-TERM143斷言會失敗；還原後runner family16項通過。這證明supervisor忽略TERM不會把忽略狀態洩漏到CLI。SIGCHLD launcher測試是既有行為characterization PASS，不計為RED。

## R4 完整候選證據（2026-09-29，待獨立審查）

- Runtime `834dc89` 的正式`make test-all` exit0：1575 XCTest／38 Swift Testing／66 smoke、兩模式各15 MCP、新TERM host-death測試1項含3subcases、benchmark52／CLI trace7。簽章49 PASS／2身分SKIP，GUI harness SKIP。
- R4九項有效變異均攔截並還原；完整原始log及driver definitions保留供reviewer核對，不只提供summary。
- Release SHA256 `02320ed601bc71f34fabd715463d0a058d5a3776a08b00122b00ba7cfb1ca505`：60 samples／3warmups／3秒deadline／ABBA，全部18個non-live rows均60/60且warmups皆成功。off warm isolated24.296/25.574ms vs persistent1.139/1.470；on23.574/24.707 vs1.124/1.371。Trace-on仍60 vs1 worker PID，各60requestIDs。
- 新三次呼叫resident snapshot：isolated0 child／17728KiB RSS、persistent2 children／38896KiB RSS；共享頁加總、單次snapshot，非unique memory。全部cohorts保留，沒有GUI效能宣稱。
- tasks現為16/18，4.4的獨立審查及3.3歸檔／PR仍待完成，尚未verified。

## R4 六方 PASS（固定529325d）

全部六份獨立報告均CODE PASS；Codex另讀完整raw logs的證據附錄，維持PASS。Master：https://github.com/PsychQuant/safari-browser/issues/172#issuecomment-5874525074 ，#209：https://github.com/PsychQuant/safari-browser/issues/209#issuecomment-5874536221 。Verified tags `idd-172-verified`／`idd-209-verified`固定於529325de7d8e38967c421f4f86824fad77019885，已推送。

- 最終凍結版TERM fixture又對R3保留binary重跑，三路徑皆RED且每路徑都有worker＋普通後代存活；補充log記錄test／fixture／binary SHA，已解除舊RED版本不一致的疑慮。
- 已取消後仍可能在startup race開始CLI的Low，以及大argv時序測試的更強路由斷言，另追蹤#211。當前有界／unknown／不重播契約不改成零副作用保證。
- GUI／簽章身分SKIP、受控插樁、kernel pending、來源provenance邊界均保留。後續spec歸檔與PR不改產品runtime。
