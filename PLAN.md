# safari-browser — 設計計畫

## 定位

macOS 原生的瀏覽器自動化工具，用 Safari + AppleScript 取代 agent-browser (Playwright/Chromium)。

**核心優勢：永遠登入** — 使用者的 Safari session 直接可用，不需要任何 auth 管理。

## 為什麼不用 agent-browser

從 2026-03-21 的 Plaud 實戰中發現：

1. agent-browser 每次啟動是全新 Chromium，cookies 不保留
2. `state save/load` 不穩定 — headed/headless 之間不互通
3. `fill` 在 Vue 網站上常失敗（reactivity 不觸發）
4. `find text` 匹配多個元素時失敗
5. 最後 90% 的操作都用 `eval` 跑 JS，snapshot/ref 系統用不上

## 架構選項

### 選項 A：Shell 腳本包裝 osascript

```bash
safari-browser open "https://example.com"
safari-browser js "document.title"
safari-browser upload "/path/to/file.mp3"
safari-browser screenshot output.png
```

- 優點：零依賴、立即可用
- 缺點：shell 腳本不好維護、osascript 呼叫有額外開銷

### 選項 B：Swift CLI

```bash
safari-browser open "https://example.com"
safari-browser js "document.title"
safari-browser upload "/path/to/file.mp3"
safari-browser screenshot output.png
```

- 優點：原生 macOS API、可直接用 ScriptingBridge、效能好、跟其他 che MCP server 一致（全 Swift）
- 缺點：需要編譯

### 選項 C：Claude Code Plugin（純 skill，不寫 CLI）

不建立獨立 CLI，直接在 skill 裡寫 osascript 指令。

- 優點：最簡單
- 缺點：沒有可重用的 CLI 工具、其他專案不能用

### 建議：選項 B（Swift CLI）+ Plugin 包裝

跟 che-ical-mcp、macdoc 等一致的開發模式。

## 核心 API 設計

### 導航

```bash
safari-browser open <url>              # 開啟 URL（新 tab 或現有 tab）
safari-browser open <url> --new-tab    # 強制開新 tab
safari-browser open <url> --new-window # 強制開新視窗
safari-browser back                    # 上一頁
safari-browser forward                 # 下一頁
safari-browser reload                  # 重新載入
safari-browser close                   # 關閉當前 tab
```

### JavaScript 執行

```bash
safari-browser js "<code>"             # 執行 JS，回傳結果
safari-browser js --file script.js     # 從檔案執行
safari-browser js --async "<code>"     # 非同步執行（用 window.__result 取結果）
safari-browser js --wait 5 "<code>"    # 執行後等待 N 秒再取結果
```

### 取得資訊

```bash
safari-browser get url                 # 當前 URL
safari-browser get title               # 頁面標題
safari-browser get text                # 頁面純文字（Safari 原生屬性）
safari-browser get source              # 頁面 HTML 原始碼（Safari 原生屬性）
```

### 檔案上傳（System Events）

```bash
safari-browser upload <selector> <file_path>
# 1. JS: document.querySelector(selector).click() → 開啟檔案對話框
# 2. System Events: Cmd+Shift+G → 輸入路徑 → Enter → Enter
```

### 截圖

```bash
safari-browser screenshot [output.png]           # 截取 Safari 視窗
safari-browser screenshot --full [output.png]    # 全頁截圖（JS scrollHeight 計算）
```

### Tab 管理

```bash
safari-browser tabs                    # 列出所有 tab
safari-browser tab <n>                 # 切換到第 n 個 tab
safari-browser tab new                 # 開新 tab
safari-browser tab close               # 關閉當前 tab
```

### 等待

```bash
safari-browser wait <ms>               # 等待 N 毫秒
safari-browser wait --url "<pattern>"  # 等到 URL 匹配
safari-browser wait --js "<expr>"      # 等到 JS 表達式為 truthy
```

## Safari AppleScript 能力對照表

| 能力 | AppleScript 指令 | 備註 |
|------|-----------------|------|
| 開 URL | `open location` 或 `set URL of tab` | |
| 執行 JS | `do JavaScript` | 回傳值為字串 |
| 取 URL | `get URL of current tab` | 原生屬性 |
| 取標題 | `get name of current tab` | 原生屬性 |
| 取純文字 | `get text of current tab` | 原生屬性 |
| 取 HTML | `get source of current tab` | 原生屬性 |
| 列出 tab | `get name of every tab` | |
| 切換 tab | `set current tab to tab N` | |
| 新 tab | `make new tab with properties {URL:...}` | |
| 關 tab | `close current tab` | |
| 截圖 | `screencapture -l <windowID>` | 需先用 CGWindowListCopyWindowInfo 取得 window ID |
| 上傳檔案 | System Events keystroke | Cmd+Shift+G 前往路徑 |
| 前進/後退 | `do JavaScript "history.back()"` | 沒有原生指令，用 JS |

