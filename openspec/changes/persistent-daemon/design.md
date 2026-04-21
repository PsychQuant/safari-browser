## Context

此 change 為 safari-browser#32 Wave 2 G2。discuss session（2026-04-21）鎖定 6 項設計決策：opt-in、NSAppleScript handle caching、Unix socket IPC、silent fallback、idle auto-shutdown、**no state cache（Path A）**。本 design.md 把這 6 項展開，並處理 discuss 階段未解的次要 open questions。

現狀：

- safari-browser 主體是 **stateless CLI**，每次 invoke 從零啟動 Swift process + osascript 子程序 + AppleScript JIT compile，實測 `safari-browser documents` cold-start 約 **370ms**，兩次連跑無差異（確認 kernel file cache 無法 amortize AppleScript JIT）。
- `SafariBridge.swift` 是 **2148 行 `enum`**（static namespace，非 stateful object），分散使用 `osascript` 子程序。
- 另有 3 個 commands（Screenshot / Pdf / Upload）直接呼叫 osascript，不走 SafariBridge —— daemon 要 cover 這四條路徑才有全面效益。
- 既有 in-progress change `save-image-subcommand` 正在改動 ScreenshotCommand —— 本 change 需避免衝突。

約束：

- 必須完全保留現有 stateless 路徑，不能把 daemon 變成硬依賴。
- 必須保留 `ambiguousWindowMatch` fail-closed、spatial gradient 4 層、Non-Interference 預設不 raise 等既有契約。
- 不引入新 build dependency。
- 不增加非 Apple 框架的 IPC 層（Unix socket + Foundation 夠用）。

## Goals / Non-Goals

**Goals:**

- 把 per-command 從 370ms 降到 **≤100ms**（目標 60-80ms），在連續 multi-step automation 時有明顯體感。
- Daemon 模式下的**正確性與 stateless 模式完全一致**（使用者切 tab、關 window、切 Space 等行為，daemon 不得因為有 cached state 而誤判）。
- Daemon 為 **opt-in 純加速選項**，未啟用時 safari-browser 行為與現狀完全相同。
- 提供使用者可視、可控的 daemon 生命週期（start / stop / status / logs）。
- 與 `save-image-subcommand` 並行開發不衝突。

**Non-Goals:**

- **不預設啟動 daemon**。預設 stateless 是 safari-browser 的 brand promise 之一。
- **不 cache Safari state**（不 cache window list / tab IDs / URLs），只 cache pre-compiled `NSAppleScript` object references。
- **不做 reactive invalidation**（不 subscribe Safari events，也不 polling Safari 狀態）。Safari AppleScript API 無 event stream，任何 invalidation 策略都要 polling，成本反而超過 win。
- **不支援跨機器 / remote** daemon。Unix socket only，不開 TCP、不開 auth token。
- **不整合 launchd / systemd**。idle auto-shutdown + 手動 start 即夠用，不做 at-boot 自動啟動。
- **不做 cross-version 相容性**。Daemon 和 CLI 從同一份 build 出來，版本 mismatch 時 daemon startup 檢查會 refuse 啟動並 fallback 到 stateless。
- **不取代 save-image-subcommand 的 screenshot 路徑**；那個 change 先 land，此 change 再 cover 新路徑。
- **不 cover 所有 commands**。第一版先支援最高頻 commands（snapshot / click / fill / js / documents / get url / wait / storage）；其他仍走 stateless。

## Decisions

### Daemon 為 opt-in，不改變 CLI 預設行為

每個 command 啟動時檢查三個訊號，任一成立才嘗試連 daemon：

1. CLI 有 `--daemon` flag
2. Env `SAFARI_BROWSER_DAEMON=1`
3. 目標 socket 已存在且 daemon process 還活著（讓 agent 先 `daemon start` 一次，後續 command 不用一直加 flag）

三個都不成立 → 走既有 stateless osascript 路徑，zero behaviour change。

**理由**：Non-Interference spec 的硬性契約是「使用者沒主動啟用就不該有 background process」。Opt-in 保留此契約；envar + live-socket 檢查讓 agent workflow 不用每個 call 都加 flag。

**替代方案**：預設開 daemon。拒絕 —— 會破壞使用者對 safari-browser 「一個 CLI 呼叫完就沒 process 留下」的信任。

---

### 主 win 來自 NSAppleScript handle pre-compilation，不是 process warm-ness

Daemon 啟動時 pre-compile 常用 AppleScript 為 `NSAppleScript` object 留在記憶體：

```swift
// Sources/SafariBrowser/Daemon/PreCompiledScripts.swift
static let enumerateWindows: NSAppleScript = compile("""
    tell application "Safari"
        ...
    end tell
""")
```

每次 request 走 `handle.executeAndReturnError(_:)` 走 warm path，繞過 osascript 的 compile phase。

**預期量級**：370ms → ~60-100ms（原本約 80% 的時間花在 compile + process spawn）。第一個 request 會多 ~30ms 做 handle lazy-init，之後平均 <70ms。

