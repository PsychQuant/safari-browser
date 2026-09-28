## Context

#205 的基底 1727f96 使用 #199 的單次回覆仲裁、可撤銷 transport 與 admission 捕捉的 logger。既有 emitLog 在 executeRequest 返回 Reply 之前執行；shutdown 甚至在 prepareShutdown 的世代重驗前就記 result={}。自有 fixture 已同時捕捉一般／logFull 的這筆 log 與真實 client unknown，並確認 stop 不等 writer、新 instance 仍正常。

## Goals / Non-Goals

Goals：每個結果都明確標示觀測階段；保留既有 payload/redaction，能關聯後續候選仲裁與 shutdown 最後交接；writer 更換／stop-start 不使舊事件借用新 logger；新增 logging 不阻擋回覆仲裁或停止交接。

Non-Goals：不建立完整 transport tracing 或 peer acknowledgment 協定、不改 logger 的 best-effort 持久性、不宣稱取消回滾已執行副作用、不更動 #197 診斷預算、不修未證實的 FileHandle 平台競態、不更改 wire 回覆或 no-replay 政策。

## Decisions

### 預備回覆與關聯 token

既有 payload record 保留 ts、method、requestId、durationMs、params、result、error，新增 event=request_response_prepared、requestToken=現有 RequestWork.id 的 UUID 字串、peerReceipt=unconfirmed。result 僅指預備結果值經遮蔽／截斷後的預覽，不是完整 wire envelope，不等於業務成功、傳送成功或停止完成。不同 client 可重用 requestId，因此不用 requestId 單獨關聯。

僅改文件而不標記 event 會讓既有 result={} 繼續看似最終成功；刪除 result 又破壞診斷資訊，因此採新增欄位並明載多行遷移。

### 候選回覆的仲裁觀測

Reply 攜帶固定型別 outcome：result、parse_error、method_not_found、handler_error、cancelled。原 operation task 呼叫 work.result.complete(reply) 後，使用其 Bool 結果產生 request_response_candidate，包含 ts、requestToken、outcome、selection=selected 或 not_selected、peerReceipt=unconfirmed。task 在 operation 起點的取消檢查即已取消時，先 cancel gate，再記 outcome=cancelled、selection=not_offered。executeAndOffer 返回時只帶固定 outcome／selection，不額外持有 response frame；writer 在原 operation task、actor 外執行，之後才 finishOperation；不另建 logger task／queue。

此事件只報告原 operation 候選的 offer，不是所有取消來源的完整事件流。selected 表示該候選贏得單次 gate；not_selected 只表示未被選中，不能反推另一個 winner 或 peer 收到。shutdown 對其他 work 的取消 offer 維持既有行為，不在該迴圈插入可能阻塞的 writer。handler 永不返回時不偽造 outcome；operation/logger 未完仍如實追蹤。

### Shutdown 最後交接

prepareShutdown 的 logging 後守衛保持不動；拒絕時返回 cancelled Reply，原 operation 候選事件因此能區分先前的 prepared result 與後來 cancelled/not_selected。

對成功建立 plan 的 shutdown，completeShutdown 回傳固定觀測值 rejected、hook_returned 或 instance_stopped；performShutdown 早期世代不符也回 rejected。serveConnection 在 ACK 嘗試、取消回覆預算及最後交接返回後，只交付固定 handoff outcome；原 operation task 才用捕捉的 work.log 寫 request_shutdown_handoff（ts、requestToken、outcome、peerReceipt=unconfirmed）。hook_returned 只證明 hook 返回，不概括承諾任意 hook 已停止全部工作。此 log 不在 stop、transport 完成或世代 guard 的等待鏈；正常 stop 已完成後才寫。

增加內部 beforeOperation／beforeShutdownHandoff 非同步觀測接縫；前者讓 fixture 在 admission 後取消、再放行執行前檢查，後者讓自有 fixture 在 plan 已成立／ACK 已嘗試後 stop/start，再驗最後拒絕；正式預設為空操作。不能以同步 syscall 鎖內暫停模擬這個交錯。

### 固定 metadata 與消費端遷移

新增 metadata-only 事件只接受 UUID、固定 enum 與時間，不複製 params/result、method、requestId、錯誤訊息或路徑；logFull 不擴大這些事件。舊 payload record 的 redaction／truncation／malformed marker 維持。

一筆 operation 最多一筆 prepared 與一筆 candidate；有 shutdown plan 才最多再一筆 handoff。不增加無界佇列。candidate 與 handoff 由原 operation task 寫出，但跨 request 的實體行序不能當作狀態順序；消費端以 event 與 requestToken 關聯。缺事件代表未觀察／未落盤，不是成功或沒有執行。nil writer 仍完全不輸出。

### Transport 完成與 handoff writer 分離

