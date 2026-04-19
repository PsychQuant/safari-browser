## Context

#29 已把 AX-first screenshot 的基礎架構建起來：`resolveWindowForCapture` + `getAXWebAreaBounds` + `ImageCropping.{cropPNG, scale, pixelRect, isNoOpCrop}` + `accessibilityRequired(flag:)` error pattern。#30 的 element-scoped crop 大量 reuse 這套 infra，只在三處加新 surface：

1. **JS eval** 讀 DOM element 的 `getBoundingClientRect`（AX 拿不到 DOM-level 幾何）
2. **座標轉換**：element viewport-rect → window-rect →  pixel-rect
3. **多 match disambiguation**：rich ambiguous error + `--element-index N`

關鍵既有元件（都是 #29 產出）：

- `Sources/SafariBrowser/SafariBridge.swift`：`doJavaScript(_:target:)`、`getAXWebAreaBounds(_:)`、`getAXWindowBounds(_:)`、`resolveWindowForCapture(window:)`
- `Sources/SafariBrowser/Utilities/ImageCropping.swift`：`cropPNG / scale / pixelRect / isNoOpCrop`
- `Sources/SafariBrowser/Utilities/Errors.swift`：`accessibilityRequired(flag:)` pattern（可 multi-flag reuse）
- `openspec/specs/screenshot/spec.md`：9 條既有 requirements（4 原 + #29 5 新）

Discuss（#30 diagnosis 後）已對齊 5 個關鍵決策，本文件記錄 decision + alternatives。

## Goals / Non-Goals

**Goals:**

- 提供 `--element <selector>` 能以 CSS selector 裁出頁面上特定元件
- 多 match 時 fail-closed 預設 + rich ambiguous error + `--element-index N` 作為顯式消歧義路徑
- 允許所有 flag 組合（`--element` × `--content-only` × `--full`）；每個 combo 皆有清楚語意
- 極大化 reuse #29 infra；不新增 AX / CG / HiDPI 相關抽象

**Non-Goals:**

- Shadow DOM 穿透（light DOM only）
- Iframe 內 element 定位
- `--scroll-into-view` 自動觸發（element 出 viewport → fail-closed）
- `--element-contains <text>` text-anchored disambiguation（後續 issue）
- Image element 原始資源下載（拆到 #31）

## Decisions

### Flag combos: allow all, resize-then-measure-then-crop

**Decision**: `--element` × `--content-only` × `--full` 全部可合法組合。實作上 element 測量永遠發生在 resize（若有 --full）之後，crop 流程是一個 unified pipeline：

```
1. resolve target + AX check
2. (if --full) resize window to scrollable dims + settle
3. capture window PNG via screencapture -l <windowID>
4. measure:
   a. (if --full) 使用 caller-provided post-resize windowBounds (避開 #29 發現的 AX race)
   b. getAXWebAreaBounds(axWindow)  — 窗內 web content 區域
   c. (if --element) getElementBoundsInViewport(selector, target, elementIndex)
5. 依 flag 組合選 crop rect:
   - --element: element rect in viewport + AXWebArea origin → window rect
   - --content-only 無 --element: AXWebArea rect (已是 window-rel)
   - neither: skip crop
6. isNoOpCrop(windowBounds, cropRect) → if true, write capture unchanged
7. ImageCropping.cropPNG(path, cropRect, windowWidthPoints)
8. (if --full) restore window bounds
```

**Rationale**:

- `--element` 本身已隱含「只要 element 範圍」，`--content-only` combo 只是 explicit intent（沒額外成本）
- `--element --full` 是殺手級 combo：long-page（教學文、商品 list）的下半截 card 一步到位擷取
- 拒絕 combo 的 paternalism 成本 > 接受的複雜度成本

**Alternative considered**:

- `--element --full` reject as mutually exclusive — 擋掉真正有用的 workflow，把使用者推向外部工具
- `--element --content-only` reject as redundant — 語意上無害，redundancy 不等於 bug

### JS helper placement: `SafariBridge.getElementBoundsInViewport`

**Decision**: 在 `SafariBridge.swift` 加：

```swift
static func getElementBoundsInViewport(
    selector: String,
    target: TargetDocument,
    elementIndex: Int? = nil
) async throws -> ElementBoundsResult

struct ElementBoundsResult {
    let rectInViewport: CGRect      // viewport-relative points
    let viewportSize: CGSize         // window.innerWidth/Height
    let matchCount: Int              // for error context
    let attributes: String           // "tag.class#id" snippet
    let textSnippet: String?         // first 60 chars, trimmed
}
```

