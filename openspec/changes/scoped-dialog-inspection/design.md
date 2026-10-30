## Context

main `ad317f9` 的 DialogTreeScanner 共享 800 ms deadline，完整性為整體布林值。GlobalDialogProbe 對單一候選仍要求完整掃描，這是正確的全域安全保護，但不適合已明確指定視窗的操作。#326 的 System Events 實測找不到 sheet／按鈕，不能因此斷言原生 AXUIElement 也不可讀，亦不能假設改掃描範圍就能偵測。

## Goals / Non-Goals

目標：隔離指定視窗的內容掃描、固定操作身分、保留所有 fail-closed 條件、停止不會收斂的重試指引。

非目標：不穿透 AXWebArea、不以畫面座標或 Return 猜按鈕、不從 AXDialog subrole 推論它一定是 JavaScript confirm、不改 entry probe、不宣稱 Linux 測試證明 Safari 27 可操作。

## Decisions

### 穩定 ID 與限定範圍

選擇 `--window-id`，不接受位置序號代替身分。先完整列舉有界的視窗 ID，拒絕未知／重複 ID，再只遍歷匹配視窗；不讀取其他視窗的 role、subrole、children。列舉及 ID 讀取仍共用 deadline，失敗不能被忽略。目標遍歷後再讀一次 ID，變更即不完整。

### 全域唯一性與重新核對

無範圍參數仍掃描全部視窗，不能看到一個候選就放行。初次觀察回傳唯一候選的穩定 ID，按鈕操作的同步重掃描核對此 ID、訊息、依序按鈕名稱。限定模式下的多重候選指目標視窗內；其他視窗的 AXDialog 不納入本次決策。全域模式仍保守處理所有 AXDialog，不以缺少按鈕判斷是假對話框。

### 診斷與實機驗收界線

`none` 只代表支援的原生 AX 樹沒有候選。可見卡片仍存在時停止自動化，人工處理並收集 Safari／macOS 版本與原生 AX 結構。訊息不得建議反覆重試或重播儲存動作。保留掃描原本對 AXWebArea 的排除，以免任意網頁 ARIA 對話框取得原生操作資格。

## Implementation Contract

- list／dismiss 接受正整數 `--window-id`；dismiss 的既有配對 expectation 指定同一掃描範圍，衝突 ID 在 parse 時拒絕。
- 初次讀取、同步 press 重掃描、press 後讀取使用同一範圍。全域成功亦固定第一個候選的 ID，防止相同文字出現在其他視窗而吸收操作。
- 單一目標必須完整讀取；node/depth/window/time 上限、失敗讀取、重複節點與候選仍拒絕。按鈕精確比對與 uncertain delivery 保留。
- CLI 顯示指定範圍與穩定 ID，不暗示其他視窗已 clear。
- 回歸以假的 AX provider 驅動真實 Swift scanner／press executor；macOS 再執行完整套件與自有 fixture。未完成原生驗收保持草稿。

## Risks / Trade-offs

- 視窗 ID 列舉失敗仍可能阻擋指定目標 → 保守保留，不猜測未知視窗身分。
- AXWebArea 內或完全不暴露的 Safari 27 卡片仍不可操作 → 明確交接，不新增未驗證的分類規則。
- AX 讀取與 AXPress 不是原子交易 → 保留既有 snapshot fingerprint、同步 action 與 session/deadline 守衛，不宣稱消除所有競態。
- 跨指令未指定 expectation 時，list 並非授權 token → 需要 caller-bound 訊息時使用既有 paired expectation。
