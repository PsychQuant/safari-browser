## Why

#326 的確認視窗可見，但全域 AX 掃描持續不完整；反覆執行相同指令沒有收斂。main `ad317f9` 會把任何視窗的遍歷失敗套用到全部候選，因此無法安全操作已知目標。Safari 27 是否另有未暴露的原生結構，尚無可驗證證據。

## What Changes

- `dialog list`／`dismiss` 增加 `--window-id`，以穩定 ID 限定原生樹掃描；既有配對的 `--expect-window-id`／`--expect-message` 也使用指定範圍。
- 完整辨識唯一目標後，只遍歷目標；未知、重複、消失的 ID、目標不完整、多重候選仍拒絕。
- 未指定範圍維持全域唯一性；所有 dismiss 在第二次掃描核對第一次讀到的視窗 ID 與內容。
- 不完整或無候選的訊息說明 AX 可見性的限制及人工接手，不再要求無限重試。
- 補上回歸測試與 Safari 27 原生驗收步驟。未實測前保持草稿，不自動關閉 #326。

## Capabilities

### New Capabilities

- `scoped-dialog-inspection`: 以穩定視窗 ID 限定掃描與操作的安全契約。

### Modified Capabilities

- `global-dialog-inspection`: 明確區分全域與指定範圍，所有按鈕操作保留最初觀察的視窗身分。

## Impact

影響 DialogCommand、DialogTreeScanner、GlobalDialogProbe、WindowDialogObservation、SafariBridge 與錯誤訊息。無新增執行期相依；不改動 entry probe，也不合併尚未通過實機驗收的 PR #200。
