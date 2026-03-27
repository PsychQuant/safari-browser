## 1. Element Interaction 指令

- [x] 1.1 實作 `click` 子指令：Click element by selector，含元素不存在的錯誤處理（`ClickCommand.swift`）
- [x] 1.2 實作 `fill` 子指令：Fill input by selector，清空後填入文字並觸發 input + change 事件（`FillCommand.swift`）
- [x] 1.3 實作 `type` 子指令：Type into element by selector，追加文字到現有值並觸發 input 事件（`TypeCommand.swift`）
- [x] 1.4 實作 `select` 子指令：Select dropdown option，設定 value 並觸發 change 事件（`SelectCommand.swift`）
- [x] 1.5 實作 `hover` 子指令：Hover element by selector，觸發 mouseover + mouseenter 事件（`HoverCommand.swift`）
- [x] 1.6 實作 `scroll` 子指令：Scroll page by direction（up/down/left/right），預設 500px，可指定像素數（`ScrollCommand.swift`）

## 2. Element Query 指令

- [x] 2.1 實作 `is` 子指令與 `visible` 子選項：Check if element is visible，回傳 true/false（`IsCommand.swift`）
- [x] 2.2 實作 `is exists` 子選項：Check if element exists，回傳 true/false

## 3. 擴充 Get 指令（Modified page-info）

- [x] 3.1 擴充 `get text` 支援 selector 參數：Get element text by selector，無 selector 時保持原行為（取整頁文字）
- [x] 3.2 新增 `get html <selector>`：Get element HTML by selector
- [x] 3.3 新增 `get value <selector>`：Get input value by selector
- [x] 3.4 新增 `get attr <selector> <name>`：Get element attribute by selector
- [x] 3.5 新增 `get count <selector>`：Get element count by selector

## 4. 整合與驗證

- [x] 4.1 在 `SafariBrowser.swift` 註冊所有新子指令（click, fill, type, select, hover, scroll, is）
- [x] 4.2 `swift build -c release` 編譯，複製 binary 到 `/Users/che/bin/safari-browser`
- [x] 4.3 驗證所有新指令：click、fill、type、select、hover、scroll、is visible、is exists、get text/html/value/attr/count（使用 example.com 測試）
