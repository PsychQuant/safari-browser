## Context

milliseconds 是 Int；現有程式只檢查 >=0，再直接乘上一百萬。UInt64 可表示的最大整數毫秒為 18_446_744_073_709。此修復採原本完整範圍，不套用其他 process timeout 的一天上限。

## Decisions

使用純 `WaitCommand.nanoseconds(forMilliseconds:)`：先拒絕負值，接著 `multipliedReportingOverflow`。溢位時丟出 ValidationError，訊息指出最大可表示毫秒值。只有 run() 原本選中的純毫秒分支呼叫此函式；不移到整個命令的 validate()，以保留同時指定 predicate 與毫秒時的既有優先順序。

## Validation

直接測 Int.min、-1、0、一般值、上界、上界加一及 Int.max 的轉換，禁止真的等待巨大上界。檢查 --for-url/--js 與毫秒共同解析的原本行為。以真正 CLI 執行 0 與超界值，確認後者 exit64 且有明確錯誤，不是 signal。既有 wait/CLI 回歸與獨立審查均須完成。

## Risks

只抽取原本的轉換運算。負值錯誤保持原訊息；新錯誤僅涵蓋原本必定溢位的範圍。
