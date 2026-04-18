## Why

`safari-browser screenshot` 目前一律擷取整個 Safari 視窗，包含 URL bar / tab bar / toolbar 等 chrome（約 300 px）。批次擷取網頁時，使用者每張都必須額外裁切；沒有 built-in 路徑時，使用者會退而使用 `screencapture -R x,y,w,h`，這打破 `screencapture -l <windowID>` 原本「不受 z-order 影響」的保證（見 `Sources/SafariBrowser/Commands/ScreenshotCommand.swift:82`），任何其他視窗蓋在 Safari 上就會漏到截圖裡。對應 issue #29。

## What Changes

- 新增 `--content-only` flag 給 `screenshot` 命令，只擷取 Safari web content viewport，裁掉 Safari chrome（URL bar / tab bar / toolbar）
- 新增 `SafariBridge.getAXWebAreaBounds(_ axWindow: AXUIElement) throws -> CGRect` AX helper，透過 `kAXWebAreaRole` 子元素讀 web content 區域的 screen-coordinate rect
- 新增 `Sources/SafariBrowser/Utilities/ImageCropping.swift`，提供純函式 `cropPNG(at path: String, to rect: CGRect) throws`（讀 PNG → `CGImage.cropping(to:)` → 寫回）
- `--content-only` 在 Accessibility 權限**未授權**時 hard-fail（拋 `accessibilityRequired` 錯誤），**不**走 JS `innerWidth/innerHeight` fallback
- `--content-only` 與 `--full` 可同時使用：流程為 resize → capture → 重讀 AXWebArea bounds → crop → restore
- `--content-only` 在 viewport 寬度等於 window 寬度且高度差小於 4 points 時（Fullscreen / Reader Mode 等）skip crop，直接寫出原 PNG
- HiDPI scale 動態計算：`Double(cgImage.width) / Double(windowBounds.width)`，不使用 `NSScreen.backingScaleFactor`
- 維持 non-interference 原則：沿用 #26 precedent，不 tab-switch、不 raise 不必要的 window

## Non-Goals (optional)

- **Element-scoped crop**（給 CSS selector 裁特定 element）— 拆到獨立 issue #30
- **Image element 下載**（從 DOM 解析 `img.src` 直接下載原始資源）— 拆到獨立 issue #31
- **JS-based fallback 路線**（Route B）— Diagnosis 已決定用 Route A (AX) 作為唯一路徑；精度敏感度不允許 silent-wrong output
- **自動請求 Accessibility 權限** — 未授權時丟錯並告知使用者如何開啟，不嘗試觸發系統對話框（遵守 non-interference）
- **`--no-chrome` / `--viewport` 別名** — 只提供單一 canonical flag `--content-only`，避免 CLI surface 發散

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `screenshot`：新增 `--content-only` flag 的行為需求（hard-fail on missing AX、no-op threshold、`--full` 組合、HiDPI scale 計算）

## Impact

- Affected specs: `screenshot`（新增 requirements 與 scenarios）
- Affected code:
  - `Sources/SafariBrowser/Commands/ScreenshotCommand.swift`（新 flag + crop 流程整合）
  - `Sources/SafariBrowser/SafariBridge.swift`（新 `getAXWebAreaBounds` AX helper）
  - `Sources/SafariBrowser/Utilities/ImageCropping.swift`（新檔，`cropPNG` 純函式）
  - `Sources/SafariBrowser/Utilities/Errors.swift`（新錯誤：`accessibilityRequired`、`webAreaNotFound`）
  - `Tests/SafariBrowserTests/ImageCroppingTests.swift`（新檔，crop 數學與 HiDPI scale 單元測試）
- Affected dependencies: 無新外部依賴；使用既有的 CoreGraphics / ImageIO（`CGImageSource`、`CGImageDestination`）
- Affected workflows: 批次網頁擷取（BookWalker / Plaud / 教學截圖）不再需要外部裁切；誘導使用 `screencapture -R` 的反模式消失
