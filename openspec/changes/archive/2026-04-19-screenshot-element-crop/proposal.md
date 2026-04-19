## Why

`safari-browser screenshot`（經 #29 後）可以裁掉 Safari chrome 輸出 web content viewport，但無法對準 DOM 裡某個**特定 element**（一張卡片、一個圖表、一段表格）擷取。批次做文件圖 / 教學截圖 / 與 `agent-browser` 的視覺 diff 時，使用者仍需手寫外部裁切工具，且丟失 `-l <windowID>` 的 z-order 保證（`screencapture -R` 會被遮擋其他視窗的內容汙染）。對應 issue #30；與 #31（img element 下載原始資源）並列，兩者皆從 #29 discussion 拆出。

## What Changes

- 新增 `--element <selector>` `@Option` 給 `screenshot`，接 CSS selector（light DOM，無 Shadow DOM 穿透）
- 新增 `--element-index <N>`（1-indexed）用於多 match 消歧義；預設 fail-closed
- 新增 `SafariBridge.getElementBoundsInViewport(selector:target:elementIndex:)` 封裝 JS eval + JSON parse + 4 個 fail-closed 邊界
- **允許所有 flag 組合**：`--element` × `--content-only` × `--full` 任一兩兩或三個同用都合法；語意皆收斂到「resize-then-measure-then-crop」
- 重用 #29 的 AX / CG / HiDPI infra：`getAXWebAreaBounds` / `getAXWindowBounds` / `ImageCropping.cropPNG / scale / pixelRect`；element 的 viewport-relative rect + AXWebArea origin → window-relative rect → pixel rect → crop
- `accessibilityRequired(flag:)` 重用但 `errorDescription` 依 flag 值客製 alternative 建議（`"--element"` 的替代方案是先 `--url` + 外部裁切）
- 新增 error cases：`elementNotFound` / `elementAmbiguous`（rich error：列 rect + attrs + text）/ `elementIndexOutOfRange` / `elementZeroSize` / `elementOutsideViewport` / `elementSelectorInvalid`
- 新測試 fixture `Tests/Fixtures/element-crop-test.html`（deterministic geometry，3 個 `.card` 測 ambiguous，1 個 hidden 測 zero-size，1 個超出 viewport 測 outside-viewport）

## Non-Goals (optional)

- **Shadow DOM 穿透**：只支援 light DOM 的 `querySelectorAll`，Shadow tree 內 element 無法定位（後續 issue）
- **Iframe 內 element**：`getBoundingClientRect` 只對頂層 document 有效，iframe 內 element 需 frame 遍歷（後續 issue）
- **`--scroll-into-view` 自動觸發**：element 超出 viewport 時 fail-closed 而非自動 scroll，避免動手腳改使用者頁面狀態（後續 issue）
- **`--element-contains <text>`**：text-anchored disambiguation，本 issue 先 index-based，文字錨點另起 issue
- **Canvas / SVG 內部 element**：Canvas 沒有可選擇的 DOM 子元素；SVG 內 element 的 `getBoundingClientRect` 行為正常但 nested transform 可能失準（先不保證）
- **Image element 下載原始資源**：已拆到 #31

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `screenshot`：新增 `--element <selector>` + `--element-index <N>` 的行為需求，以及與既有 `--content-only` / `--full` 的組合規則

## Impact

- Affected specs: `screenshot`（ADD 新 requirements）
- Affected code:
  - `Sources/SafariBrowser/Commands/ScreenshotCommand.swift`（新 `@Option` + element crop 路徑整合）
  - `Sources/SafariBrowser/SafariBridge.swift`（新 `getElementBoundsInViewport` JS-eval helper）
  - `Sources/SafariBrowser/Utilities/Errors.swift`（6 新 error cases + `accessibilityRequired(flag:)` 的 errorDescription 依 flag 客製 alternative）
  - `Tests/SafariBrowserTests/ElementCropTests.swift`（新檔，JSON parse + rect math 單元測試）
  - `Tests/SafariBrowserTests/ErrorsTests.swift`（新 error cases 的 errorDescription 測試）
  - `Tests/Fixtures/element-crop-test.html`（新 fixture，deterministic geometry）
- Affected dependencies: 無新外部依賴；使用既有 `doJavaScript` / AX / CoreGraphics / ImageCropping
- Affected workflows: 批次 card list 截圖、教學文件元件擷取、`agent-browser` 視覺 diff 流程不再需外部裁切