封裝 JS eval + JSON parse + 把 JS 端 `error` 欄位轉成特定 `SafariBrowserError` case（`elementNotFound` / `elementAmbiguous` / `elementIndexOutOfRange` / `elementZeroSize` / `elementOutsideViewport` / `elementSelectorInvalid`）。Rich ambiguous error 會回傳所有 match 的 rect + attrs + text，這裡一併 parse。

**Rationale**:

- `SafariBridge` 既有 `getAX*Bounds` / `doJavaScript*` pattern — primitive getters 集中在 Bridge，Command 保持 orchestration role
- `getElementBoundsInViewport` 未來可被 `wait --element-visible` / `highlight --element` / agent-browser integration 等 reuse
- Inline 在 ScreenshotCommand 會讓該檔同時處理 AX + JS + CG + Argument Parser 四層抽象，違反 #26 之後的 Bridge-as-gateway 慣例

**Alternative considered**: inline in ScreenshotCommand — premature abstraction 風險，但違反既有架構 pattern；若未來真無第二 caller 再 inline 回去即可。

### Multi-match disambiguation: fail-closed + `--element-index N` + rich error

**Decision**: Multi-match 預設 fail-closed。提供兩個 disambiguation 路徑：

1. **`--element-index N`**（1-indexed among matches in document order） — 顯式選擇第 N 個
2. **Rich ambiguous error** — 列出每個 match 的 rect + attrs + text snippet，使用者看完可選擇：
   - 改 selector（`.card:nth-of-type(2)`、加 class / id）
   - 加 `--element-index N`

**Unique-match 時使用者誤加 `--element-index 1`**: 合法 — 視為 assertion「我期待 1 個 match」，script 的顯式意圖。
**`--element-index` 超出 match count**: throw `elementIndexOutOfRange(selector:, index:, matchCount:)`。

**Rich ambiguous error format**:

```
Multiple elements match ".card":
  [1] rect={x:50, y:100, w:300, h:200}     class="card featured"    text="Launch Sale"
  [2] rect={x:50, y:320, w:300, h:200}     class="card"             text="Summer Deal"
  [3] rect={x:50, y:540, w:300, h:200}     class="card"             text="Free Shipping"
Disambiguate by either:
  1. Refine selector: e.g. ".card.featured" or ".card:nth-of-type(2)"
  2. Add --element-index 2 to pick the second match (document order)
```

**Rationale**:

- `--first-match` 是 silent-wrong trap（頁面變動後靜默錯）；`--element-index` 讓意圖留在 code，count 變化時 **explicit out-of-range error**
- Rich error 給足 context，使用者第一次就能決定改 selector 還是加 index（不用反覆 trial-and-error）
- 與 #28 既有 `--window M --tab-in-window N` composite 消歧義 pattern 一致

**Alternative considered**:

- `--first-match`（既有 `--url` 用過）— 同類問題（silent first-match），僅擴大 footgun；`--element-index` 較嚴格但同樣簡單
- `--element-contains <text>` text-anchor — 很人性化但 scope 大，先留 future issue

### Error cases: reuse `accessibilityRequired(flag:)` with customized alternative

**Decision**: 沿用 `SafariBrowserError.accessibilityRequired(flag: String)`，`errorDescription` 依 `flag` 值客製 alternative 建議：

| flag 值 | Alternative message |
|---|---|
| `"--content-only"` | Re-run without `--content-only` — get chrome-included screenshot, crop externally |
| `"--element"` | Re-run with explicit `--window N` / `--url <pattern>` to capture the whole window, then crop externally with ImageMagick / `sips` to the element's bounding box |

不新增 `accessibilityRequiredForElement`  etc. 新 case。

**新增 6 個 error cases**：

- `elementNotFound(selector: String)` — `querySelectorAll.length == 0`
- `elementAmbiguous(selector: String, matches: [(rect: CGRect, attrs: String, textSnippet: String?)])` — length > 1 且無 `--element-index`
- `elementIndexOutOfRange(selector: String, index: Int, matchCount: Int)` — `--element-index` > matches
- `elementZeroSize(selector: String)` — `getBoundingClientRect` width/height ≤ 0
- `elementOutsideViewport(selector: String, rect: CGRect, viewport: CGSize)` — 部分或全部超出 `window.innerWidth/Height`
- `elementSelectorInvalid(selector: String, reason: String)` — JS `SyntaxError`

**Rationale**:

- `accessibilityRequired` 單一 case 已為 multi-flag 設計（`flag: String` 參數）；開新 case 等於複製 80% 訊息 body
- 6 新 error cases 對應 6 個精確 fail-closed 邊界；每個都有獨立 recovery hint

