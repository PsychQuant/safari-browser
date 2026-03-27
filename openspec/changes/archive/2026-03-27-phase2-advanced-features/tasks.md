## 1. Screenshot — 截圖

- [x] 1.1 在 SafariBridge 新增 `getWindowID()` 方法：透過 AppleScript 取得 Safari front window 的 window ID（用於 screencapture）
- [x] 1.2 實作 `screenshot` 子指令：Take window screenshot，呼叫 `screencapture -l <windowID> <path>`，預設路徑 `screenshot.png`（`ScreenshotCommand.swift`）
- [x] 1.3 支援 `--full` Take full page screenshot：透過 JS 取得 scrollHeight/scrollWidth，暫時調整視窗大小截圖後恢復

## 2. File Upload — 檔案上傳

- [x] 2.1 實作 `upload` 子指令：Upload file via file dialog（`UploadCommand.swift`）
- [x] 2.2 實作 System Events 檔案對話框流程：JS click 觸發 → 等待 sheet → Cmd+Shift+G → 輸入路徑 → Enter → Enter，含檔案不存在和元素不存在的 Element not found handling

## 3. Find Elements — 元素搜尋

- [x] 3.1 實作 `find` 子指令（`FindCommand.swift`）：Find element by text content、Find element by ARIA role、Find element by label、placeholder 四種 locator
- [x] 3.2 實作 action 執行：找到元素後支援 click、fill 動作，含 Element not found handling

## 4. Extended Element Ops — 元素操作擴充

- [x] 4.1 實作 `scrollintoview` 子指令：Scroll element into view，呼叫 `el.scrollIntoView({behavior:'smooth',block:'center'})`（`ScrollIntoViewCommand.swift`）
- [x] 4.2 實作 `highlight` 子指令：Highlight element，設定 `el.style.outline = '2px solid red'`（`HighlightCommand.swift`）
- [x] 4.3 擴充 `get` 加入 `box` 子指令：Get element bounding box，回傳 JSON 格式 {x,y,width,height}
- [x] 4.4 擴充 `is` 加入 `enabled` 子指令：Check if element is enabled，回傳 true/false
- [x] 4.5 擴充 `is` 加入 `checked` 子指令：Check if checkbox is checked，回傳 true/false

## 5. Storage Management — 儲存管理

- [x] 5.1 實作 `cookies` 子指令（`CookiesCommand.swift`）：Get cookies（全部/指定名稱）、Set cookie（name + value）、Clear cookies（過期所有 cookies）
- [x] 5.2 實作 `storage` 子指令（`StorageCommand.swift`）：Get localStorage value、Set localStorage value、Remove localStorage value、Clear localStorage，以及 sessionStorage operations（get/set/remove/clear）

## 6. Debug Tools — 除錯工具

- [x] 6.1 實作 `console` 子指令（`ConsoleCommand.swift`）：Capture console output，`--start` 注入 override、無參數讀取 buffer、`--clear` 清空
- [x] 6.2 實作 `errors` 子指令（`ErrorsCommand.swift`）：Capture JS errors，注入 window.onerror handler，讀取/清空 buffer
- [x] 6.3 實作 `mouse` 子指令（`MouseCommand.swift`）：Mouse move x y、Mouse down and up、Mouse wheel dy

## 7. 整合與驗證

- [x] 7.1 在 `SafariBrowser.swift` 註冊所有新子指令
- [x] 7.2 `swift build -c release` 編譯，複製 binary 到 `/Users/che/bin/safari-browser`
- [x] 7.3 驗證 screenshot（含 Take full page screenshot）
- [x] 7.4 驗證 Find element by text content、Find element by ARIA role + click
- [x] 7.5 驗證 scrollintoview、highlight、Get element bounding box、Check if element is enabled、Check if checkbox is checked
- [x] 7.6 驗證 Get cookies / Set cookie / Clear cookies、Get localStorage value / Set localStorage value / Remove localStorage value / Clear localStorage / sessionStorage operations
- [x] 7.7 驗證 Capture console output、Capture JS errors、Mouse move / Mouse down and up / Mouse wheel
