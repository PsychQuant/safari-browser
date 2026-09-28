## Summary

#172 讓 MCP 的正常工具呼叫重用隔離的 CLI worker，保留單筆執行、取消／逾時、輸出界線、版本檢查與不重播；以獨立監督程序處理 host 死亡時的程序群組清理。

## Motivation

基底 ea5e019 的非 live 基準：暖 MCP host 每次仍建立新 worker，wait 0 的 p50/p95 為 30.58/32.20 ms。暫時量測點進一步得到 runner p50 30.54 ms，其中 spawn syscall 0.18 ms、spawn 至 async main 5.20 ms、外層解析 2.70 ms、內層 CLI 解析 10.78 ms、命令本身 0.024 ms、退出與回收 12.19 ms。啟動至內層解析完成約占逐筆 runner 時間中位數 60.1%；各分段分位數不能直接相加。

同一程序固定重複解析 wait 0，後續解析仍約 9.98 ms；常駐化主要節省 loader／外層解析／退出回收，不能承諾消除 CLI 解析成本。這是只執行 wait 0 的診斷實驗，原始碼已還原，不是可用的常駐 worker 實作。

## Proposed Solution

- MCP 預設使用 persistent worker，提供明確 isolated 模式供相同比較與相容操作；沒有失敗後自動換引擎或重播。
- 每個 host 最多一組監督程序與執行 worker，仍只有一筆 CLI 呼叫。既有忙碌拒絕、取消及 discovery 回應保留。
- worker 每次建立新的 command struct／trace／dialog gate，以私有 control socket 傳遞請求與分段 stdout/stderr；CLI stdio 與 MCP JSON-RPC 完全分開。
- 完成時封閉該筆 stdio、等待已知輔助工作、確認所屬群組與 AX 工作已清理；不能確認可重用則退休整組，不把上一筆狀態帶進下一筆。
- 監督程序不執行 CLI；host 意外死亡時終止自己所屬的群組，涵蓋被停住的實際 worker。所有 host 發出的群組訊號綁定仍受保留的 direct-child supervisor PID。
- 閒置回收、worker 崩潰後下一筆重建、磁碟 executable 與 loaded/catalog image 比對；當筆不因未知結果重試。
- 保留 4 MiB stdin、每流 2 MiB capture、8 MiB MCP frame 及原 schema。接近 OS argv/environment 邊界的呼叫在送出前選擇原隔離路徑，維持 kernel 的原始接納行為。

## Capabilities

### New Capabilities

- mcp-persistent-worker：私有 worker 協定、生命週期／監督／請求隔離、版本失效及效能驗收。

### Modified Capabilities

- mcp-cli-facade：以可驗證的 request isolation 取代每次新 process 的限制，保留既有 schema、CLI validation、取消與輸出契約。

## Impact

MCP worker／runner／stdio 整合、CLI entry 的可重用執行邊界、BlockingDialogGate 的 request scope、既有兩個輔助 task 的結束觀測、benchmark 與 #110 回歸測試。新增私有 hidden helper，不新增公開 MCP tool，不安裝 binary、不更動 TCC、不快取 Safari 狀態。

## R2 驗證後補充

`1e0ad62` 的一般 pair 已有實際 host SIGKILL 對照通過，但合法大 argv 的預先選路在 host 死亡後仍留下 one-shot worker。這違反原清理驗收；#209 同時已重現舊 runner 的 stopped-event 誤判。兩題需共同修正 `MCPProcessRunner`／supervision／admission ownership，不能把公開輸入拒絕掉或僅列為例外取得通過。

一次性執行仍保留每筆新的 CLI 與原 kernel argv/environment 接納，但也需獨立 lifetime supervision、bounded pending owner 及真正退出判讀。原公開 schema、大小上限、未知結果不重播與 explicit daemon detach 全部維持。改動涵蓋 MCP runner／supervisor／入口 bootstrap 與其測試；不新增公開能力。
