## Context

`safari-browser screenshot` 已有成熟的 AX-first 架構（見 `openspec/specs/screenshot/spec.md` 的 Hidden window capture requirement）。擴充 chrome-cropping 需要在這個既有架構上加「量 web content 區域 + 裁 PNG」的能力。

關鍵既有元件（`Sources/SafariBrowser/SafariBridge.swift`）：

- `resolveWindowForCapture(window:) -> (cgID, axWindow?)` — AX 有走 AX、無走 legacy CG 的 asymmetric fallback
- `getAXWindowBounds(_ element:) throws -> CGRect` — 讀 `kAXPositionAttribute` + `kAXSizeAttribute`
- `setAXWindowBounds(_:x:y:width:height:)` — `--full` 的 resize 基礎
- `doJavaScript(_:target:)` — 與特定 document 互動

既有 ScreenshotCommand 的關鍵路徑（`Sources/SafariBrowser/Commands/ScreenshotCommand.swift`）：

- 第 39-65 行：`hasExplicitTarget` 判定 + `resolveNativeTarget`，背景 tab 時丟 `backgroundTabNotCapturable`
- 第 80-84 行：simple path（`!full`）直接 `screencapture -x -l <windowID>`
- 第 86-214 行：`--full` path，resize → capture → restore，AX 有優先走 AX bounds，無走 AS

新功能必須與這些路徑無縫整合，**不破壞** 既有 non-interference / fail-closed 契約（#26 precedent）。

## Goals / Non-Goals

**Goals:**

- 提供 `--content-only` flag，能在 `screenshot` simple path 與 `--full` path 下都裁掉 Safari chrome
- 在 AX 可用時精確定位 `AXWebArea` 幾何（Reader Mode / sidebar / tab overview 等異形 layout 皆正確）
- 維持 non-interference：不 tab-switch、不 raise 多餘 window
- 維持 fail-closed：AX 權限未授或 `AXWebArea` 找不到時，清楚拋錯，不 silent wrong output
- 支援 HiDPI（retina / Display Scaling / multi-monitor）於裁切階段正確換算 points ↔ pixels

**Non-Goals:**

- Element-scoped crop（已拆到 #30）
- Image element 下載（已拆到 #31）
- JS-based viewport 測量 fallback（Route B，已在 diagnosis 拒絕）
- 多 `--content-only` 語意別名（`--viewport` / `--no-chrome`）
- 自動請求或引導 Accessibility 權限 UI
- 修改既有 `screenshot` simple path 的預設輸出（僅在 flag 出現時啟動裁切）

## Decisions

### Flag name: `--content-only`

`ScreenshotCommand` 既有 `--full` 佔用 scrollable-content 語意。若選 `--viewport`，使用者可能誤以為「viewport 擷取」與 `--full` 對立，但 `--full` 本身就是擷取 viewport 區域的 scrollable extension，語意衝突。`--no-chrome` 為反向命名，不符合 Swift `@Flag` 預設 false 慣例。`--content-only` 雖然字面稍抽象，但在 issue body、Real-world repro、Expected 三處已出現，使用者心智已適配。

**Alternative considered**: `--viewport` — 技術精確，但與 `--full` 的語意空間重疊，教學成本提高。

### AX fallback: hard-fail with `accessibilityRequired`

`--content-only` 的精度敏感度比既有 Hidden window capture 更高：前者只要 CG windowID 對即可，後者是幾何精確的 crop rect，1-2 points 偏移肉眼可見。JS fallback（Route B）在 Reader Mode / sidebar 下會**靜默錯誤**，違反 fail-closed。既有 `--window N` 路徑已是 hard-fail（`accessibilityNotGranted`），新 flag 沿用同類嚴格策略，CLI surface 一致。

錯誤訊息要明確告知：

- 為何拒絕（AX 未授權）
- 如何授權（System Settings → Privacy & Security → Accessibility）
- 若不想授權的替代方案（不用此 flag、接受 chrome）

**Alternative considered**: JS viewport + chrome-on-top 假設 — 在 Reader Mode / sidebar 下靜默錯誤，不可接受。

### No-op threshold: absolute tolerance

當 Fullscreen / Reader Mode / Stage Manager 下 `AXWebArea` bounds ≈ window bounds 時，裁切是 identity 操作，應 skip 直接寫出原 PNG。

判定規則：`viewport.width == window.width` **且** `(window.height - viewport.height) < 4 points` → skip crop。

- **Width 要求 exact 相等**：Safari chrome 只在 y 軸，x 軸絕不應有差異；若有，代表 AX 讀到錯的元素
- **Height 容忍 < 4 points**：覆蓋 AX / AS bounds 的 rounding drift、retina subpixel、macOS window server 的整數截斷
- **不用百分比**：98% 會誤判「近似全屏但仍有小 chrome」（1920×1075 viewport in 1920×1080 window → 5px chrome 仍明顯）

**Alternative considered**: 百分比（98% / 95%）— 在邊界尺寸下誤判，拋棄。

### `--full --content-only` combo: coherent, resize-then-remeasure

