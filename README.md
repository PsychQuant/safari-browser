# safari-browser

macOS 原生瀏覽器自動化 CLI，透過 Safari + AppleScript 控制瀏覽器。

**核心優勢：永遠登入** — 直接使用 Safari 現有的 session（localStorage、cookies 永久保留），不需要任何 auth 管理。

## 安裝

```bash
git clone git@github.com:PsychQuant/safari-browser.git
cd safari-browser
make install
```

Binary 安裝到 `~/bin/safari-browser`。確認 `~/bin` 在 `$PATH` 中。

### 系統需求

- macOS Sequoia 15+
- Safari
- Swift 6.0+
- Accessibility 權限（System Events 操作需要，截圖和上傳時）

## 指令總覽

### 導航

```bash
safari-browser open <url>              # 開啟 URL
safari-browser open <url> --new-tab    # 開新 tab
safari-browser open <url> --new-window # 開新視窗
safari-browser back                    # 上一頁
safari-browser forward                 # 下一頁
safari-browser reload                  # 重新載入
safari-browser close                   # 關閉當前 tab
```

### 元素發現（Snapshot + @ref）

```bash
safari-browser snapshot                # 掃描互動元素，分配 @e1, @e2...
safari-browser snapshot -s "form"      # 限定範圍
safari-browser snapshot -c             # compact（排除隱藏元素）
safari-browser snapshot -d 3           # 限制 DOM 深度
safari-browser snapshot --json         # JSON 輸出
safari-browser click @e3               # 用 @ref 點擊
safari-browser fill @e1 "text"         # 用 @ref 填入
```

所有接受 selector 的指令都支援 `@eN` ref 格式。

### JavaScript

```bash
safari-browser js "<code>"             # 執行 JS
safari-browser js --file script.js     # 從檔案執行
```

### 頁面資訊

```bash
safari-browser get url                 # 當前 URL
safari-browser get title               # 頁面標題
safari-browser get text [selector]     # 頁面/元素純文字
safari-browser get source              # HTML 原始碼
safari-browser get html <selector>     # 元素 innerHTML
safari-browser get value <selector>    # input 值
safari-browser get attr <sel> <name>   # 元素屬性
safari-browser get count <selector>    # 元素數量
safari-browser get box <selector>      # 元素 bounding box (JSON)
```

### 元素互動

```bash
safari-browser click <selector>        # 點擊
safari-browser dblclick <selector>     # 雙擊
safari-browser fill <sel> <text>       # 清空+填入
safari-browser type <sel> <text>       # 追加文字
safari-browser select <sel> <value>    # 下拉選單
safari-browser hover <selector>        # hover
safari-browser focus <selector>        # 聚焦
safari-browser check <selector>        # 勾選 checkbox
safari-browser uncheck <selector>      # 取消勾選
safari-browser scroll <dir> [px]       # 捲動 (up/down/left/right)
safari-browser scrollintoview <sel>    # 捲動到可見
safari-browser highlight <selector>    # 高亮顯示（紅框）
safari-browser drag <src> <dst>        # 拖放（JS drag events）
```

### 鍵盤

```bash
safari-browser press Enter             # 按鍵
safari-browser press Tab               # Tab
safari-browser press Escape            # Escape
safari-browser press Control+a         # 修飾鍵組合
safari-browser press Shift+Tab         # Shift+Tab
```

### 搜尋元素

```bash
safari-browser find text "Submit" click           # 按文字找+點擊
safari-browser find role "button" click            # 按 ARIA role 找
safari-browser find label "Email" fill "a@b.com"   # 按 label 找+填入
safari-browser find placeholder "Search" fill "q"  # 按 placeholder 找
```

### 狀態檢查

```bash
safari-browser is visible <selector>   # 是否可見
safari-browser is exists <selector>    # 是否存在
safari-browser is enabled <selector>   # 是否 enabled
safari-browser is checked <selector>   # 是否已勾選
```

### 截圖、PDF 與上傳

```bash
safari-browser screenshot [path]       # 視窗截圖
safari-browser screenshot --full path  # 全頁截圖
safari-browser pdf [path]              # Export as PDF
safari-browser upload <sel> <file>     # 檔案上傳
```

### Tab 管理

```bash
safari-browser tabs                    # 列出所有 tab
safari-browser tabs --json             # JSON 輸出
safari-browser tabs                    # 列出所有 tab
safari-browser tab <n>                 # 切換到第 n 個 tab
safari-browser tab new                 # 開新 tab
```

### 等待

```bash
safari-browser wait <ms>               # 等待毫秒
safari-browser wait --url <pattern>    # 等 URL 匹配
safari-browser wait --js <expr>        # 等 JS 為 truthy
safari-browser wait --timeout 5000     # 自訂 timeout
```

