## Summary

將所有 System Events file dialog 路徑輸入從 `keystroke` 逐字打改為剪貼簿 `Cmd+V` 貼上，同時全面升級 dialog 等待邏輯。

## Motivation

目前 `upload` 和 `pdf` 的 file dialog 操作用 `keystroke` 逐字打路徑：
- 鍵盤被控制 ~1-3 秒（路徑越長越久）
- 中文路徑、特殊字元可能出問題
- `delay 1` 盲等不精確

改用剪貼簿 + `Cmd+V`：
- 路徑貼上 ~0.05 秒，不論長度
- 鍵盤控制從 4 步（Cmd+Shift+G、逐字打、Enter、Enter）降到 3 步（Cmd+Shift+G、Cmd+V、Enter），且打字那步瞬間完成
- 中文/特殊字元完全不怕（剪貼簿是原始字串）

同時統一兩處 file dialog 邏輯：
- `UploadCommand.swift` — 已有 `repeat until exists`（#14）
- `PdfCommand.swift` — 仍用 `delay 1` 盲等，需升級

## Proposed Solution

1. 抽出共用的 `navigateFileDialog(path:)` 函式到 `SafariBridge.swift`，兩個 command 共用
2. 路徑輸入改為：`set the clipboard to path` → `keystroke "v" using command down` → 還原剪貼簿
3. 所有 dialog 等待改為 `repeat until exists`（UploadCommand 已做，PdfCommand 未做）
4. 確認按鈕改用 `AXDefault` attribute（locale-independent）+ try/on error fallback `keystroke return`
5. Upload 加入 `AXIsProcessTrusted()` 智慧預設：有權限 → native、無權限 → JS fallback
6. 修復 6-AI 驗證的 P2 問題（`__sbUpload` 清理、URL fragment 忽略、URL 檢查頻率、README 舊描述）

## Non-Goals

- 不改 `keystroke "g" using {command down, shift down}` — 這是快捷鍵，無法用其他方式取代
- 不改 `keystroke return` — 只有路徑確認那個 Enter，不需要剪貼簿
- 不做剪貼簿加密或安全清除 — 路徑是本機檔案，非敏感資訊

## Alternatives Considered

- **`set value` on text field** — 測試過，macOS file dialog 的 Go to Folder combo box 不觸發路徑解析，無法使用
- **`keystroke` 保持現狀** — 可行但慢、不支援特殊字元、鍵盤控制時間長

## Impact

- Affected specs: `file-upload`（upload 預設行為改變）、`pdf-export`（dialog 邏輯改善）、`non-interference`（鍵盤控制時間大幅縮短）
- Affected code:
  - `Sources/SafariBrowser/SafariBridge.swift` — 新增 `navigateFileDialog(path:)` 共用函式
  - `Sources/SafariBrowser/Commands/UploadCommand.swift` — 改用共用函式 + AXIsProcessTrusted 智慧預設
  - `Sources/SafariBrowser/Commands/PdfCommand.swift` — 改用共用函式（消除 delay 1 + keystroke）