**Alternative considered**: 單一 `elementError(reason: String)` generic — 錯誤訊息可客製，但 caller 無法 programmatic 區分 which failure（testing 難寫），違反既有 exhaustive enum pattern。

### Test fixture: new `Tests/Fixtures/element-crop-test.html`

**Decision**: 新建 fixture，不擴充既有 `test-page.html`。

內容（deterministic geometry）：

```html
<div id="target" style="position:absolute; left:50px; top:100px; width:200px; height:150px;
                         background:#4a90e2;">Target</div>
<div class="card" style="position:absolute; left:50px; top:300px; width:300px; height:200px;">Card 1</div>
<div class="card" style="position:absolute; left:50px; top:520px; width:300px; height:200px;">Card 2</div>
<div class="card" style="position:absolute; left:50px; top:740px; width:300px; height:200px;">Card 3</div>
<div id="hidden-el" style="display:none;">Hidden</div>
<div id="below-fold" style="position:absolute; top:5000px; width:100px; height:100px;">Far Below</div>
```

**Rationale**:

- `test-page.html` 是 form-interaction fixture（input / checkbox / select），native rendering 跨版本 geometry 有 drift — 不適合 pixel-exact 裁切測試
- Absolute positioning + fixed pixel size 保證 test 跨機器 / 跨 Safari 版本一致
- 一個 fixture 覆蓋 5 個 error case（`#target` 單 match，`.card` 多 match，`#hidden-el` zero-size，`#below-fold` outside-viewport，`#nonexistent` not-found）

**Alternative considered**: 擴充 `test-page.html` — 讓單一 fixture 變成 kitchen sink，form inputs + geometry 元件混在一起破壞 single-purpose 原則。

## Risks / Trade-offs

1. **`getBoundingClientRect` viewport-relative**：element 在長頁面且未 scroll 到時回傳座標會 > viewport — 預期走 `elementOutsideViewport` fail-closed；`--scroll-into-view` 已列 future issue
2. **Selector JS escaping**：使用者傳 `div[title="He said \"hi\""]` 之類含雙引號的 selector，JS 字串會壞；由 Swift 端用 `JSONSerialization.data(withJSONObject: [selector])` 或相等 escape 工具處理
3. **Sub-pixel element rect**：`getBoundingClientRect` 可能回傳小數，`ImageCropping.pixelRect` 已有 `CGRect.integral` 處理；最壞 1 px tolerance
4. **`--element --full` 下 element 在 resize 後才測量**：與 `--content-only --full` 同步時序需求，統一在 post-resize phase 做 JS eval 和 AX read
5. **Ambiguous error 的 text snippet 有 PII/secrets 風險**：若使用者網頁 element 含 token / 密碼 / 個資，rich error 會把前 60 chars 印到 terminal — 文件註明「error output 可能含頁面文字，CI logs 要小心」；snippet 長度上限 60 chars 且 trim whitespace
6. **`--element-index` 使用者看 error 後改寫 script，頁面變化後 count 同但洗牌**：silent-wrong 風險仍在，但比 `--first-match` 小（index 至少是 assertion）；mitigation 靠 rich error 的 rect/text 讓使用者選擇更精確的 selector
7. **CSS 偽元素與 `::before` / `::after`**：`querySelectorAll` 不回 pseudo-element；使用者想擷取 decoration 會失敗，error 訊息需暗示「pseudo-element cannot be selected」— 這是 CSS 限制，非本 feature bug
8. **Accessibility revocation 在 `--element` 執行中**：AX check 在 run() 入口；若使用者中途撤銷 AX，`getAXWebAreaBounds` 會 throw — fail-closed OK，訊息清晰

9. **Safari window height 被 macOS 鎖在 display 高度**：這是 apply 期間發現的 pre-existing #29 `--full` 行為（不是 #30 引入）— `setAXWindowBounds` 要求 6000pt 高的 window 會被 macOS window server 靜默 clamp 到 display 高度（本機實測從 6150 → 1100pt）。對 `--full --element` 的影響：若 element 在 display-clamped viewport 內可正確裁切；若 element 在 clamp 後仍超出 viewport，`elementOutsideViewport` fail-closed。**Spec scenario 已更新**反映此限制：原 "resize 到 scrollable 高度後 element 一定在 viewport 內" 改為兩個 scenario（fit-within-display 成功 / exceed-display fail-closed + 錯誤訊息建議 scrollIntoView）。真正解決長頁面的 element-crop 需要 `--scroll-into-view`，已列 future issue。