**預編譯清單（第一版）**：`enumerate-windows`, `get-tab-url`, `activate-tab`, `run-js-in-current-tab`, `set-current-tab`, `dispatch-mouse-event`, `dispatch-key-event`。約 7-10 個 scripts，rewrite 自 SafariBridge.swift 現有 osascript 片段。

**理由**：量測顯示 cold-start 和 warm 連跑沒差異，確認 AppleScript JIT 才是主成本（process launch 相對便宜）。

**替代方案**：除了 handle cache 還 cache Safari state。在 discuss 階段展開後拒絕（見下 No state cache decision）。

---

### IPC：Unix domain socket + JSON lines + per-NAME namespace

Socket path：`/tmp/safari-browser-<NAME>.sock`，`NAME` 由 `SAFARI_BROWSER_NAME` env 或 `--name` flag 決定，預設 `default`。

Wire format（每行一筆 JSON）：

```
→ {"method": "Safari.snapshot", "params": {"includeInteractive": true, "url": "plaud"}, "requestId": 17}
← {"requestId": 17, "result": {"refs": [...]}}
```

錯誤：`{"requestId": 17, "error": {"code": "ambiguousWindowMatch", "message": "...", "data": {...}}}`

**理由**：

- Unix socket = per-user 權限自然、無網路暴露、macOS / Linux 都支援。
- JSON lines 協議 = 簡單、可除錯、可用 `nc -U` 手動戳；直接借用 browser-harness 的 `daemon.py` 設計。
- `NAME` namespace 讓 2 個 agent 並行（例如同時操作兩個 Safari profile）不互相踩 —— 直接模仿 browser-harness 的 `BU_NAME`。

**替代方案**：
- TCP + loopback：拒絕，容易被本機其他程式或 docker container 誤連。
- Named pipe：macOS 支援但不如 Unix socket streamlined。
- gRPC / MsgPack：拒絕，多一層序列化 library，對本地單機 IPC 過度。

---

### No Safari state cache（Path A，不快取 window / tab / URL 映射）

Daemon 只 cache pre-compiled `NSAppleScript` objects。每次 request 都透過 warm handle 重新向 Safari 查詢當下 state。

**理由**（discuss 已展開）：

- AppleScript 無 event stream，reactive invalidation 只能靠 polling（例如每秒 enumerate 一次 windows）。Polling 本身的成本（每秒 ~30-50ms AE roundtrip）累積起來比 Path A 的 per-call cost 還高。
- TTL 型 cache（例如 2 秒 TTL）在使用者任意操作下無法保證正確。`--url plaud` 比對 cache 可能指向已關閉的 tab 或已 shift index 的 window，導致**靜默誤操作**（點到錯的網頁），破壞 `ambiguousWindowMatch` fail-closed 契約。
- Path A 每次 call 雖多 ~30-50ms AE roundtrip，但從 370ms 降到 ~60-100ms 已是使用者有感差異（sub-100ms feels instant）；多省的 ~30ms 不值得犧牲正確性。

**替代方案（Path B，cache with invalidation）**：在 discuss 展開後拒絕。

---

### 失敗時 silently fallback 到 stateless

Client 連 daemon socket 若遇以下情況，**透明降級**走既有 osascript 路徑（附帶一次 stderr warning `[daemon fallback: <reason>]`）：

- Socket 不存在
- 連線被 refused
- Daemon 回 `error` 但 stateless 可能 work（例如 daemon 還沒 init 完某個 handle）
- Socket 連上但 15 秒內無 response（timeout）

Daemon 絕不是硬依賴。`--daemon` flag 意思是「有就用，沒就算了」。

**理由**：保留 stateless 路徑作為安全網，避免 daemon bug / crash / 升級錯誤讓所有 CLI invocation 失效。

**替代方案**：daemon 失敗時 error out。拒絕 —— 把 daemon 從加速選項變成故障點。

---

### Idle auto-shutdown 預設 10 分鐘

Daemon 內建 `Task` 追蹤「最後一次 request 完成時間」；持續 10 分鐘無 request 則自己退出（釋放 socket、刪 pid 檔）。

`SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` env 可調，範圍 **60 – 3600 秒**（超出 clamp 到邊界）。

**理由**：

- Non-Interference spec 要求「使用者隨時可終止 agent 背景行為」—— 自動超時等價於「使用者不在 agent workflow 時自動清掉」。
- 10 分鐘對連續 automation 夠用，連續 snapshot-click loop 每步低於 60 秒所以不會中斷。
- 不搞 launchd 自動啟動 —— agent workflow 結束就結束，不該常駐。

**替代方案**：無 timeout（使用者自己管）。拒絕 —— 違反 Non-Interference 預設不留駐契約。

---

### Daemon subcommand group：`safari-browser daemon {start, stop, status, logs}`

