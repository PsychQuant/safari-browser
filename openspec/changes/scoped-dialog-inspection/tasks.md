## 1. 安全掃描

- [x] 1.1 實作穩定 ID 與限定範圍（Stable scoped inspection），以 ScopedDialogInspectionTests 驗證多視窗、失效與重複 ID、重排。
- [x] 1.2 保留 Complete target evidence，以真實 scanner／executor 的回歸驗證目標逾時、預算耗盡、WebArea 排除、無關與多重 AXDialog。
- [x] 1.3 實作全域唯一性與重新核對（Strict command integration），驗證相同內容跨視窗、內容變更與按鈕缺失皆零操作。

## 2. 指令與交接

- [x] 2.1 接上 list／dismiss 參數與三次相同範圍，新增 parse／指令測試驗證無效及衝突 ID 被拒絕。
- [x] 2.2 完成診斷與實機驗收界線（Scoped reporting and handoff），檢查輸出不建議無限重試，文件清楚列出原生驗收缺口。
- [x] 2.3 執行可用自動測試及規格檢查，記錄結果與未執行項目，提出草稿 PR。
- [ ] 2.4 在 macOS 執行完整 make test；Safari 27 自有 confirm 實測並取得原生 AX 結構，驗證明確指定按鈕及一次 handler 執行後才完成 #326。
