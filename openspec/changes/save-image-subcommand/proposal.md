## Why

`safari-browser screenshot --element`（#30 後）可裁出 DOM 元素的像素截圖，但這是 **有損 raster** — 丟失原始 JPG / PNG / WebP 品質、無法取得動畫 GIF 原始檔、無法處理 inline SVG 向量、受 browser 縮放影響。批次擷取網頁素材（商品圖、教材插圖、認證資源）需要 **原始 bytes** 路徑。對應 issue #31，與 #30 成對作為 lossy raster / lossless original resource 配對。使用者在 #29 diagnosis 期間提出此需求後拆出獨立 issue。

## What Changes

- **新 subcommand** `safari-browser save-image <output>`，註冊到 `SafariBrowser.swift` 的 `subcommands:` 陣列
- **CLI surface**：`<output path>` argument + `TargetOptions` + `--element <selector>`（required）+ `--element-index <N>`（1-indexed disambiguator，mirror #30）+ `--track <src|currentSrc|poster>`（預設 `currentSrc`）+ `--with-cookies`（opt-in fetch bridge）
- **JS element resolver**：`SafariBridge.resolveElementResource(selector:target:track:elementIndex:) async throws -> ElementResource`，依 tagName 分類：
  - `<img>` / `<source>` / `<picture>`：`currentSrc || src`
  - `<video>` / `<audio>`：`currentSrc` 或 `--track poster` 取 `el.poster`
  - inline `<svg>`：serialize `outerHTML`
  - 其他 tag：throw `unsupportedElement`
- **Download pipeline**（依 URL scheme 分流）：
  - `http(s)`：URLSession 下載；header 預設帶 `Referer: <document.URL>` + 透過 `doJavaScript("navigator.userAgent")` 取得的 Safari UA；follow-redirect 時 cross-origin drop Referer
  - `data:`：Foundation 直接 parse 不經 URLSession
  - `--with-cookies` opt-in：透過 `doJavaScript` 執行 `fetch(url) → blob → FileReader.readAsDataURL` 取 base64，再用既有 `doJavaScriptLarge` 分片讀回 Swift 解碼；10 MB hard cap + 5 MB soft warn（沿用 #24 `upload --js` 安全限制）
  - 其他 scheme（`blob:` / `ftp:` / 未知）：throw `unsupportedURLScheme` fail-closed
- **Output path**：**完全信任使用者指定的路徑**，不做 Content-Type 推斷、不查 MIME 對照表、不加 `.bin` fallback、不 warn ext/MIME mismatch。靜默 overwrite（match `screenshot` 行為）。inline SVG 以 UTF-8 寫 `outerHTML` 字串到 user path。
- **新 error cases**（在 `Utilities/Errors.swift`）：
  - `elementHasNoSrc(selector: String, tagName: String)`
  - `unsupportedElement(selector: String, tagName: String)`
  - `downloadFailed(url: String, statusCode: Int?, reason: String)`
  - `downloadSizeCapExceeded(url: String, capBytes: Int, actualBytes: Int)`
  - `unsupportedURLScheme(url: String, scheme: String)`
- **Reuse #30 error cases**：`elementNotFound` / `elementAmbiguous` / `elementIndexOutOfRange` / `elementSelectorInvalid` 用同一套 fail-closed + rich ambiguous error pattern，保持 CLI UX 一致
- **新 test fixture** `Tests/Fixtures/save-image-test.html`：含 `<img src="...png">`、`<picture>` with `<source>`、`<video poster="...">`、inline `<svg>` 各一個 deterministic element，以及一個隱藏 img（`elementHasNoSrc` 測試）
- **新 capability spec** `openspec/specs/save-image/spec.md`（peer to `file-upload`，**不是** `screenshot` 的 extension）

## Non-Goals (optional)

- **CSS `background-image: url(...)`** — 需 `getComputedStyle` 解析，out of scope（未來 issue）
- **`canvas.toBlob()` export** — rasterize 非原始資源，語意屬 `screenshot --element` 範疇
- **Multi-element batch**（`save-images <output-dir> --selector ...`）— 本 issue 單 element；批次版需另外設計檔名 pattern 與 error aggregation
- **`<object>` / `<embed>` / `<iframe>`** 嵌入資源 — 後續 issue
- **Shadow DOM 穿透** — light DOM only（與 #30 一致）
- **Iframe 內 element** — `getBoundingClientRect` 不需但仍需切 iframe document，out of scope
- **Auto-extension 推斷** — 設計已明確拒絕；user 的 path 絕對
- **HTTP hard-block** — 允許 HTTP + stderr warn，不擋；intranet / archive workflow 需要
- **`--scroll-into-view`** — element 可見性與 save-image 無關（src 屬性不隨 viewport 變化）
- **`--no-referer` / `--no-user-agent`** — 未收到需求前不加 opt-out flag

## Capabilities

### New Capabilities

- `save-image`: Download an img / video / audio / picture / source element's raw resource URL to disk, or serialize an inline SVG element's outerHTML. Complements the lossy raster `screenshot --element` with a lossless original-bytes path. Supports cookie-bearing authenticated fetch via JS fetch + base64 bridge (10 MB capped).

### Modified Capabilities

(none)

## Impact

- Affected specs: `save-image`（new capability）
- Affected code:
  - `Sources/SafariBrowser/Commands/SaveImageCommand.swift`（**新檔**，估 250–350 LOC）
  - `Sources/SafariBrowser/SafariBrowser.swift`（subcommand registry）
  - `Sources/SafariBrowser/SafariBridge.swift`（新 `resolveElementResource` + `fetchResourceWithCookies` helpers，估 150–200 LOC）
  - `Sources/SafariBrowser/Utilities/Errors.swift`（+5 error cases）
  - `Tests/SafariBrowserTests/SaveImageTests.swift`（**新檔**：JS response parse、ElementResource enum、MIME/scheme 判定、base64 decode、URLSession mock-able bits）
  - `Tests/SafariBrowserTests/ErrorsTests.swift`（+5 error description 測試）
  - `Tests/Fixtures/save-image-test.html`（**新檔**）
- Affected dependencies: 無新外部依賴；使用既有 `Foundation.URLSession`、`CoreFoundation` data URL parsing、`doJavaScript` / `doJavaScriptLarge` / `resolveNativeTarget`
- Affected workflows: 批次 archive（BookWalker / 教材插圖 / 商品圖）不再需要兩步式 eval+curl；認證資源擷取（付費後台圖）透過 `--with-cookies` 一步到位
