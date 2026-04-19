## 1. Errors + fixture

- [x] [P] 1.1 Error cases: reuse `accessibilityRequired(flag:)` with customized alternative — 在 `Sources/SafariBrowser/Utilities/Errors.swift` 新增 6 個 error cases（`elementNotFound`、`elementAmbiguous(selector:matches:)` 含 rect + attrs + textSnippet、`elementIndexOutOfRange`、`elementZeroSize`、`elementOutsideViewport`、`elementSelectorInvalid`），並修改 `accessibilityRequired(flag:)` 的 `errorDescription` 依 flag 值 switch 客製 alternative 訊息（`"--element"` 建議 `--window N` + 外部裁切；`"--content-only"` 維持原訊息；其他 flag 給 generic fallback）
- [x] [P] 1.2 Test fixture: new `Tests/Fixtures/element-crop-test.html` — 建立 deterministic geometry fixture：`#target` 200×150@(50,100)、`.card` × 3（document order y=300/520/740）、`#hidden-el` `display:none`、`#below-fold` absolute y=5000

## 2. JS helper (SafariBridge)

- [x] 2.1 JS helper placement: `SafariBridge.getElementBoundsInViewport` — 實作 `static func getElementBoundsInViewport(selector: String, target: TargetDocument, elementIndex: Int? = nil) async throws -> ElementBoundsResult`：
  - 透過 `doJavaScript(_:target:)` eval JS 區塊（使用 `JSONSerialization.data(withJSONObject: [selector])` 安全包裝 selector 避免 quote injection）
  - JS 內做 `querySelectorAll` → 依 length 與 elementIndex 組合回傳 `{ ok: {...} }` 或 `{ error: 'not_found'|'ambiguous'|'zero_size'|'outside_viewport'|'index_out_of_range'|'selector_invalid', ... }`
  - Ambiguous 分支回傳所有 match 的 rect + `tag.class#id` attrs + first 60 chars trim whitespace text snippet（null 若無文字）
  - Swift 端 parse JSON → 轉對應 `SafariBrowserError` case 拋出；成功則回傳 `ElementBoundsResult { rectInViewport, viewportSize, matchCount, attributes, textSnippet }`

## 3. ScreenshotCommand integration

- [x] 3.1 加 `@Option var element: String?` + `@Option var elementIndex: Int?` 到 `ScreenshotCommand`；`validate()` 若 `elementIndex != nil && element == nil` 抛 `ValidationError`；若 `elementIndex != nil && elementIndex! < 1` 也 reject
- [x] 3.2 Flag combos: allow all, resize-then-measure-then-crop — 重構 `ScreenshotCommand.run()` 成 unified pipeline：resolve → capture →（if --full）resize → post-resize measurement（AXWebArea + element rect）→ 依 flag 組合決定 crop rect → crop → restore；**不**在 validate 拒絕 `--element --content-only` 或 `--element --full` 任一 combo
- [x] 3.3 Multi-match disambiguation: fail-closed + `--element-index N` + rich error — 實作「--element-index disambiguates multi-match deterministically」：JS helper 與 error case 串接：multi-match 無 `--element-index` → `elementAmbiguous` 含所有 matches；有 `--element-index N` 且 N ≤ matchCount → pick Nth in document order；N > matchCount → `elementIndexOutOfRange`；unique match + `--element-index 1` 視為合法 assertion；`elementAmbiguous` 的 `errorDescription` 列 rect + attrs + text snippet + 兩種 disambiguate 建議（refine selector / 加 `--element-index`）
- [x] 3.4 Crop to element bounding box with --element flag — AX hard-fail check（與 `--content-only` 同 gate pattern，flag 帶 `"--element"`）→ resolve target + capture → 呼叫 `SafariBridge.getElementBoundsInViewport` → 把 element viewport rect 加 AXWebArea origin 轉 window-rel rect → 呼叫 `ImageCropping.cropPNG(at:rectPoints:windowWidthPoints:)`
- [x] 3.5 --element fails closed on no match, multi-match, zero-size, outside-viewport, and invalid selector — 把 JS helper 的六個 error response 各自 propagate 為對應 `SafariBrowserError` case；每種情境都**不**寫任何檔案到輸出路徑（在 `screencapture` 之前或擷取後捕捉 error，早 throw 的 case 擷取本身不執行；晚 throw 的 case 若已寫入臨時檔需清理）
- [x] 3.6 --element combines with --content-only and --full — 組合路徑 integration：`--element --full` 於 resize 後的 settle phase 呼叫 `getElementBoundsInViewport`（與 `getAXWebAreaBounds` 同 phase，用 pre-measured windowBounds 避開 AX race 如 #29）；`--element --content-only` 視為 no-op（element 本身已隱含 chrome-stripped）

## 4. Tests

- [x] [P] 4.1 ElementCropTests unit tests — 新 `Tests/SafariBrowserTests/ElementCropTests.swift` 涵蓋：JSON response parsing（6 種 response shape）、viewport-rect + AXWebArea origin → window-rect 的座標轉換 math（1×、2×、1.5× scale）、`ElementBoundsResult` struct 構造、rich ambiguous error 的 matches array decoding
- [x] [P] 4.2 accessibilityRequired errorDescription customizes alternative by flag — 新 `ErrorsTests` 測試：`testAccessibilityRequiredForElement`（驗證 `"--element"` message 含 `--window N` / `--url` + ImageMagick/sips 關鍵字）、`testAccessibilityRequiredForContentOnlyUnchanged`（驗證既有 `"--content-only"` message 不受新 switch 影響）
- [x] 4.3 Manual integration: --element 基本 crop — apply 期間實測 `--element "#target"` 於 fixture 頁面輸出 426×320px（200×150pt × 2.13 scale，dynamic HiDPI 對 Display Scaling 1.25× 正確推算）
- [x] 4.4 Manual integration: --element-index disambiguation — 實測 `--element ".card"` rich ambiguous error 列出 3 個 matches 含 rect/attrs/text snippet；`--element ".card" --element-index 2` 輸出 638×426px（第 2 個 card，300×200pt × 2.13 scale）；`--element-index 2` without `--element` 於 validate 階段被 reject
- [x] 4.5 Manual integration: --element --full combo — 發現並文件化 macOS Safari window-height clamp：`--full --element "#target"`（element 在 display-clamped viewport 內）on 新 window 驗證成功輸出 416×313px；`--full --element "#below-fold"` 於 display 高度（~1100pt）clamp 後 element 仍超出 viewport，正確 fail-closed 成 `elementOutsideViewport`。已更新 spec scenario（兩個：fit-within-display 成功 / exceed-display fail-closed）與 design.md Risk #9 反映 Safari 行為

## 5. Documentation & spec update

- [x] 5.1 `safari-browser screenshot --help` 自動包含 `--element` / `--element-index` 描述（由 ArgumentParser `@Option(help: ...)` 負責），apply 期間實測 `--help` 顯示兩個選項描述完整
- [x] 5.2 Archive note — 本任務不是 apply-time 工作，由 `/spectra-archive` 把 ADDED Requirements 合入 `openspec/specs/screenshot/spec.md`（預期從 9 → 14 requirements）
