## 1. 重現與逐呼叫協定

- [x] 1.1 以 JSResultIsolationTests 的正式 JSCommand.run／JavaScriptCore 接縫重現同長度交錯結果：要求 new-batch 卻寫出 old-batch；保留行為 RED，編譯失敗不算 RED。
- [x] 1.2 實作「逐呼叫結果物件」與 Invocation-owned JavaScript result transfer：JavaScriptResultSession／JSWrapper 產生唯一 prepared/running/done/error 狀態，測初始化身分、空值、例外與另一呼叫狀態不被覆寫。
- [x] 1.3 實作「帶識別與範圍的傳輸框架」：驗 token、offset/end、UTF-16 長度與總長，測舊回覆、短塊、代理對邊界、冒號／換行及非零失敗。

## 2. 指令與共用家族

- [x] 2.1 接上「安全的語法後備與導頁判讀」：JSCommand 一般／大型路徑共用新引擎，只有 prepared 可 statement fallback；以側作用計數、空結果、同 URL 狀態消失及已知導頁測試確認不重跑，失敗保留既有 output 檔。
- [x] 2.2 接上「共用讀取家族與清理」：SafariBridge.doJavaScriptLarge、GetText／GetHTML、Snapshot callers 改走獨立結果，逐一驗大型結果與錯誤，確認 cleanup 只刪本次狀態；原交錯 RED 轉 GREEN。

## 3. 驗證與交付

- [ ] 3.1 執行 JS wrapper／navigation／bridge 相容測試、完整 make test-all 與六方審查，更新 README／CHANGELOG 與 issue 證據；清楚區分 JSC 接縫驗證、Safari 實測與未重現的歷史事件。
- [ ] 3.2 Spectra analyze/validate 無阻擋後更新 PR；合併前核對測試與審查快照，完成後同步規格並歸檔，保留 issue 原始觀察。

目前證據：28 項 JS/JSC／wrapper／navigation focused tests 通過，包含 GetText、GetHTML 與 Snapshot 兩種模式的真正 command 路徑（DOM 為受控 stub）。原交錯 RED 已轉 GREEN；另外修正新協定的頁面 s 變數遮蔽、組合字元框架解析與初始化失敗誤判導頁。Safari／CSP 實測、完整測試與最終審查仍待完成。

## 4. 第一輪審查修正

前述完成項記錄 694734a 的實作範圍；本節完成及重新驗證前不得視為已驗收。

- [x] 4.1 「導頁、取消與診斷收尾」：帶 matcher 的正式 bridge 重試路徑先 RED 再 GREEN；取消各邊界、遺失 frame 狀態與 UTF-16 診斷先重現，再以 focused tests 驗證。
- [x] 4.2 「暫時編譯與舊 daemon 相容」／Ephemeral AppleScript compilation：cache 18→1 行為 RED／GREEN，驗新 RPC、舊 daemon 拒絕後安全退回、可重用 handle 不變及日誌遮蔽。
- [ ] 4.3 「驗證範圍與後續」：補量測與驗證，記錄暫時編譯保留量及可取得的延遲證據，區分純 fixture 與 Safari 真實指令；更新 #170 的量測前提，執行完整測試與第二輪六方審查。

R2 目前：真正 NSAppleScript 與 RPC 的保留量／相容性測試通過；20 筆 return-fixture RPC 延遲已記錄於 design，並未當作 Safari 端到端量測。#193 追蹤硬終止後的頁面回收。
