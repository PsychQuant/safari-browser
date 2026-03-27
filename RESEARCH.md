# safari-browser — 研究筆記

## Safari AppleScript SDEF（完整指令清單）

來源：`sdef /Applications/Safari.app`，2026-03-21 擷取。

### Commands

| Command | 說明 |
|---------|------|
| `do JavaScript` | 在 tab 中執行 JS，回傳字串結果 |
| `open location` | 開啟 URL |
| `add reading list item` | 加入閱讀清單 |
| `email contents` | 用 Mail 寄送 tab 內容 |
| `search the web` | 用 Safari 搜尋引擎搜尋 |
| `show bookmarks` | 開書籤 |
| `dispatch message to extension` | 跟 Safari Extension 通訊 |
| `sync all plist to disk` | 同步記憶體狀態到磁碟 |

### Tab Properties

| Property | Type | 說明 |
|----------|------|------|
| `source` | text | 頁面完整 HTML 原始碼 |
| `URL` | text | 當前 URL |
| `text` | text | 頁面純文字 |
| `name` | text | Tab 標題 |
| `visible` | boolean | 是否可見 |
| `index` | number | Tab 位置（左到右） |
| `pid` | number | WebContent process PID |

### Window Properties

- `name`, `bounds`, `document`
- `current tab` — 可讀寫，用於切換 tab

## do JavaScript 的限制

1. **回傳值必須是字串** — 如果 JS 回傳 object/array，需要 `JSON.stringify()`
2. **回傳值大小限制** — 實測約 1MB，超過會截斷或出錯
3. **同步執行** — AppleScript 會等 JS 執行完才回傳。如果 JS 是 async（fetch），需要用 window 變數暫存結果，再分開取
4. **無 Promise 支援** — `do JavaScript "fetch(...).then(...)"` 會立即回傳 Promise 物件的字串表示，不會等結果
5. **頁面導航後 JS context 重置** — 跟 agent-browser 一樣

## System Events 檔案上傳

### 前提

- System Preferences → Privacy & Security → Accessibility → 允許 Terminal / Claude Code
- Safari 的檔案對話框是標準 macOS sheet

### 已知問題

1. **檔案對話框可能有延遲** — 需要 `repeat until exists sheet 1` 等待
2. **Cmd+Shift+G 可能被系統快捷鍵攔截** — 極少見但可能
3. **路徑中有空格** — 需要測試 keystroke 是否正確處理
4. **多檔案上傳** — 檔案對話框支援多選，但 keystroke 只能輸入一個路徑。多檔案需要逐個上傳

## screencapture 截圖

```bash
# 截取特定視窗（需要 window ID）
screencapture -l <windowID> output.png

# 取得 Safari window ID
osascript -e 'tell application "System Events" to get id of first window of process "Safari"'
# 或用 CGWindowListCopyWindowInfo（Swift 更容易）
```

## 與 Plaud 相關的發現

### Performance API 不再可靠（2026-03-21）

Plaud 改版後，`trans_result.json.gz` 不再出現在 `performance.getEntriesByType('resource')` 中。

### 新的下載方法：API + JWT

```
1. JWT 存在 localStorage.getItem("tokenstr")
   格式：bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

2. API: GET https://api-apse1.plaud.ai/file/detail/{file_hash}
   Headers: { Authorization: <tokenstr> }

3. Response 結構：
   {
     "data": {
       "file_id": "...",
       "file_name": "...",
       "content_list": [
         {
           "data_type": "transaction",   // ← 這是逐字稿
           "task_status": 1,             // 1 = 完成
           "data_link": "https://...s3.amazonaws.com/.../trans_result.json.gz?..." // signed URL
         },
         {
           "data_type": "outline",       // 大綱
           ...
         },
         {
           "data_type": "auto_sum_note", // AI 摘要
           ...
         }
       ]
     }
   }

4. data_link 是 signed S3 URL，可直接 curl 下載
```

### Plaud 登入機制

- 登入頁：`https://web.plaud.ai/login`
- 未登入時自動重導向：`https://web.plaud.ai/login?from_url=/`
- JWT 存在 localStorage `tokenstr`，格式 `bearer eyJ...`
- Session cookie 不足以維持登入（agent-browser 的 `state save/load` 失敗的原因）
- **Safari 的 localStorage 跨 session 保留** — 這就是 Safari 方案能一勞永逸的根本原因

## 競品比較

### agent-browser (Vercel)
- Playwright/Chromium 底層
- 強在 headless、CI、跨平台
- 弱在 session 持久化

### browser-use
- Python AI agent 框架
- 支援 `Browser.from_system_chrome(profile_directory=...)` 使用既有 Chrome profile
- 但需要 LLM API 來決定每步操作，不適合固定步驟自動化

### safari-browser（我們要做的）
- macOS 原生 Safari + AppleScript
- 強在永久登入、零設定、原生整合
- 弱在 macOS only、非 headless

## 參考資源

- Safari AppleScript: `sdef /Applications/Safari.app`
- System Events: `sdef /System/Library/CoreServices/System\ Events.app`
- screencapture: `man screencapture`
- ScriptingBridge (Swift): https://developer.apple.com/documentation/scriptingbridge
