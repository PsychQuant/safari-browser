## Why

safari-browser 的核心賣點是「使用者的 Safari，使用者可以隨時觀察和介入」。但目前沒有明文的設計原則規範指令在什麼情況下可以控制滑鼠/鍵盤、彈出對話框、或發出聲音。每次開發新功能（如 #11 upload --native、#10 channel monitor）都要重新辯論「預設行為該不該干擾使用者」。

需要一個 cross-cutting 的 design principle：**預設情況下，使用者可以同時做其他事情而不受 safari-browser 的影響**。

## What Changes

- 建立 `non-interference` spec，以 SHALL/MUST 規範所有指令的預設行為
- 定義「干擾行為」的分類：HID 控制（滑鼠/鍵盤）、系統對話框、音效、視窗焦點搶奪
- 規範：所有干擾行為預設關閉，需明確 opt-in flag 才啟用
- 記錄現有符合此原則的設計決策（`--allow-hid`、`screencapture -x`、`SB_CHANNEL_MONITOR=1`）作為 conformance examples

## Non-Goals

- 不修改任何現有指令的行為 — 現有實作已大致符合此原則
- 不要求已 opt-in 的功能（`--allow-hid`、`--native`）變更其行為
- 不涉及 Safari Automation 權限設定（那是 macOS 層級的，不在 CLI 控制範圍）

## Capabilities

### New Capabilities

- `non-interference`: 跨功能設計原則，規範所有指令的預設行為必須不干擾使用者操作。定義干擾行為分類、opt-in 機制、conformance 判定標準。

### Modified Capabilities

（無 — 此為新增的 cross-cutting principle，不修改現有 spec 的 requirements）

## Impact

- Affected specs: 新增 `specs/non-interference/spec.md`
- Affected code: 無直接程式碼變更 — 此 spec 是對未來開發的約束，不是對現有程式碼的修改
- 間接影響：未來所有新增指令/功能的設計審查需符合此 spec
