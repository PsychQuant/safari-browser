## 1. 重現與逐呼叫協定

- [x] 1.1 以 JSResultIsolationTests 的正式 JSCommand.run／JavaScriptCore 接縫重現同長度交錯結果：要求 new-batch 卻寫出 old-batch；保留行為 RED，編譯失敗不算 RED。
- [ ] 1.2 實作「逐呼叫結果物件」與 Invocation-owned JavaScript result transfer：JavaScriptResultSession／JSWrapper 產生唯一 prepared/running/done/error 狀態，測初始化身分、空值、例外與另一呼叫狀態不被覆寫。
- [ ] 1.3 實作「帶識別與範圍的傳輸框架」：驗 token、offset/end、UTF-16 長度與總長，測舊回覆、短塊、代理對邊界、冒號／換行及非零失敗。

## 2. 指令與共用家族

- [ ] 2.1 接上「安全的語法後備與導頁判讀」：JSCommand 一般／大型路徑共用新引擎，只有 prepared 可 statement fallback；以側作用計數、空結果、同 URL 狀態消失及已知導頁測試確認不重跑，失敗保留既有 output 檔。
- [ ] 2.2 接上「共用讀取家族與清理」：SafariBridge.doJavaScriptLarge、GetText／GetHTML、Snapshot callers 改走獨立結果，逐一驗大型結果與錯誤，確認 cleanup 只刪本次狀態；原交錯 RED 轉 GREEN。

## 3. 驗證與交付

- [ ] 3.1 執行 JS wrapper／navigation／bridge 相容測試、完整 make test-all 與六方審查，更新 README／CHANGELOG 與 issue 證據；清楚區分 JSC 接縫驗證、Safari 實測與未重現的歷史事件。
- [ ] 3.2 Spectra analyze/validate 無阻擋後更新 PR；合併前核對測試與審查快照，完成後同步規格並歸檔，保留 issue 原始觀察。
