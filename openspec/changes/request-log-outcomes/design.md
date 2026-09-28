## Context

#205 的基底 1727f96 使用 #199 的單次回覆仲裁、可撤銷 transport 與 admission 捕捉的 logger。既有 emitLog 在 executeRequest 返回 Reply 之前執行；shutdown 甚至在 prepareShutdown 的世代重驗前就記 result={}。自有 fixture 已同時捕捉一般／logFull 的這筆 log 與真實 client unknown，並確認 stop 不等 writer、新 instance 仍正常。

## Goals / Non-Goals

Goals：每個結果都明確標示觀測階段；保留既有 payload/redaction，能關聯後續候選仲裁與 shutdown 最後交接；writer 更換／stop-start 不使舊事件借用新 logger；新增 logging 不阻擋回覆仲裁或停止交接。

Non-Goals：不建立完整 transport tracing 或 peer acknowledgment 協定、不改 logger 的 best-effort 持久性、不宣稱取消回滾已執行副作用、不更動 #197 診斷預算、不修未證實的 FileHandle 平台競態、不更改 wire 回覆或 no-replay 政策。

## Decisions

### 預備回覆與關聯 token

既有 payload record 保留 ts、method、requestId、durationMs、params、result、error，新增 event=request_response_prepared、requestToken=現有 RequestWork.id 的 UUID 字串、peerReceipt=unconfirmed。result 僅指候選 JSON result envelope，不等於業務成功、傳送成功或停止完成。不同 client 可重用 requestId，因此不用 requestId 單獨關聯。

僅改文件而不標記 event 會讓既有 result={} 繼續看似最終成功；刪除 result 又破壞診斷資訊，因此採新增欄位並明載多行遷移。

### 候選回覆的仲裁觀測

Reply 攜帶固定型別 outcome：result、parse_error、method_not_found、handler_error、cancelled。原 operation task 呼叫 work.result.complete(reply) 後，使用其 Bool 結果產生 request_response_candidate，包含 ts、requestToken、outcome、selection=selected 或 not_selected、peerReceipt=unconfirmed。task 在 executeRequest 前已取消時，先 cancel gate，再記 outcome=cancelled、selection=not_offered。executeAndOffer 返回時只帶固定 outcome／selection，不額外持有 response frame；writer 在原 operation task、actor 外執行，之後才 finishOperation；不另建 logger task／queue。

此事件只報告原 operation 候選的 offer，不是所有取消來源的完整事件流。selected 表示該候選贏得單次 gate；not_selected 只表示未被選中，不能反推另一個 winner 或 peer 收到。shutdown 對其他 work 的取消 offer 維持既有行為，不在該迴圈插入可能阻塞的 writer。handler 永不返回時不偽造 outcome；operation/logger 未完仍如實追蹤。

### Shutdown 最後交接

prepareShutdown 的 logging 後守衛保持不動；拒絕時返回 cancelled Reply，原 operation 候選事件因此能區分先前的 prepared result 與後來 cancelled/not_selected。

對成功建立 plan 的 shutdown，completeShutdown 回傳固定觀測值 rejected、hook_returned 或 instance_stopped；performShutdown 早期世代不符也回 rejected。serveConnection 在 ACK 嘗試、取消回覆預算及最後交接返回後，才用捕捉的 work.log 寫 request_shutdown_handoff（ts、requestToken、outcome、peerReceipt=unconfirmed）。hook_returned 只證明 hook 返回，不概括承諾任意 hook 已停止全部工作。此 log 不在 stop 或世代 guard 的等待鏈；正常 stop 已完成後才寫。

增加內部 beforeOperation／beforeShutdownHandoff 非同步觀測接縫；前者讓 fixture 在 admission 後取消、再放行執行前檢查，後者讓自有 fixture 在 plan 已成立／ACK 已嘗試後 stop/start，再驗最後拒絕；正式預設為空操作。不能以同步 syscall 鎖內暫停模擬這個交錯。

### 固定 metadata 與消費端遷移

新增 metadata-only 事件只接受 UUID、固定 enum 與時間，不複製 params/result、method、requestId、錯誤訊息或路徑；logFull 不擴大這些事件。舊 payload record 的 redaction／truncation／malformed marker 維持。

一筆 operation 最多一筆 prepared 與一筆 candidate；有 shutdown plan 才最多再一筆 handoff。不增加無界佇列。candidate 與 handoff 由不同既有 task 寫出，實體行序不能當作狀態順序；消費端以 event 與 requestToken 關聯。缺事件代表未觀察／未落盤，不是成功或沒有執行。nil writer 仍完全不輸出。

## Implementation Contract

- DaemonLog 提供型別化 candidate outcome／selection／shutdown handoff 格式化；JSON-line 一行一物件，三種 event 都有 requestToken 與 peerReceipt=unconfirmed。
- DaemonServer 保留所有既有世代／fd／仲裁守衛。先 complete/cancel gate，後寫候選 metadata；先完成 shutdown 交接，後寫 handoff。所有新 writer 呼叫都在 Instance actor 外，不增加獨立背景 logger task。
- 正常 shutdown：prepared result、candidate result/selected、handoff instance_stopped 或 hook_returned；client 正常取得 ACK。舊 writer 阻塞再 stop/start：prepared result、candidate cancelled/not_selected；client unknown、新 logger 不收到舊事件、新 instance 正常。
- Plan 後世代被撤銷：handoff rejected，不呼叫替代 hook、不停止新 instance。handler 返回晚到 result：candidate result/not_selected，不宣稱副作用回滾或 peer 已接收。
- 驗收：將 diagnostic baseline 改成新 contract 的真實 socket RED；正常與 revoked shutdown、最後交接、blocked candidate/handoff writer、logger replacement、late handler、重複 requestId、logFull、格式化／redaction 舊測試。完整非 GUI suite、關鍵守衛與事件變異、六方審查後才 verified。

## Risks / Trade-offs

- [多行 schema 影響消費端] → 保留 payload 欄位；文件要求以 request_response_prepared 篩選，不再假設每行有 result。
- [新增 writer 可能阻塞] → 在 reply gate／停止交接之後寫；不置於 actor、停止迴圈或取消回覆預算中；以 gate fixture 驗證 transport／stop 仍完成。
- [stop 後 sink 已關閉] → 保留 best-effort，不保證事件落盤；prepared 與 unconfirmed 標記避免把缺少後續事件當成成功。
- [誤把 gate 接受當 peer receipt] → selection 語意只到仲裁，所有事件明載 unconfirmed，文件及測試不聲稱遠端接收。

## Migration Plan

更新文件與 tests 的 payload 篩選，新增 event/token 欄位和 metadata 行。舊 reader 若忽略未知欄位但假設每行皆 payload，須先加入 event 篩選；沒有 event 的歷史行只能視為歷史未分類候選，不能回填傳送成功。回退版本會恢復舊 schema，不需磁碟資料轉換。

## Open Questions

無阻擋問題。peer 實際接收與 best-effort 檔案持久性仍不可由本地事件證明。
