## Context

#178 的 per-incident 過濾在每次 recovery 後重設，因此交替成功／失敗仍可逐次輸出。#194 在 framing 拒絕時直接關閉連線，需要不包含前綴的原因紀錄。現有 writer 於 actor 外執行；Instance.stop 沒有等待 accept loop，必須保留這個性質。

## Goals / Non-Goals

**Goals:** 共用事件預算、固定大小抑制摘要、及時呈現首次錯誤和保留的終止原因；程序持續運作時，最後的恢復摘要不必等待下一個 client。額度與摘要用控制時鐘／實際寫入路徑驗證。

**Non-Goals:** 不限制既有每請求日誌，不增加持久化或強制停止前 flush 保證；不改 RPC 輸出、重播、listener 終止通知（#198）或既有連線取消（#199）。

## Decisions

### 共用額度與終止保留

單一 Instance 的診斷 logging session 使用容量 8、每秒補充 2 token；每筆 admitted 診斷 JSON 行含 summary 行都消耗 1 token；額度約束紀錄放行時間，不是底層檔案 flush 的物理速率。一般事件只有在消耗後仍至少留下 1 token 時才能送出；terminal 事件或包含被抑制 terminal 的摘要可使用最後 token。無任何無限 bypass。使用 Duration 作為整數精度 credit（1 token = 500 ms，容量 4 s），monotonic 時鐘倒退不補充，incident recovery／quiet gap／stop-start 不重設額度。

第一筆可立即記錄；耗盡後的 incident 首筆允許被聚合，否則無法同時滿足跨 incident 硬上限。一次 listener 失效通常可使用保留 token；短時間重啟造成後續 terminal 無額度時，原因仍保留於摘要，依正常補充規則送出。

### 固定摘要與定時排出

保留七個固定事件種類的被抑制候選紀錄筆數、總數、第一筆抑制紀錄、最後的 recovery 及 terminal。計數採飽和加法，不以任意 errno 或輸入建立無界 map。計數是被抑制的候選日誌筆數，不是底層 syscall 失敗總數；#178 原有 incident 過濾保留。

下一個可送出的事件可攜帶整份摘要，或由單一 flusher 每 500 ms 嘗試送出 diagnostics_suppressed 行。摘要也消耗額度；writer 可用且排程正常時，無新事件的 pending summary 最多等兩個 tick 即可取得至少一個可用 slot。firstSuppressed／lastRecovery／lastTerminal 僅含 event、errno、disposition、count，不含 client 資料。

### Actor 外寫入與 logger 生命週期

Instance actor 只處理 clock、budget、固定記錄與 emission 準備。格式化／writer 呼叫在 actor 外，stop 不等待 writer 或 flusher。保留一個 task handle 直到該 flusher 實際完成；writer 卡住時不再派生多個 timer。stop 停用診斷、清除未送摘要並取消 timer，但不等待它；更換／停用 writer 會結束 logging session，清除舊摘要並使舊 token 失效。若 timer 尚未完成，新的 pending 摘要等同一 task 完成後才重新排程，避免堆積 timer。

排程提供者失敗時，同一 generation 不自行重試；pending 保留，後續候選事件或新 logging session 才能再排程。

stop-start 沿用額度而建立新的 flush generation；明確更換 writer 才建立新的 logging session／額度。已準備的 emission 持有原 writer，不能轉送到新 writer。已開始的 write 與既有 logging 相同，屬 best-effort，不承諾能撤回或一定在程序離開前落盤。正常運作時 timer 提供最後摘要；立即 stop／關閉 logger 或強制終止不新增 drain 等待，最後尚未送出的摘要可能不落盤，不能以排隊成功聲稱持久化成功。

### 拒絕先關閉連線

request_too_long／request_read_failed 的分類只有固定事件名與整數 errno。拒絕時先關閉自有 client fd，解除 defer 的關閉責任並釋放 reader 暫存，再進入診斷路徑。這樣慢 writer 不會延後 client 看到關閉，也不讓待寫事件持有原始 request buffer。EOF 正常結束不記錯誤；EINTR 在 reader 內重試。

## Implementation Contract

新建 DaemonDiagnosticBudget 的 typed Event／Disposition、Suppression、Emission 資料。輸出的既有事件欄位維持 timestamp/event/errno/disposition/count；有摘要時新增 suppressed，內含 total、byEvent、first、lastRecovery、lastTerminal。timer 單獨排出時頂層 event 為 diagnostics_suppressed、errno 為 0、disposition 為 suppressed、count 為 summary.total。所有 enum 值固定，不接受任意字串或原始請求。

Instance 提供內部診斷 clock／sleep 注入接點，正式 caller 使用 ContinuousClock 與 500 ms sleep。accept、setup 與 request 拒絕共用 record/prepareEmission 路徑。正常 request log 的格式、寫入呼叫與 logFull 語意維持原狀；logFull 也不能讓診斷事件攜帶 payload。

驗收使用實際診斷 emission 路徑與 writer sink：固定時間大量交替事件、連續錯誤、多 errno、quiet gap、500 ms 補充、terminal 保留、無新流量 timer 排出、writer 替換／停用、stop-start 不重設額度、慢 writer 時 stop 返回，以及真 socket 超量／讀取失敗的關閉與不 dispatch。與既有 daemon／不重播測試共同執行，完整測試及六方確認後合併。

## Risks / Trade-offs

- [停止與持久化] stop 不新增等待，最後 pending 摘要不保證送出 → 明文保留 best-effort 邊界；正常運作以 timer 排出。
- [首次錯誤] 不能逐 incident 無條件送出首筆 → 只保證 logging session 第一筆，其他 first event 用摘要保留。
- [stale timer] 舊 timer 可能晚完成 → token 檢查、原 writer 捕捉及單一 task 所有權。
- [阻塞 writer] 任意 writer 可能卡住 → 不在 actor 內呼叫，timer 不堆積，拒絕前先關 fd；不宣稱消除所有既有日誌 I/O 阻塞。

## Migration Plan

診斷 log 新增選填 suppressed 欄位及 diagnostics_suppressed 事件，既有主要欄位保持。無 CLI／RPC wire 格式變更；回退本次提交恢復舊日誌量，不影響 request framing。

## Open Questions

無待決事項；上述額度與 best-effort 邊界作為 /idd-all unattended 的明文決定。