- `start`：fork detached daemon process，wait 至 socket listening 後 exit；已 running 則 no-op。
- `stop`：送 shutdown request 給 socket，等 daemon graceful exit；socket 不在則 no-op。
- `status`：顯示 pid / uptime / 已處理 request 數 / pre-compiled script 數 / 最後 activity 時間。
- `logs`：tail `/tmp/safari-browser-<NAME>.log`。

**理由**：使用者需要可視的 daemon 生命週期控制。`status` 讓 agent 也能 inspect daemon 狀態（例如開 new session 前先確認 daemon alive）。

---

### 版本相容：Daemon 和 CLI 必須同一 build，不同版 daemon startup 檢查拒絕啟動

Daemon 啟動時寫入 `/tmp/safari-browser-<NAME>.pid` 附帶 build identifier（git commit hash + version）。Client 連線時握手驗證；不合則 client silently fallback 到 stateless 並 stderr warning「daemon version mismatch」。

**理由**：Daemon 的 JSON protocol 會隨 CLI 演進，跨版本相容成本高。強制同版是最簡單契約。使用者升級 CLI 後第一次呼叫自動 kill 舊 daemon 重啟 —— 可接受的 one-time cost。

---

### 與 `save-image-subcommand` 的順序

優先讓 `save-image-subcommand`（已 in-progress）先 land —— 該 change 的 tasks 已 0/16，但既然已建，應先完成避免並發衝突。本 change 的 DaemonServer 若要 cover screenshot，等 `save-image-subcommand` archive 後再 PR 合併。

**Tasks.md 明確標注**：Phase 1 暫不 cover ScreenshotCommand（它在另一個 in-progress change 中），後續 follow-up 補。

---

### 第一版 command coverage 限制

Phase 1 cover：`snapshot`, `click`, `fill`, `type`, `press`, `js`, `documents`, `get url`, `get title`, `wait`, `storage`。

Phase 1 **不** cover：`screenshot`, `pdf`, `upload --native`, `upload --allow-hid`（這四個有 AX / keystroke 特殊路徑，daemon 化複雜度遠高於單純 osascript 替換）。

**理由**：先用有感 win 驗證架構，再逐步擴大 coverage。

## Risks / Trade-offs

| 風險 | 緩解 |
|---|---|
| Daemon crash 或 stale socket 導致所有 CLI 卡住 | Silent fallback + 15 秒 timeout；fallback 行為和 daemon-off 完全一致 |
| Pre-compiled NSAppleScript 在 Safari 更新後行為改變（例如 AppleScript dictionary 變動） | Daemon 啟動時 dry-run 每個預編譯 script 驗證；失敗則拒絕啟動並 fallback |
| `--url` 跨 Space 行為在 daemon 模式漏掉使用者剛切 Space 的變動 | Path A 每次 re-query Safari，天然正確；此風險**不存在於本 design** |
| Daemon 被異常終止留下 stale socket / pid | 啟動時掃既有 pid，kill -0 檢查是否存活；不存活則清理 |
| 兩個使用者同時啟動 daemon（非典型情境，但同 host 多 tmux session 可能觸發）| `NAME` namespace 隔離 socket 路徑，user A 的 `default` 和 user B 的 `default` 不同 `/tmp/*.sock`（macOS 預設 `/tmp` per-user 非隔離，要改用 `$TMPDIR`） |
| Daemon 記憶體洩漏（長時間跑記憶體漲） | Idle auto-shutdown 10 分鐘已本質上切斷。另外 DaemonServer 用 per-request Task，不累積狀態 |
| 過早 optimize — 多花時間在 daemon，G4/G5 stall | 本 change 明確限定 Phase 1 coverage，不 cover all commands；預計 2-3 週實作 |
| 使用者誤以為 daemon 永遠開著，結果在 idle timeout 後一個 command 又多付 startup 成本 | `daemon status` 可查；加 `--daemon-auto-restart`（opt-in opt-in，預設關）之類選項留到 future follow-up |
| Daemon 啟動時 pre-compile 失敗（例如 Safari 沒啟動無法 connect）| Pre-compile 只做 AppleScript source → bytecode，不需 Safari 已啟動；失敗 = AppleScript source 本身有語法錯，應該 build-time 抓到 |

## Open Questions

- **Pre-compile 清單的確切選擇**：提案 7-10 個 scripts 應足夠涵蓋 Phase 1 commands，但具體要哪幾個、如何組合參數化（AppleScript 不支援高階函數，要手寫 placeholder substitution 還是每個 variant 各編一份？）留到實作時決定。Tasks.md 標為 implementation-time call。
- **Daemon logs 格式**：純文字 vs JSON vs structured logging library？Phase 1 採純文字 + timestamp（最簡），未來需要 machine-readable 再升級。
- **Idle timeout 重置精確度**：每個 request 收到時重置計時器，還是 request 完成時？選「收到時」較寬鬆（避免長 request 進行中被 shutdown）。
- **Parallel request 處理**：daemon 要 serialize 所有 Safari AppleScript 呼叫（Safari 本身不支援並行 AE），還是讓 client 自己排隊？選 daemon 內 serialize（對 client 透明），用 Swift actor 實作。
