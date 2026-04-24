## Context

#29 建立 AX-based screenshot infrastructure，#30 reuse 它加上 DOM 幾何層裁切特定 element。兩者都是 **raster pipeline**（AX + CoreGraphics + HiDPI）。#31 是第一條完全脫離這套基礎的能力 — **resource download pipeline**（JS + HTTP）。差別在於：

| 能力 | Pipeline | Privilege | Output |
|---|---|---|---|
| `screenshot` | AX → CGImage → PNG | Accessibility | Lossy raster |
| `screenshot --element` (#30) | AX + JS getBoundingClientRect → CGImage.cropping | Accessibility | Lossy raster, element-scoped |
| `save-image`（本 change） | JS querySelector → URL → URLSession bytes / `outerHTML` text | **None**（純 JS + HTTP） | Lossless original bytes |

關鍵既有元件（**不** reuse AX/CG）：

- `SafariBridge.doJavaScript(_:target:)` — 執行 JS 拿 string 結果
- `SafariBridge.doJavaScriptLarge(_:target:)` — chunked read 256 KB（`SafariBridge.swift:470-510`）用於大 base64 回傳
- `SafariBridge.resolveNativeTarget(from:)` — target options → window index
- `TargetOptions` — `--url / --window / --tab / --document`
- `UploadCommand` 的 `jsHardCapBytes = 10 MB` + Array.push chunking pattern（`UploadCommand.swift:40-90, 333-356`）— #24 教訓的對應實作，本 change 以**逆向 chunked read** 方式 reuse

Discuss 階段對齊了 5 個核心決策，本文件記錄 decision + rationale + alternatives。

## Goals / Non-Goals

**Goals:**

- 提供原始 bytes 下載路徑補齊 #30 lossy raster 缺口
- 不依賴 Accessibility，與 #29/#30 的權限模型分離
- 支援 cookie-bearing 認證資源擷取（`--with-cookies`）但限制大小避免 V8 OOM
- 保持 CLI 與 #30 語意一致（`--element` + `--element-index` 同 fail-closed pattern）
- 極致簡化 output path 決策（使用者絕對主權）
- Fail-closed 覆蓋所有不支援情境（blob: / ftp: / unsupported tag / size cap / HTTP errors）

**Non-Goals:**

- CSS `background-image` 解析（未來 issue）
- `canvas.toBlob()` export（屬 rasterize 語意，不是原始資源）
- Multi-element batch（檔名 pattern 需獨立設計）
- `<object>` / `<embed>` / `<iframe>` 嵌入資源
- Shadow DOM 穿透
- Iframe 內 element 下載
- 自動 MIME → extension 推斷（使用者絕對主權）
- HTTP hard-block（僅 stderr warn，支援 intranet）
- 自動 scroll-into-view（src 不隨可見性變化，不需要）

## Decisions

### CLI surface: `--element` required, multi-match mirrors #30

**Decision**:
- `--element <selector>` **required**；`validate()` 在 `element == nil` 時 throw `ValidationError`
- `--element-index <N>` 1-indexed（`validate()` 要求 `N >= 1` 且同 #30 要求 `--element`）
- Multi-match 行為完全 mirror #30：預設 fail-closed 拋 `elementAmbiguous(selector:matches:)` rich error；使用者看完列表選 `--element-index N` 顯式消歧義；unique match + `--element-index 1` 合法作為 assertion
- `--track <src|currentSrc|poster>`：預設 `currentSrc`；對 `<img>` / `<source>` 忽略 `poster`；對 `<video>` / `<audio>` 支援 `poster`（取 `el.poster`）
- `--with-cookies` opt-in flag

**Rationale**:
- `save-image` 本質 element-scoped，沒有合理 whole-page default（不像 `screenshot` 無 flag 時可截整窗）
- #30 已建立 `--element` + `--element-index` + rich ambiguous error 的 CLI 慣例；divergence 會增加使用者認知負擔
- `--track` 預設 `currentSrc` 因為那是 responsive image 實際載入的 URL；使用者偶爾想要原始 `src` 屬性（例如繞過 srcset）或 `poster`（抓 video cover）

**Alternative considered**:
- `--element` optional with whole-page default (fetch page's og:image / first img) — 過度 magical，拒絕
- `--first-match` 靜默第一個 — 同 #30 理由拒絕（silent-wrong trap）

### URL request: Referer + Safari UA, drop on cross-origin redirect

**Decision**: URLSession 請求默認設定：

- `Referer: <document.URL>` — 透過 `doJavaScript("document.URL")` 取得；在發出請求前設定
- `User-Agent: <Safari UA>` — 透過 `doJavaScript("navigator.userAgent")` 取得；每次 invocation 取一次（非 per-chunk）
- `URLSessionTaskDelegate` handle redirect：若 redirect cross-origin，**drop Referer**；若同 origin，保留
- 預設 follow redirect

**Rationale**:
- CDN（Cloudflare / BunnyCDN / BookWalker CDN 實測）常以 Referer 或 UA 白名單判 403；不帶 header 無法服務
- Drop Referer on cross-origin redirect 符合現代瀏覽器 `strict-origin-when-cross-origin` 預設行為；避免 document URL 外流到第三方
- 在 download 命令使用者已明確授權情境下，functional default 優於 default-safer-for-privacy

**Alternative considered**:
- 無 header — CDN 403 率高，fail early 無法用工具下載
- `--no-referer` opt-out 現在就加 — YAGNI；等使用者反饋再加

### `--with-cookies`: fetch bridge + 10 MB cap + chunked read via `doJavaScriptLarge`

**Decision**: 當 `--with-cookies` 啟用：

```
JS 端（透過 doJavaScript）：
  const r = await fetch(url);
  const blob = await r.blob();
  const reader = new FileReader();
  reader.readAsDataURL(blob);
  // onloadend → window.__sbResource = reader.result (data URL with base64);
  // window.__sbResourceLen = length;

Swift 端：
  doJavaScriptLarge 觸發 chunked read → 拿到完整 data URL
  parse "data:<mime>;base64,<payload>"
  Data(base64Encoded: payload) → 寫檔
```

**Size safeguards**（對齊 `UploadCommand` 的 #24 教訓）：

- 5 MB soft warn：stderr `"Resource exceeds 5 MB via --with-cookies; JS bridge overhead may be significant"`
- 10 MB hard cap：throw `downloadSizeCapExceeded` 並建議使用 default URLSession path（若無 auth 需求）
- Size check 在 `FileReader` 完成後、chunked read 前執行（從 `__sbResourceLen` 讀）

**Rationale**:
- `doJavaScriptLarge` 已在 SafariBridge 存在（`:470-510`），inverse of upload's chunked **write**；直接 reuse 無新 infrastructure
- 10 MB cap 與 `upload --js` 對稱 — 同一 V8 base64 bridge 風險模型，#24 實測大檔會 OOM
- `FileReader.readAsDataURL` 輸出已是 `data:` URL 形式，Swift 端只需 split-once 拿 base64 payload

**Alternative considered**:
- 無 size cap — 重演 #24 131 MB 導致 Safari 83 GB transient string allocation 的 incident，拒絕
- 用 WKWebView 的 cookie store bridge — 更複雜且需要更多權限，目前 JS fetch + base64 已足夠

### Output path: pure bytes-to-path, zero MIME inference

**Decision**: 使用者給的 `<output>` path **絕對信任**：

- Path 有 extension（`out.jpg`）→ 寫到 `out.jpg`
- Path 無 extension（`out`）→ 寫到 `out` literal（無 extension）
- 不查 Content-Type response header
- 不查 URL path extension
- 不查 MIME → extension 對照表
- 不加 `.bin` fallback
- 不 warn on ext/MIME mismatch
- Overwrite silent（match `screenshot` 行為）

**Inline SVG** path：serialize `outerHTML` 為 UTF-8 字串寫到 user path（無論 user path 是 `.svg` / `.xml` / `out`）。

**`data:` URL** path：Foundation 自行 decode（`data:<mime>;base64,<payload>` split-on-comma-once，base64 decode payload，寫檔）。跳過 URLSession（URLSession 不支援 `data:` scheme）。

**Rationale**:
- YAGNI — MIME 推斷表會 rot（新 WebP / AVIF / HEIC 需追加）
- 使用者主權（curl `-o` convention）— 呼叫者知道自己下游 pipeline 需要的 extension
- 移除 MIME/ext 衝突處理 + 多路決策，code path 變單一
- Inline SVG 是 text，直接 UTF-8 write；URL 是 bytes，直接 raw write — 沒有中間判斷

**Alternative considered**:
- 從 Content-Type 自動補 extension（3-step chain `user ext > server MIME > .bin`）— 複雜、維護負擔大、會 surprise scripts，拒絕
- 強制要求 user 提供 extension — paternalistic，拒絕

### URL scheme policy: http(s) + data: supported, others fail-closed

**Decision**:

- `http://`：允許 + stderr warn `"Downloading over http:// — contents traverse cleartext"`（不擋）
- `https://`：默認，無 warn
- `data:`：Foundation 自行 decode，不經 URLSession
- **其他 scheme**（`blob:` / `ftp:` / `javascript:` / `file:` / 未知）：throw `unsupportedURLScheme(url:, scheme:)`

**Overwrite**：目的 path 已存在時 silent overwrite（match `screenshot` 行為），不 prompt、不加 `--force`。

**Rationale**:
- HTTP intranet / archive 工作流常見；hard-block 造成不必要障礙
- `blob:` 是 JS 端 URL.createObjectURL() 產生的臨時引用，在 subprocess 呼叫的 osascript 端無法解析 → fail-closed 比嘗試錯誤解碼好
- `file:` 拒絕因為 save-image 是下載場景，本地檔案應用 cp / mv
- Overwrite silent 是 CLI 工具標準（screenshot / pdf / upload 都這樣）

**Alternative considered**:
- HTTP hard-block — 排除 intranet 工作流，拒絕
- `--force` flag 控制 overwrite — CLI 既有命令沒有此 flag，新增破壞一致性

## Risks / Trade-offs

1. **Cross-origin 403 仍可能**：即使帶 Referer + Safari UA，某些 CDN 額外檢查 `Sec-Fetch-Site` / `Origin` / HMAC-signed URL (AWS S3 pre-signed)。**Mitigation**：`downloadFailed` error 訊息引導使用者改走 `--with-cookies`（走 Safari 自身 fetch 完全 browser-equivalent）

2. **`--with-cookies` chunked base64 performance**：大檔（接近 10 MB）走 JS bridge 比 URLSession 慢 10–100 倍。**Mitigation**：5 MB soft warn 讓使用者知道；10 MB hard cap 避免 worst case；文件註明 `--with-cookies` 適用中小檔（< 5 MB）

3. **Redirect chain Referer drop 邊界**：`HTTP → HTTPS` 同 host 是 cross-origin 嗎？技術上 origin = scheme+host+port，port 不同視為 cross-origin。**Mitigation**：照 browser Origin 定義實作；若 user 抱怨，提供 `--keep-referer` opt-out（未收到前不加）

4. **Animated GIF 在某些 `<img>` 裡其實是 `<video>` 模擬**：`currentSrc` 會是 `.mp4` 而非 `.gif`；使用者期望 GIF 但拿到 MP4。**Mitigation**：error-prone 的語意 mismatch 不在 save-image 責任範圍；文件提醒；使用者若要 GIF 語意應明確檢查 tag

5. **`<video poster>` 可能是 data URL**（base64 inline）：data URL decode 已處理，不需特殊對待

6. **JS selector escape**：特殊字元 injection 風險。**Mitigation**：reuse #30 的 `JSONSerialization` 包裝模式（`SafariBridge.swift:498`）

7. **`data:` URL 極端長**（幾 MB 的 inline base64 img）：超過 `doJavaScript` 的 osascript argv 長度限制。**Mitigation**：取 `src` 屬性時若偵測 `data:` 長度 > 256 KB 走 `doJavaScriptLarge`；小 data URL 直接走正常 bridge

8. **Inline SVG 的 `outerHTML` 含外部 CSS class 但 CSS 未 inline**：寫出的 SVG 檔開起來樣式壞掉。**Mitigation**：Non-Goals 明列；未來 issue 考慮 `--inline-styles` flag

9. **File overwrite 破壞資料**：使用者若 typo 路徑到重要檔案會被覆寫。**Mitigation**：與 `screenshot` 一致的行為，使用者已知 CLI 預設 overwrite；未來可加 `--no-clobber`（未收到需求前不加）

10. **Element 出 viewport 不影響 save-image**：`src` 屬性 / `outerHTML` 不隨可見性變化，不需 scroll-into-view；這是本 feature 與 #30 的關鍵差別之一
