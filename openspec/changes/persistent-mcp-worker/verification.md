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
