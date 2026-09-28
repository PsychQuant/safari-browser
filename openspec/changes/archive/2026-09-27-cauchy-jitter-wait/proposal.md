## Why

#182：隨機間隔只以 plugin SKILL.md 的一行 Python 存在，由呼叫者自行複製。那行公式以 `max(2, …)` 截下界（left-censoring），10⁶ 次模擬中 22.3% 的間隔固定為 2.0 s；上界不存在，P(> 60 s) = 1/225。CLI 的 `wait` 只接受固定毫秒。

## What Changes

- `wait` 新增 `--jitter cauchy`：以 doubly truncated Cauchy 抽一次等待時間後睡眠。
- 參數 `--min`、`--max`、`--median`、`--scale`（毫秒）與 `--seed`；`--median` 是**截斷後**分布的中位數。
- 預設 [2000, 60000] ms、截斷後中位數 3000 ms、scale 800 ms。
- `--jitter` 與位置毫秒、`--for-url`、`--js` 互斥。

## Capabilities

### Modified Capabilities
- `wait`: 新增隨機間隔等待。

## Impact

WaitCommand 與一個新的抽樣器檔案、對應測試、README、CHANGELOG。不改既有純毫秒、URL、JS 等待行為，不改 daemon 與 MCP schema。全域預設節奏另見 #184；plugin SKILL.md 的文件更新另見 PsychQuant/psychquant-claude-plugins#134。
