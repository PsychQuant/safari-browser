## 1. 專案骨架（Swift CLI + osascript 橋接、專案結構）

- [x] 1.1 依照專案結構建立 Swift Package（`Package.swift`），加入 `swift-argument-parser` 依賴，設定 macOS 15+ 最低版本
- [x] 1.2 建立 CLI 進入點（`Sources/SafariBrowser/SafariBrowser.swift`），設定頂層 `@main` 指令與子指令路由
- [x] 1.3 建立 Safari AppleScript 橋接層（`Sources/SafariBrowser/SafariBridge.swift`），採用 AppleScript 執行方式：Process.osascript 而非 ScriptingBridge，依照 Safari AppleScript 能力對照表封裝所有指令

## 2. Navigation — URL 導航

- [x] 2.1 實作 `open` 子指令：Open URL in current tab（預設行為）、Open URL in new tab（`--new-tab`）、Open URL in new window（`--new-window`），含 Safari 未啟動時自動啟動
- [x] 2.2 實作 `back` 子指令：Navigate back（透過 `do JavaScript "history.back()"`)
- [x] 2.3 實作 `forward` 子指令：Navigate forward（透過 `do JavaScript "history.forward()"`)
- [x] 2.4 實作 `reload` 子指令：Reload page（透過 `do JavaScript "location.reload()"`)
- [x] 2.5 實作 `close` 子指令：Close current tab（透過 AppleScript `close current tab`）

## 3. JS Execution — JavaScript 執行

- [x] 3.1 實作 `js` 子指令：Execute inline JavaScript，透過 `do JavaScript` 執行字串並將結果印到 stdout
- [x] 3.2 加入 `--file` 選項：Execute JavaScript from file，讀取檔案內容後執行，含檔案不存在的錯誤處理
- [x] 3.3 處理 JS 執行錯誤：解析 AppleScript 錯誤訊息，輸出到 stderr 並以非零狀態碼退出

## 4. Page Info — 頁面資訊取得

- [x] 4.1 實作 `get` 子指令與 `url` 子選項：Get current URL（Safari 原生 `URL` 屬性）
- [x] 4.2 實作 `get title`：Get page title（Safari 原生 `name` 屬性）
- [x] 4.3 實作 `get text`：Get page text（Safari 原生 `text` 屬性）
- [x] 4.4 實作 `get source`：Get page source（Safari 原生 `source` 屬性）

## 5. Tab Management — Tab 管理

- [x] 5.1 實作 `tabs` 子指令：List all tabs，輸出格式為 `<index>\t<title>\t<url>`，含無 tab 時空輸出
- [x] 5.2 實作 `tab <n>` 子指令：Switch to tab by index，含 Invalid tab index 錯誤處理
- [x] 5.3 實作 `tab new` 子指令：Open new empty tab

## 6. Wait — 等待機制

- [x] 6.1 實作 `wait <ms>` 子指令：Wait for duration，暫停指定毫秒數
- [x] 6.2 實作 `wait --url <pattern>` 選項：Wait for URL pattern，輪詢直到 URL 包含 pattern，含 Default timeout 30 秒
- [x] 6.3 實作 `wait --js <expr>` 選項：Wait for JS condition，輪詢直到 JS 表達式為 truthy，含 timeout 處理
- [x] 6.4 加入 `--timeout <ms>` 選項：覆寫預設 30 秒 timeout

## 7. 建置與安裝（與 agent-browser 的 CLI 介面對照驗證）

- [x] 7.1 `swift build -c release` 編譯，複製 binary 到 `/Users/che/bin/safari-browser`
- [x] 7.2 手動驗證所有指令：open、js、get、tabs、tab、wait、back、forward、reload、close
