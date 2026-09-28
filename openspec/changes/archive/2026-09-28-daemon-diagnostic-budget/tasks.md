## 1. 預算與摘要

- [x] 1.1 實作 Bounded daemon diagnostic events 的共用額度與終止保留：DaemonDiagnosticBudget 以單調時鐘維持 8 筆／2 筆每秒、不因 incident 或 stop-start 重設；先寫固定時間交替事件與 500 ms／倒退時鐘 RED 測試，再驗證 token 上限與 terminal 保留。
- [x] 1.2 實作 Bounded and private suppression summaries 的固定摘要與定時排出資料契約：七種事件計數、飽和總數、first／lastRecovery／lastTerminal；以真實 JSON writer sink 驗證白名單欄位、計數不重複與 logFull 不洩漏。

## 2. Instance 整合

- [x] 2.1 實作 Diagnostic logging preserves daemon lifecycle behavior 的 Actor 外寫入與 logger 生命週期：共用 gate、單一 500 ms flusher、token 失效與 writer 更換；控制 sleep／clock 驗證無新事件時摘要、慢 writer 時 stop 不等待、舊 timer 不寫入新 sink、stop-start 不補免費額度。
- [x] 2.2 實作 Private request rejection diagnostics 的拒絕先關閉連線：framing 失敗先 close／釋放 reader，再記固定原因事件；以自有 socket 與阻塞 writer 驗證 client 關閉、零 handler、正常 client 結果、不重播，以及 EOF 不記錯誤。

## 3. 整合驗證與文件

- [x] 3.1 以實際 accept/setup/recovery 事件路徑、控制時鐘驗證交替與連續錯誤、不同 errno、quiet gap 共享額度；執行 daemon 相關測試、變異測試與 make test-all。
- [x] 3.2 更新 CLAUDE.md／CHANGELOG.md 的額度、固定摘要及 best-effort 停止邊界；spectra analyze／validate、六方審查通過後同步規格、歸檔，提交與 PR 均引用 #197。
