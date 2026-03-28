## 1. Test Fixture — Test page fixture

- [x] [P] 1.1 建立 Test page fixture `Tests/Fixtures/test-page.html`：包含 h1、a（link）、form（text input + submit button）、checkbox、select dropdown、hidden div，title 為 "Safari Browser Test Page"

## 2. Unit Tests — Test string escaping for AppleScript、Test string escaping for JavaScript、Test ref resolution JS generation、Test error descriptions、Test command argument parsing

- [x] [P] 2.1 建立 `Tests/SafariBrowserTests/StringExtensionsTests.swift`：Test string escaping for AppleScript（雙引號、反斜線）、Test string escaping for JavaScript（單引號）、Test ref resolution JS generation（CSS selector passthrough、Ref resolution、isRef detection）
- [x] [P] 2.2 建立 `Tests/SafariBrowserTests/ErrorsTests.swift`：Test error descriptions，驗證所有 SafariBrowserError case 的 errorDescription
- [x] [P] 2.3 建立 `Tests/SafariBrowserTests/CommandParsingTests.swift`：Test command argument parsing，驗證 OpenCommand（URL + flags）、JSCommand（validation）、WaitCommand（timeout）的 ArgumentParser 解析

## 3. E2E Tests — E2E navigation test、E2E JavaScript execution test、E2E snapshot and ref test、E2E get info test、E2E wait test、E2E error handling test

- [x] 3.1 建立 E2E navigation test（`E2ETests.swift`）：open test-page.html → get url → 驗證包含 test-page
- [x] 3.2 建立 E2E JavaScript execution test：js "1 + 1" → 驗證 stdout 含 "2"；js "document.title" → 驗證含 test page title
- [x] 3.3 建立 E2E snapshot and ref test：snapshot → 驗證 stdout 含 @e1
- [x] 3.4 建立 E2E get info test：get title → 驗證含 "Safari Browser Test Page"；get text "h1" → 驗證非空
- [x] 3.5 建立 E2E wait test：wait 500 → 驗證 exit code 0
- [x] 3.6 建立 E2E error handling test：click ".nonexistent" → 驗證 exit code != 0；click @e99 → 驗證 exit code != 0

## 4. 整合

- [x] 4.1 更新 `Makefile`：加入 `make test`（`swift test`）
- [x] 4.2 執行 `swift test` 確認所有 unit tests 通過
- [x] 4.3 執行 E2E tests 確認通過（需要 Safari 開啟）
