## Why

#153：`wait` 的正整數毫秒可通過 parser，卻在乘上一百萬時超出 UInt64，造成算術異常終止。應提供明確驗證錯誤。

## What Changes

- 增加純毫秒轉奈秒檢查，拒絕負值與不可表示的結果。
- 純毫秒等待分支沿用這項轉換；保留所有可表示值。
- 增加整數上下界、predicate 優先順序與 CLI 錯誤路徑驗證。

## Capabilities

### Modified Capabilities
- `wait`: 純等待時間必須可表示為 UInt64 奈秒。

## Impact

只修改 WaitCommand 的純等待轉換與測試；不改 URL/JS 輪詢、目標判定、MCP schema 或新參數。