### Storage

```bash
safari-browser cookies get [name]      # 取得 cookies
safari-browser cookies get --json      # JSON 格式
safari-browser cookies set <n> <v>     # 設定 cookie
safari-browser cookies clear           # 清除 cookies
safari-browser storage local get <key> # localStorage
safari-browser storage local set <k> <v>
safari-browser storage local remove <key>
safari-browser storage local clear
safari-browser storage session get/set/remove/clear  # sessionStorage
```

### Debug

```bash
safari-browser console --start         # 開始攔截 console (log/warn/error/info/debug)
safari-browser console                 # 讀取攔截到的訊息（含 [warn]/[error] 等前綴）
safari-browser console --clear         # 清空
safari-browser errors --start          # 攔截 JS 錯誤
safari-browser errors                  # 讀取錯誤
safari-browser mouse move <x> <y>      # 滑鼠移動
safari-browser mouse down / up         # 滑鼠按下/放開
safari-browser mouse wheel <dy>        # 滾輪
```

### 設定

```bash
safari-browser set media dark          # 強制 dark mode
safari-browser set media light         # 強制 light mode
```

## 為什麼選 safari-browser

### 核心優勢

**零設定登入** — 使用者的 Safari session 直接可用。localStorage、cookies、SSO session 永久保留。不需要 cookie injection、不需要每次重新登入、不需要管理 auth token。對企業 SaaS、銀行、社群平台等需要登入的網站，這是唯一可靠的自動化方式。

**使用者同時操作** — agent-browser 開的是獨立 Chromium 實例，使用者看不到也碰不了。safari-browser 操作的是使用者自己的 Safari，AI 操作時使用者可以即時觀看、隨時介入、直接接手。這讓 human-in-the-loop 工作流成為可能。

**macOS 生態整合** — Safari 的 localStorage、Keychain 整合、iCloud cookies 同步、Safari Extension 狀態全部直接可用。這不是功能差距可以彌補的，而是根本的架構差異。

**反 bot 偵測免疫** — 許多網站（Facebook、Instagram、銀行）積極封鎖 headless Chromium。safari-browser 使用的是真正的 Safari 瀏覽器，與使用者手動瀏覽完全相同，不會觸發任何 bot 偵測。

### 適用場景

| 場景 | 為什麼只有 safari-browser 能做 |
|------|------|
| 企業 SaaS 自動化（Notion、Slack web、JIRA） | 永久登入 + SSO session 保持 |
| 金融操作（銀行轉帳、報稅系統） | 不可能在 headless Chromium 做，銀行會封鎖 |
| 社群管理（Facebook、Instagram、X 後台） | 這些平台積極偵測並封鎖 headless 瀏覽器 |
| AI + 人類協作 | 使用者隨時看到 AI 在做什麼、隨時接手 |
| 讀取已登入網站的 API token | `js "localStorage.getItem('token')"` 直接取 |
| 需要 2FA / MFA 的網站 | 使用者已經在 Safari 完成驗證，session 直接可用 |

### 與 agent-browser 的完整比較

| 功能 | agent-browser | safari-browser |
|------|--------------|----------------|
| **登入狀態** | 每次重新登入 | **永遠登入** ✅ |
| **使用者可見** | 獨立 Chromium，使用者看不到 | **使用者的 Safari** ✅ |
| **反 bot 偵測** | 容易被偵測為 headless | **真正的瀏覽器** ✅ |
| **2FA / SSO** | 需要每次處理 | **session 直接可用** ✅ |
| **macOS 整合** | 無 | **Keychain、iCloud、Extension** ✅ |
| 底層 | Playwright / Chromium | Safari + AppleScript |
| Headless | ✅ | ❌（不需要） |
| 跨平台 | ✅ Linux / Windows | macOS only |
| Network 攔截 | ✅ route / unroute | ❌ |
| Accessibility tree | ✅ CDP 原生 | JS DOM 掃描（90% 夠用） |
| 並行 session | ✅ 多個隔離實例 | 共用 Safari（多 tab） |
| 適合場景 | CI、公開網站、headless 測試 | **需登入的網站、macOS 本地自動化、AI 協作** |

### 選擇指南

```
需要登入？ ──── 是 → safari-browser
              └── 否 → 需要 headless/CI？ ──── 是 → agent-browser
                                           └── 否 → 都可以（safari-browser 更輕量）
```

## 開發

```bash
make build    # 編譯 (debug)
make install  # 編譯 + 安裝到 ~/bin
make clean    # 清除 build artifacts
```
