## Why

safari-browser 有 36 個指令和 3 個核心模組（SafariBridge、Commands、Utilities），但目前零測試。需要建立測試基礎設施，確保重構和新增功能時不會 break 既有行為。

## What Changes

### Unit Tests
測試不依賴 Safari 的純邏輯：
- **String extension**：`escapedForAppleScript`、`escapedForJS`、`resolveRefJS`、`isRef`、`refErrorMessage`
- **Error types**：`SafariBrowserError` 各 case 的 `errorDescription` 輸出
- **Command parsing**：ArgumentParser 的參數解析和 validation（不執行 `run()`）

### E2E Tests
需要 Safari 執行的整合測試（透過 shell 呼叫 `safari-browser` binary）：
- **Navigation**：open → get url → 驗證 URL 一致
- **JS execution**：js 回傳值正確、錯誤處理
- **Element interaction**：open test page → snapshot → click @ref → 驗證導航
- **Get info**：get text/title/source 回傳非空
- **Wait**：wait 毫秒、wait --js
- **Error cases**：不存在的 selector、invalid ref

### Test Page
建立本地 HTML 測試頁（`Tests/Fixtures/test-page.html`），包含 form、checkbox、link 等元素，作為 E2E 測試的固定目標。

## Non-Goals

- 測試 Safari AppleScript 本身的行為（那是 Apple 的責任）
- Mock Safari — unit test 只測純邏輯，E2E 測真實 Safari
- 100% coverage — 目標 80%+ 對 unit testable 的程式碼

## Capabilities

### New Capabilities

- `unit-tests`: Swift XCTest 單元測試，測試字串處理、錯誤類型、指令解析
- `e2e-tests`: Shell-based E2E 測試，透過 binary 呼叫驗證完整流程

### Modified Capabilities

（無）

## Impact

- 新增：`Tests/SafariBrowserTests/StringExtensionsTests.swift`、`ErrorsTests.swift`、`CommandParsingTests.swift`、`Tests/SafariBrowserTests/E2E/E2ETests.swift`、`Tests/Fixtures/test-page.html`、`Makefile`（加 `make test`）
