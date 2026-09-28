# 元件實作證據（2026-09-28）

目前完成 tasks 1.1、1.2、1.3、2.1；其餘未完成。這份紀錄不是完整 #172 驗收，也不表示 public MCP 已改用常駐 worker。

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

## 合併後局部回歸

在上述最終原始碼執行 `swift test --filter MCP`：99 tests，0 failures。`git diff --check` 與 Spectra validation 通過。

尚待 request stdio/state 隔離、hidden command 整合、persistent runner、公開模式切換、完整 #110 回歸、同 build 效能對照、完整測試與六方審查。未操作 Safari GUI，未安裝 binary，未宣告 #172 verified。


## Request scope／CLI／stdio 元件（2.2 進行中）

本批新增元件已實作，但 task 2.2 仍未勾選：須在 task 2.3 的 actual worker 迴圈接上 AX quiescence 的不重用／退休回覆，才能證明完整路徑。

- `MCPInvocationContext`：每次建立獨立 gate／trace；gate 優先序為 daemon request、MCP invocation、普通 process。成功與錯誤路徑均 cancel 並 await 已知輔助工作；一般 CLI 保持原 cancel-only 行為。SafariBridge 的 watchdog 與 System Events waiting-message 已接上此邊界。
- `BoundedAXWorker.isQuiescent`：只讀狀態，不因呼叫端 timeout 提早重設 allowance。測試以受控背景工作證明真正返回前仍不可重用。
- `CLIExecution`：普通 main 與 persistent 執行共用 parser／run／diagnostics；只有 main 退出程序。保留 help、validation、silent ExitCode、glued-flag hint 與 trace 格式。Persistent 模式拒絕執行 hidden/MCP commands。
- `MCPRequestStdio`：一個 worker process 只有一個 stdio owner；每筆獨立管線、4 MiB input cap、兩個 8192-byte relay 與 stdin feeder。清除 libc stdin 殘留／EOF，flush 後轉回 null，非阻塞地等待 relay 全部結束；output failure 或 seal deadline 未完成永久拒絕該 owner 的後續呼叫。Relay 自己關閉 descriptor，不從其他執行緒關閉尚在使用的 fd。
- Scope 的 owned RED：14 tests／15 個行為失敗；CLI stub RED：4 tests／22 個失敗；stdio stub RED：5 tests／20 個失敗。各自實作後 GREEN。最終相關範圍 141 tests 通過。
- 11 項新增變異全部被抓到並還原：gate isolation、auxiliary join、AX quiescence、diagnostic newline、stdin purge、stdout flush、poisoned reuse、input cap、relay join、writer failure、process lifetime claim。
- 使用重構前後兩個實際 executable，比較 90 條公開 help 路徑與 8 個其他案例：98/98 的 stdout、stderr、exit code 完全相同。這是此次 CLI 入口抽取的比較；後續新增明示 MCP 模式選項與 hidden metadata 時，需另按預期差異驗證。
- 原 `Tests/mcp-stdio.py` 10 項端到端測試通過（含 77 個公開 tool help、stdin、cancel／EOF／backpressure、nested group、explicit daemon、binary replacement）。目前仍使用原 isolated runner，不把它當作常駐 backend 的驗收。
- 還原所有變異後 `make test-all` exit 0：1,516 XCTest、38 Swift Testing、66 smoke；簽章 49 PASS／2 SKIP（缺少所需簽章身分）。GUI harness 明確 SKIP，沒有新的 Safari GUI 驗收。

下一步：hidden supervisor／worker 入口、私有 framing 與 request dispatch 整合；驗證健康呼叫的同 PID 重用、AX busy／descendant／scope failure 的實際退休，然後才完成 task 2.2／2.3。Public MCP 尚未改成 persistent；沒有新的效能改善宣稱。
