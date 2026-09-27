## Problem

#190 記錄大型 JS 輸出曾成功寫出前批資料。原始 OpenAlex 事件尚未重現，但正式 JSCommand／SafariBridge 搭配 JavaScriptCore 的交錯測試已證實：要求 new-batch 的呼叫會成功寫出另一呼叫的 old-batch。

## Root Cause

一般與大型 JS 共用 window.__sbResult 等暫存欄位。執行、讀長度、取回資料與清除各為不同往返，沒有呼叫身分及分塊完整性驗證。清除前一次欄位不能防止中途由其他呼叫覆寫。

## Proposed Solution

使用逐呼叫的頁面結果物件，明確標示 prepared／running／done／error；回讀框架攜帶呼叫識別與區段界限。以同一個結果物件支援一般讀取及分塊後備，不重跑使用者程式。共享讀取函式的 Get 與 Snapshot 呼叫者一併納入驗證。

## Success Criteria

- 正式指令交錯測試不能把 old-batch 寫成 new-batch 的結果。
- 遺失、錯識別與不完整回覆明確失敗，目的檔不被失敗結果覆寫。
- 空結果、表達式／函式本體、CSP 相容性、執行期錯誤不重跑與已知導頁行為有測試。
- 大型 Unicode 內容完整往返，僅清除本次狀態。

## Capabilities

### New Capabilities

無。

### Modified Capabilities

- `js-execution`: 新增逐呼叫結果歸屬、完整性與生命週期契約。

## Impact

- Sources/SafariBrowser/Commands/JSCommand.swift
- Sources/SafariBrowser/Commands/JSWrapper.swift
- Sources/SafariBrowser/JavaScriptResultSession.swift（新增）
- Sources/SafariBrowser/SafariBridge.swift
- Sources/SafariBrowser/Commands/GetCommand.swift
- SnapshotCommand 的共用 helper 呼叫相容性
- Tests/SafariBrowserTests/JSResultIsolationTests.swift、JSWrapperTests.swift、導頁及 bridge 回歸測試
