## Why

#184 要讓批次呼叫者不必在每個操作之間手動插入 `wait --jitter`。既有抽樣器已完成，但 standalone、兩種 MCP 與 daemon 批次路徑的執行邊界不同，必須有一份一致且預設關閉的節奏契約。

## What Changes

- 提供 `SAFARI_BROWSER_PACING=cauchy|off` 與四個以毫秒為單位的參數環境變數，沿用截斷 Cauchy 與奈秒檢查；未設定與 `off` 不增加等待。
- 一般命令執行後自動等待一次；設定／抽樣在副作用前完成，runtime error保留原錯誤，取消不重播已完成操作。
- 明確排除 help／解析錯誤、顯式wait、daemon管理、host與hidden wrapper。exec以每步為邊界，整批不重複等。
- 啟用pacing時，exec在送出前預選既有逐步subprocess路徑，每步仍可使用daemon；關閉時保留原整批快速路徑。
- standalone、isolated MCP與persistent MCP共用解析後的命令執行邊界，避免漏等或多等。

## Capabilities

### New Capabilities

- `command-pacing`: opt-in環境設定、命令分類、單次等待、取消與呼叫端一致性。

### Modified Capabilities

- `script-exec`: 為daemon整批選路增加明確的pacing opt-in例外，逐步等待不發生執行後fallback。

## Impact

- 產品：`CLIExecution.swift`、`MCPWorker.swift`、`ExecCommand.swift`，新增pacing policy/helper。
- 驗證：設定與執行邊界單元測試、自有非GUI命令／MCP／daemon fixture、變異與既有回歸；`Tests/command-pacing-test.py`透過Makefile的`test-command-pacing`接入`test-all`。
- 文件：README、CHANGELOG；不改daemon wire schema、既有wait抽樣器或預設速度。