兩個 flag 可同時使用。流程：

```
resolve target
  → resize window to scrollable dims (既有 --full 流程)
  → capture PNG
  → [NEW] 重讀 getAXWebAreaBounds (resize 後)
  → [NEW] cropPNG(path, viewport rect in resized window coord)
  → restore window bounds (既有流程)
  → restore scroll position (既有流程)
```

關鍵：**重讀** AXWebArea bounds 必須發生在 resize **之後**、restore **之前**。理由是 resize 後 chrome 高度通常不變，但 Safari toolbar 在特定尺寸下會折疊（Diagnosis Risks #4），只有 resize 後量才準確。

**Alternative considered**: 互斥 flag（`--full --content-only` 丟 validation error）— 強迫使用者記 flag 矩陣，壞 UX；而且「長教學頁面 + 去 chrome」是合理組合。

### HiDPI scale: dynamic `cgImage.width / windowBounds.width`

裁切實作本來就要把 PNG 讀回記憶體（`CGImageSource` → `CGImage.cropping(to:)`），從 `CGImage.width` 推 scale 成本 = 0。`NSScreen.backingScaleFactor` 需先解析 window 在哪個 screen，多螢幕時 `NSScreen.main` ≠ window owning screen，額外複雜度與 failure mode。

Dynamic 路徑自動處理：

- Retina（2×）/ non-retina（1×）
- macOS Display Scaling（1.25× / 1.5× 的 downsampled）
- 外接低 DPI 螢幕（1× 輸出、不同於 main retina）
- Stage Manager / Split View 下的 window scaling

**Alternative considered**: `NSScreen.backingScaleFactor` — 需多 resolve window-screen 對應，邊界情況多，拋棄。

### Abstractions: `getAXWebAreaBounds` in SafariBridge

AX getter 放 `SafariBridge.swift` 與既有 `getAXWindowBounds` / `setAXWindowBounds` 同檔同命名 pattern：

```swift
static func getAXWebAreaBounds(_ axWindow: AXUIElement) throws -> CGRect
```

實作：`AXUIElementCopyAttributeValue(axWindow, kAXChildrenAttribute, ...)` 遞迴找 role == `"AXWebArea"` 的第一層子元素，深度上限 3。找到後讀 `kAXPositionAttribute` + `kAXSizeAttribute`。找不到拋 `webAreaNotFound`。

**Alternative considered**: `viewportBoundsInWindow` / `contentArea` 等 domain-level 命名 — 破壞既有 `getAX...` 一致性，社群偏好 implementation-leaky-but-consistent。

### Abstractions: `cropPNG` in new `Utilities/ImageCropping.swift`

裁切 helper 放新檔 `Sources/SafariBrowser/Utilities/ImageCropping.swift`：

```swift
enum ImageCropping {
    static func cropPNG(at path: String, to rect: CGRect) throws
}
```

理由：純圖像邏輯，無 Safari / AX 依賴，方便 unit test（符合 `common-testing.md` 的 Unit Tests 類別）。`SafariBridge` 的 AX helpers 不應混入 PNG I/O（職責分離）。

**Alternative considered**: 把 `cropPNG` 放 `SafariBridge` — 職責混雜，測試時需拉 SafariBridge 整包依賴。

## Risks / Trade-offs

- **AXWebArea 遞迴在 iframe / multi-frame 頁面可能拿錯元素** → 只找第一層 `AXWebArea`，深度上限 3；若抓到 sub-frame 測量會錯。**Mitigation**: 記錄找到的 AXWebArea 在 window 內的 y 座標，若 y > 50% of window height，拋 `webAreaNotFound`（暗示抓到 sub-frame 而非主 viewport）
- **Resize 後 Safari toolbar 可能在邊界尺寸折疊** → 重讀 AXWebArea 在 resize 後，不用 resize 前的值
- **CGImage cropping 座標系 y 方向** → `cgImage.cropping(to:)` 用 top-left origin image-space；AppKit window bounds 是 top-left screen origin（macOS 10.0+ flipped），方向一致。需 integration test 驗證
- **HiDPI scale 非整數（1.25× / 1.5×）** → Crop rect 乘 scale 後可能是非整數像素，`CGRect` 會整數化；實測最壞 1 px 偏移。**Mitigation**: `cropRect` 先 `integral` 取整，接受 1 px tolerance
- **AX `kAXChildrenAttribute` 在 Safari private window / PDF preview 等特殊文件可能拿不到** → 這類情境下整個 viewport 概念不適用。**Mitigation**: `webAreaNotFound` 錯誤訊息要建議使用者改用不帶 `--content-only` 的擷取
- **`--content-only` 與 `--full` resize 期間，使用者手動 resize window** → 既有 `--full` 路徑本來就有這問題（race），沿用既有最佳努力 restore；文件標注「擷取期間不要手動操作 Safari 視窗」
- **ErrorMessage 過長** → `accessibilityRequired` 的錯誤訊息需簡潔但足夠引導；參考既有 `accessibilityNotGranted` 的訊息風格（一行 describe + 一行 action）
