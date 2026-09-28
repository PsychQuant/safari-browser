## Summary

#205 將 request log 明確定義為預備回覆，並以安全、可關聯的 metadata 記錄候選回覆的仲裁與 shutdown 最後交接，避免把 result 誤讀成 peer 已收到或停止已完成。

## Motivation

在基底 1727f96 的自有 socket fixture，一般與 logFull 都重現：shutdown writer 阻塞時 stop/start，舊 log 留下 result={}／error=null，實際 DaemonClient 卻是 outcome unknown；舊 operation 返回後沒有補充事件。#199 已撤銷 transport，所以原 #198 的 cancelled wire 案例現在常為 EOF／unknown。

## Proposed Solution

既有 payload record 加 event=request_response_prepared 與 server 產生的 requestToken。operation 在單次回覆仲裁之後，記 metadata-only 的 request_response_candidate（outcome 與 selected／not_selected／not_offered）。shutdown 有 plan 時，在最後交接完成後另記 request_shutdown_handoff（rejected／hook_returned／instance_stopped）。事件保留 admission 捕捉的 writer；不宣稱本地 write 等於 peer 接收，也不讓新增 logging 延後回覆選擇或 stop。

**Migration**：既有 payload 欄位與 redaction 保留，但一筆 request 現在可有多行。以 event 篩選 payload record、以 requestToken 關聯；不能再假設每行都有 params/result 或把 result 當成傳送完成。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- persistent-daemon：request log 階段、候選仲裁／shutdown 交接結果、logger 所有權及日誌消費端遷移。

## Impact

Sources/SafariBrowser/Daemon/DaemonLog.swift、DaemonServer.swift；日誌 formatter／outcome／generation／connection 測試；CLAUDE.md、CHANGELOG.md 與 persistent-daemon 規格。不變更 wire 回覆、handler 副作用或 fallback 政策。
