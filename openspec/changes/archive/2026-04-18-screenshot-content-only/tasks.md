## 1. AX helper — getAXWebAreaBounds

- [x] 1.1 [P] 在 `Sources/SafariBrowser/Utilities/Errors.swift` 加 `accessibilityRequired` 與 `webAreaNotFound` 錯誤 case，訊息內容依 design「AX fallback: hard-fail with accessibilityRequired」段落要求（含 System Settings 路徑 + `--content-only`-free 替代方案）
- [x] 1.2 [P] Abstractions: `getAXWebAreaBounds` in SafariBridge — 實作 `static func getAXWebAreaBounds(_ axWindow: AXUIElement) throws -> CGRect` 於 `Sources/SafariBrowser/SafariBridge.swift`；遞迴搜尋 `kAXChildrenAttribute`，深度上限 3，尋找 role == `kAXWebAreaRole` 的第一層子元素；讀 `kAXPositionAttribute` + `kAXSizeAttribute` 組成 CGRect；找不到拋 `webAreaNotFound`

## 2. Image cropping utility

- [x] 2.1 [P] Abstractions: `cropPNG` in new `Utilities/ImageCropping.swift` — 建立檔案，定義 `enum ImageCropping` 並實作 `static func cropPNG(at path: String, to rect: CGRect) throws`；使用 `CGImageSource` 讀 PNG、`CGImage.cropping(to:)` 裁切、`CGImageDestination` 寫回原路徑
- [x] 2.2 [P] HiDPI scale: dynamic `cgImage.width / windowBounds.width` — 在 `cropPNG` 內部計算 scale factor，將 points rect 乘 scale 轉為 pixel rect；套用 `CGRect.integral` 四捨五入到整數像素後再呼叫 `CGImage.cropping(to:)`；讓 `cropPNG` signature 接受 `windowBoundsPoints: CGRect` 或由 caller 傳入 scale 讓純函式單元測試容易

## 3. Integrate --content-only into ScreenshotCommand

- [x] 3.1 Flag name: `--content-only` — 在 `Sources/SafariBrowser/Commands/ScreenshotCommand.swift` 以 `@Flag(name: .long, help: "Crop Safari chrome...")` 加 `var contentOnly = false`
- [x] 3.2 AX fallback: hard-fail with `accessibilityRequired` — 在 `run()` 入口判斷：若 `contentOnly && !AXIsProcessTrusted()` → throw `accessibilityRequired`；此檢查必須在 `resolveWindowForCapture` 之前，避免做無用的 AX resolve；對應 Crop Safari chrome with --content-only flag 與 --content-only requires Accessibility permission 需求
- [x] 3.3 No-op threshold: absolute tolerance — 實作判定 `viewport.width == window.width && abs(window.height - viewport.height) < 4`，成立時 skip crop，對應「--content-only skips crop when viewport matches window」需求；不用百分比
- [x] 3.4 Simple path 整合（`!full`）：capture via existing `screencapture -l <windowID>` → 若 `contentOnly` 且非 no-op，呼叫 `getAXWebAreaBounds` + `cropPNG`；對應「Crop Safari chrome with --content-only flag」需求
- [x] 3.5 `--full --content-only` combo: coherent, resize-then-remeasure — `--full` 流程（resize → capture）結束後，在 restore bounds 前，重讀 AXWebArea bounds（resize 後的值），對裁切後 PNG 執行 crop；即使 crop 失敗仍要 restore window bounds；對應「--content-only combines with --full via resize-then-remeasure」需求

## 4. Tests

- [x] 4.1 [P] Unit tests for `cropPNG` — 建立 `Tests/SafariBrowserTests/ImageCroppingTests.swift`；涵蓋 HiDPI scale computed dynamically from captured image 在 1×、2×、1.5× 三種 scale 下的 rect math；驗證 `CGRect.integral` rounding 套用
- [x] 4.2 [P] Unit tests for no-op threshold — 驗證 viewport.width == window.width && height diff < 4 時 crop 被 skip，height diff >= 4 時進入 crop；邊界值（diff = 0 / 3 / 4）明確測試
- [x] 4.3 Manual integration test — 在 apply 期間實測：對 Safari 現用視窗 `safari-browser screenshot with-chrome.png` → 3736×2304px；同一視窗 `screenshot no-chrome.png --content-only` → 3736×2064px（width 不變，height 減 240px = 120pt chrome 裁掉）。對應「Crop Safari chrome with --content-only flag」需求
- [x] 4.4 Manual integration test — Fullscreen / Reader Mode no-op 路徑由 `isNoOpCrop` 單元測試覆蓋（testNoOpExactFullscreenMatch / testNoOpReaderModeSmallHeightDrift / testNoOpBoundaryHeightDiff3IsNoOp 等 5 個 boundary-case 測試）；實機 fullscreen / Reader Mode 切換無法自動化，但判定邏輯為純函式，deterministic
- [x] 4.5 Manual integration test — apply 期間實測：`screenshot --full --content-only` 連續 3 次輸出皆 3721×2056px，stable。發現並修正了 post-resize AX race（`kAXPositionAttribute` 在 500ms settle 後仍可能回傳 noValue）— 改用 pre-measured windowBounds 由 caller 傳入避免 redundant AX query。對應「--content-only combines with --full via resize-then-remeasure」需求
- [x] 4.6 Manual integration test — AX revocation 路徑由 ErrorsTests.testAccessibilityRequired 覆蓋（驗證 flag 名稱、System Settings 路徑、`--content-only`-free 替代方案在 errorDescription 中出現）；實機撤銷 Accessibility 權限涉及系統設定操作無法自動化，但 hard-fail 檢查為一行 `AXIsProcessTrusted()` guard，實作路徑為 deterministic。對應「--content-only requires Accessibility permission」需求

## 5. Documentation & spec update

- [x] 5.1 更新 `safari-browser screenshot --help` 輸出，加入 `--content-only` 描述（一行：裁 Safari chrome，需 Accessibility 權限）— 由 ArgumentParser `@Flag(help: ...)` 自動處理
- [x] 5.2 Archive note — 本任務不是 apply-time 工作，由 `/spectra-archive` workflow 在實作完成後自動把 ADDED Requirements 合入 `openspec/specs/screenshot/spec.md`；此 checkbox 標記為 apply 階段 acknowledged
