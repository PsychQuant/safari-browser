## 1. 事件與仲裁

- [x] 1.1 實作「預備回覆與關聯 token」及「固定 metadata 與消費端遷移」，履行 Request payload logs identify prepared responses：DaemonLog 加 event/token/unconfirmed 與型別化 metadata formatter，保留 payload/redaction；formatter schema、非法 payload marker、logFull 與舊欄位回歸測試由 RED 轉 GREEN。
- [x] 1.2 實作「候選回覆的仲裁觀測」及 Operation candidate logs reflect reply arbitration：Reply 固定 outcome，原 operation 先 complete/cancel gate 再用 captured logger 記選擇結果；將 baseline probe 改成 blocked shutdown、晚到 handler、取消前執行與重複 requestId 的契約 RED，驗證實際 wire／token／selected 與 not_selected。
- [x] 1.3 實作「Shutdown 最後交接」及 Shutdown handoff logs report the final guarded handoff：保留 prepare／final guards，回傳 rejected／hook_returned／instance_stopped 並於交接後記錄；以正常 shutdown 與 plan 後 stop/start 的受控接縫驗證 ACK、舊 hook 不借用、新 instance 正常。

## 2. 完整驗證與交付

- [ ] 2.1 驗證 Outcome logging preserves lifecycle and logger ownership：blocked candidate／handoff writer 不阻擋 response／stop、新舊 logger 分離、nil writer 靜默、每 request 有界事件；更新既有日誌測試的 payload event 篩選，執行關鍵守衛／事件變異及 make test-all，並在 CLAUDE.md／CHANGELOG.md 記錄多行遷移與 best-effort 限制。
- [ ] 2.2 完成六方審查與修正、spectra analyze／validate、四項 requirements 同步歸檔；依最終提交留下完整證據，PR 與每個 commit 引用 #205，驗證後保留 issue OPEN。