R1 補測證實直接在 serveConnection 呼叫 handoff writer 會延後 transport 完成；原設計在這點不足，以下方案取代該安排。RequestWork 增加只保存固定 ShutdownHandoff enum 的單次觀測物件。executeAndOffer 回傳 selected 且具有 shutdown plan 的布林，不回傳 Reply/frame；原 operation 先寫 candidate，再對這種已選中 plan 等待 handoff observation 並寫 handoff，最後才 finishOperation。transport 在 performShutdown 返回後 complete 該 observation，立即退出／revoke／退休，完全不等 handoff writer。

observation 的等待刻意不自動隨 Task cancellation 撤銷：正常 stop 會取消 operation，但它仍須記錄已完成的 handoff。未被選中的 plan 或無 plan 的 request 不等待；nil logger 不等待／不輸出。已選中的 shutdown Reply 依既有 result gate 仍交付一次，ACK 失敗也執行 plan，所以 transport 必須交付一個 outcome。任意自訂 hook 永不返回時，對應的 shutdown 仍如實未完成，不偽造停止結果。使用 private lock／continuation，不新增 task 或 queue，也不改一般 request gate 的取消契約。

### 檔案 sink 的最後使用者擁有權

R1 真實 ServeLoop 測試證實 eager close 會使正常 handoff 寫入必然遺失。DaemonLogFile 為 Run 專屬的 reference owner；writer closure 持有它，Run teardown 只清除 underlying writer 與自己的 owner reference，不等待 writer，也不提前關閉仍由 request／diagnostic snapshots 使用的 sink。最後 reference 退休時關閉描述元。

以 O_APPEND／O_CLOEXEC 開啟（sink 自行建立的新檔 0600；既有檔案保留權限，包含 CLI spawner 先以 0644 建立的 stdout/stderr log）；不能只移除舊 close 並保留 seekToEnd，否則舊／新 Run 的獨立 offset 會覆寫新紀錄。同一 owner 串行寫入並處理短寫／EINTR；既有 I/O failure 仍 best-effort。舊 descriptor 繼續指向原 inode，不對晚到事件重新開啟目前路徑。LifecycleEnvironment 的預設空 log-write／sink-close 觀測只供受控 fixture，不能取得新的停止權限。

## Implementation Contract

- DaemonLog 提供型別化 candidate outcome／selection／shutdown handoff 格式化；JSON-line 一行一物件，三種 event 都有 requestToken 與 peerReceipt=unconfirmed。
- DaemonServer 保留所有既有世代／fd／仲裁守衛。先 complete/cancel gate，後寫候選 metadata；先完成 shutdown 交接並放行 transport，後由原 operation 寫 handoff。所有新 writer 呼叫都在 Instance actor 外，不增加獨立背景 logger task。
- 正常 shutdown：prepared result、candidate result/selected、handoff instance_stopped 或 hook_returned；client 正常取得 ACK。舊 writer 阻塞再 stop/start：prepared result、candidate cancelled/not_selected；client unknown、新 logger 不收到舊事件、新 instance 正常。
- Plan 後世代被撤銷：handoff rejected，不呼叫替代 hook、不停止新 instance。handler 返回晚到 result：candidate result/not_selected，不宣稱副作用回滾或 peer 已接收。
- 驗收：將 diagnostic baseline 改成新 contract 的真實 socket RED；正常與 revoked shutdown、最後交接、blocked candidate/handoff writer、logger replacement、late handler、重複 requestId、logFull、格式化／redaction 舊測試。完整非 GUI suite、關鍵守衛與事件變異、六方審查後才 verified。

## Risks / Trade-offs

- [多行 schema 影響消費端] → 保留 payload 欄位；文件要求以 request_response_prepared 篩選，不再假設每行有 result。
- [新增 writer 可能阻塞] → 在 reply gate／停止交接之後寫；不置於 actor、停止迴圈或取消回覆預算中；以 gate fixture 驗證 transport／stop 仍完成。
- [I/O 失敗或行程退出] → owner 延長有效 writer 的 sink lifetime，消除 deterministic eager-close loss；仍不承諾持久化或行程退出前一定落盤，prepared／unconfirmed 與缺事件語意保留。
- [誤把 gate 接受當 peer receipt] → selection 語意只到仲裁，所有事件明載 unconfirmed，文件及測試不聲稱遠端接收。

## Migration Plan

更新文件與 tests 的 payload 篩選，新增 event/token 欄位和 metadata 行。舊 reader 若忽略未知欄位但假設每行皆 payload，須先加入 event 篩選；沒有 event 的歷史行只能視為歷史未分類候選，不能回填傳送成功。回退版本會恢復舊 schema，不需磁碟資料轉換。

## Open Questions

取消若發生在 operation 起點檢查之後、handler 前的既有 Task.checkCancellation，仍沿用 handler_error envelope；not_offered 不涵蓋此窗口。peer 實際接收與 best-effort 檔案持久性仍不可由本地事件證明。
