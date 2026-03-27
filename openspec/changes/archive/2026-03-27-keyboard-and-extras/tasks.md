## 1. Keyboard 指令

- [x] 1.1 實作 `press` 子指令：Press a keyboard key，解析按鍵名稱並觸發 keydown + keyup 事件（`PressCommand.swift`）
- [x] 1.2 支援 Press key with modifiers：解析 `Modifier+Key` 格式（Control、Shift、Alt、Meta），設定對應的 ctrlKey/shiftKey/altKey/metaKey

## 2. Extra Interaction 指令

- [x] 2.1 實作 `focus` 子指令：Focus element by selector，呼叫 `.focus()`，含元素不存在錯誤處理（`FocusCommand.swift`）
- [x] 2.2 實作 `check` 子指令：Check checkbox，設定 `checked = true` 並觸發 change 事件，已勾選時為 no-op（`CheckCommand.swift`）
- [x] 2.3 實作 `uncheck` 子指令：Uncheck checkbox，設定 `checked = false` 並觸發 change 事件
- [x] 2.4 實作 `dblclick` 子指令：Double-click element by selector，觸發 dblclick 事件（`DblclickCommand.swift`）

## 3. 整合與驗證

- [x] 3.1 在 `SafariBrowser.swift` 註冊新子指令（press, focus, check, uncheck, dblclick）
- [x] 3.2 `swift build -c release` 編譯，複製 binary 到 `/Users/che/bin/safari-browser`
- [x] 3.3 驗證：press Enter、press Control+a、press Escape、focus、check、uncheck、dblclick
