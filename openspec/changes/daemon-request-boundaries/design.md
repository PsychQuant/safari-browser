## Context

Refs #130, #136。#126 的入口警告已存在。現在的 socket 每次 read 各自逾時，整體可被逐字資料延長；exec 警告停在 daemon log。實測 NSAppleScript 普通 actor 在先執行 return、再執行 delay 時卡住，主執行緒對照正常。

## Goals / Non-Goals

Goals：請求有整體期限、結果未知不重送、exec 的警告可見且請求互相隔離、保留已編譯腳本的效能設計。

Non-Goals：不自動關閉 dialog、不承諾取消 Safari 已收到的 AppleEvent、不處理 #134/#135 的視窗配對與 AX 時間預算、不擴大 exec 支援指令。

## Decisions

### 單調時鐘期限與結果未知

DaemonClient 將阻塞 I/O 移到獨立 DispatchQueue，socket 使用 O_NONBLOCK。以 DispatchTime uptime 形成同一 deadline，connect／poll／write／read 都消費同一剩餘時間；EINTR 重試不重設期限，EOF 沒有換行不接受為完整回覆。timeout 僅接受有限且 0.001～86400 秒的值。

完整 newline-delimited request 送出後，逾時、斷線、無效 JSON、requestId 不符一律回報 requestOutcomeUnknown，fallbackReason 為 nil。收到 methodNotFound 可證明 handler 未執行，仍允許 fallback；handlerError 不能保證無副作用，直接回報。ExecCommand 對缺 results 的回覆同樣禁止重跑。一般 bridge 請求使用 min(呼叫端上限,15 秒)，exec 保留明確 60 秒。

### 主執行緒編譯快取

CompileCache 改為 MainActor 隔離類別，初始化保持無副作用且可跨執行緒呼叫。NSAppleScript 建立、編譯、執行均在同一主執行緒，繼續按 source 快取。以獨立 daemon 重複 return→delay 的測試驗證；client deadline 仍是最終等待上限，不能宣稱 timeout 等於取消腳本。

### 每次請求的執行環境與警告傳遞

新增 TaskLocal execution context：內部 AppleScript runner、BlockingDialogGate、診斷收集器。DaemonServer 執行 handler 時建立全新 gate 和收集器，成功與失敗 envelope 都可帶 diagnostics 陣列。DaemonDispatch 的 exec handler 綁定 CompileCache runner；SafariBridge.runAppleScript 優先呼叫 runner，不再連回自己的 socket。未在 daemon 請求中的 CLI 沿用原有 gate。

client 驗證完整 response 身分及形狀後，將 diagnostics 寫到 stderr，再回傳 result 或拋 error。stdout schema 維持原樣。跨請求不共用 warned/cache，單一請求內仍去除重複警告。

### 子行程同時讀取兩條 pipe

CommandDispatch 使用可指定 executable 的 subprocess helper。Process 啟動後用兩個 GCD 工作同時讀 stdout/stderr，等讀完與行程退出後組結果。stderr 在成功和失敗都轉發；非零仍保留 StepResult.error。測試以本地腳本交錯寫入超過 pipe 容量的兩種輸出，斷言無資料遺失且無死鎖。

## Implementation Contract

- `DaemonClient.sendRequest` 的 timeout 涵蓋 connect 到完整 response；0.1 秒測試期限在寬裕 0.8 秒測試容差內結束，trickle 不延長期限。
- 已送出且結果未知的請求不呼叫 stateless fallback；尚未送出的連線／握手失敗仍可退回。
- 成功與 handler error 回覆可含 `diagnostics: [String]`；兩個交錯 request 不混用 gate 或訊息。
- exec 使用內部 cached runner；原 stdout JSON 不含 warning。成功唯讀與失敗 JS 都要傳回警告。
- 本機不碰 Safari 的測試涵蓋短 delay、快取重用、socket 期限與截斷回覆；Safari fixture 涵蓋 dialog 與 exec 兩條路徑。

## Risks / Trade-offs

- client 逾時後 Safari 仍可能完成先前操作 → 明確回報結果未知，不重送。
- 主執行緒可能被長腳本佔住 → 保留獨立 socket deadline 與 lifecycle 路徑，測試同時查 status；不宣稱任意腳本皆可取消。
- 等請求結束才傳 diagnostics → 指令卡住時最遲以 client timeout 告知；本組不新增 streaming 協定。
- 舊 client 不讀 diagnostics → build handshake 要求同版本，部署時重新啟動 daemon。