## System Events 檔案上傳流程

```applescript
-- 前提：已用 JS 點擊了 <input type="file">
tell application "System Events"
    tell process "Safari"
        -- 等待檔案對話框出現
        repeat until exists sheet 1 of front window
            delay 0.5
        end repeat

        -- Cmd+Shift+G 前往路徑
        keystroke "g" using {command down, shift down}
        delay 1

        -- 輸入路徑
        keystroke "/path/to/file.mp3"
        keystroke return
        delay 1

        -- 點「打開」
        keystroke return
    end tell
end tell
```

## 與 agent-browser 的比較

| 功能 | agent-browser | safari-browser |
|------|--------------|----------------|
| 登入 | 每次重新登入 | 永遠登入 ✅ |
| JS 執行 | `eval` | `js` |
| Element discovery | `snapshot -i` → `@ref` | 不需要（直接寫 JS selector） |
| 檔案上傳 | `upload` (Playwright API) | System Events (檔案對話框) |
| 截圖 | `screenshot` (Playwright) | `screencapture` (macOS) |
| Headless | ✅ | ❌（Safari 一定有視窗） |
| 跨平台 | ✅ | ❌（macOS only） |
| 並行 | 多 session | 多 tab/window |
| 等待元素 | `wait` | JS polling |

## 依賴

- macOS（Sequoia 15+ 建議）
- Safari
- System Events accessibility 權限（System Preferences → Privacy → Accessibility）
- Swift 6.0+（編譯用）

## 開發順序

### Phase 1：核心 CLI
1. `open`, `js`, `get url/title/text/source`
2. `tabs`, `tab`, `close`
3. `wait`

### Phase 2：進階功能
4. `upload`（System Events）
5. `screenshot`（screencapture）
6. `--async` JS 執行

### Phase 3：Plugin 整合
7. Claude Code plugin 包裝
8. plaud-transcriber 遷移
9. safari-scraper skill 整合

## 實戰驗證的 Pattern

以下是 2026-03-21 實際成功的操作模式，可作為測試基準：

### Plaud 下載 SRT（API + JWT 方法）

```bash
# 1. 開新 tab 導航到檔案頁
safari-browser open "https://web.plaud.ai/file/{hash}" --new-tab

# 2. 取 JWT
TOKEN=$(safari-browser js "localStorage.getItem('tokenstr')")

# 3. 呼叫 API 取 signed URL
safari-browser js "
  fetch('https://api-apse1.plaud.ai/file/detail/{hash}', {
    headers: {'Authorization': localStorage.getItem('tokenstr')}
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    var contents = d.data.content_list;
    for (var i = 0; i < contents.length; i++) {
      if (contents[i].data_type === 'transaction') {
        window.__transLink = contents[i].data_link;
        break;
      }
    }
  });
" --wait 5

URL=$(safari-browser js "window.__transLink")

# 4. curl 下載 + 轉換
curl -sL "$URL" | gunzip > /tmp/transcript.json
python3 json_to_srt.py /tmp/transcript.json output.srt
```

### Plaud 上傳

```bash
# 1. 導航到首頁
safari-browser open "https://web.plaud.ai"

# 2. 點「新增音訊」→「匯入音訊」
safari-browser js "
  var links = document.querySelectorAll('a, button, [role=menuitem]');
  for (var i = 0; i < links.length; i++) {
    if (links[i].textContent.indexOf('新增音訊') !== -1) { links[i].click(); break; }
  }
"
sleep 1
safari-browser js "
  var items = document.querySelectorAll('[role=menuitem], button');
  for (var i = 0; i < items.length; i++) {
    if (items[i].textContent.indexOf('匯入音訊') !== -1) { items[i].click(); break; }
  }
"
sleep 1

# 3. 上傳檔案
safari-browser upload "input[type='file']" "/path/to/file.mp3"
sleep 25

# 4. 關閉 modal（導航離開）
safari-browser open "https://web.plaud.ai"
```
