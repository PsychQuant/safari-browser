## Why

每次 `safari-browser` 呼叫目前花 **~370ms**（量過兩次連跑都一樣，代表 process launch + AppleScript JIT compile 才是主成本，kernel file cache 不幫 JIT）。對 agent 單一命令感覺不到，但做 multi-step automation（例如 snapshot → click → verify → snapshot 這種典型 loop）時，10 個步驟就硬多 3.7 秒純 overhead。

browser-harness 用長駐 daemon 把每次 call 降到 <10ms（預編譯 protocol + warm websocket）。safari-browser 因為必須用 AppleScript（Safari 沒有 CDP），amortize 不到 browser-harness 那麼低，但可以預期 **370ms → ~60-100ms（約 4 倍）**，主要 win 來自 keep NSAppleScript handles pre-compiled 而非重新 osascript compile。

此 change 新增 opt-in `--daemon` 模式，不取代預設 stateless CLI —— 保留 Non-Interference / fail-closed ambiguous match / spatial gradient 這些契約的現狀，讓 daemon 成為**純加速選項**，agent 在需要高吞吐 workflow 時可開啟。

## What Changes

- **新 capability `persistent-daemon`**：定義 daemon 模式的啟動 / IPC / 生命週期 / fallback / 正確性契約。
- **`--daemon` opt-in flag**（等價 env `SAFARI_BROWSER_DAEMON=1`）：client 嘗試連 daemon socket；若連不到，silently fallback 到現有 stateless AppleScript 路徑（可選 stderr warning）。
- **新 subcommand 群 `safari-browser daemon {start,stop,status,logs}`**：手動管理 daemon 生命週期（status 應含 pid、uptime、待處理 request、預編譯 script 數）。
- **IPC via Unix domain socket** `/tmp/safari-browser-<NAME>.sock`：JSON lines protocol（直接借用 browser-harness `daemon.py` 協議格式，包含 `{method, params}` request、`{result}` / `{error}` response）。
- **Multi-session namespace**：`SAFARI_BROWSER_NAME` env（預設 `default`）或 `--name` flag 決定 socket path suffix，讓 parallel agent 各走獨立 daemon。
- **Idle auto-shutdown**：daemon 內建 timer，預設 10 分鐘無 command 自動退出；`SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` env 可調（最小 60 秒、最大 3600 秒，超出範圍 clamp）。
- **No Safari state cache（Path A）**：daemon 只保留 pre-compiled `NSAppleScript` objects，**每次 call 重新向 Safari 查詢當下 window/tab 狀態**，確保正確性與 fail-closed ambiguous match 契約不變。
- **Non-Interference spec delta**：明確宣告 daemon process 本身是 passively interfering 的第 X 級，但使用者隨時可透過 `safari-browser daemon stop` 或 idle timeout 終止 —— 不違反「使用者可關閉 agent 背景行為」的硬性契約。
- **Human-Emulation spec delta**：spatial gradient 的 4 層判定（noop / current tab / raise / new tab）在 daemon 模式下與 stateless 模式**必須行為一致**；daemon 不得因為有 cached handle 而跳過 Safari 狀態查詢。

## Non-Goals

<!-- 在 design.md 的 Goals / Non-Goals section 展開 -->

## Capabilities

### New Capabilities

- `persistent-daemon`: 定義 opt-in 長駐 daemon 的啟動契約、IPC 協議、namespace 規則、idle shutdown、fallback 行為、與「不 cache Safari state」的正確性保證。

### Modified Capabilities

- `non-interference`: 新增 requirement 明確列舉 daemon 模式的干擾分級與使用者退出機制，確保 daemon 存在不破壞預設非干擾承諾。
- `human-emulation`: 新增 requirement 要求 daemon 模式下所有 target resolution（spatial gradient、`--url` ambiguous match）的行為與 stateless 模式完全一致。

## Impact

- **Affected specs**：
  - 新增 `openspec/specs/persistent-daemon/spec.md`
  - 修改 `openspec/specs/non-interference/spec.md`（delta：daemon passive interference 分級 + 退出契約）
  - 修改 `openspec/specs/human-emulation/spec.md`（delta：daemon 模式行為一致性）
- **Affected code**（均在 safari-browser repo）：
  - 新增 `Sources/SafariBrowser/Daemon/DaemonServer.swift`（Unix socket server + JSON lines dispatcher + NSAppleScript handle cache）
  - 新增 `Sources/SafariBrowser/Daemon/DaemonClient.swift`（client-side connect/fallback 邏輯）
  - 新增 `Sources/SafariBrowser/Daemon/PreCompiledScripts.swift`（預編譯常用 AppleScript 清單 + handle 管理）
  - 新增 `Sources/SafariBrowser/Commands/DaemonCommand.swift`（`daemon start/stop/status/logs` subcommand）
  - 修改 `Sources/SafariBrowser/SafariBridge.swift`（檢查 `--daemon` / env，若 daemon available 走 client；否則走既有 osascript 路徑）
  - 修改 `Sources/SafariBrowser/SafariBrowser.swift`（註冊 `DaemonCommand` + 全域 `--daemon` flag parsing）
- **Affected docs**：
  - 更新 `CLAUDE.md` 補 daemon section（何時開、風險、與 principles 的互動）
  - 更新 `README.md` 的 Quickstart 提及 daemon 選項
- **Affected tooling**：無新 build dependency。Unix socket + NSAppleScript 都是 macOS / Foundation 內建。
- **Affected tests**：新增 daemon unit tests + 驗證 fallback 路徑的 integration tests。
