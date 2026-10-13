## Decisions

`--expect-window-id` 與 `--expect-message` 必須同時提供或都不提供。ID>0；message使用原始字串精確匹配，不trim、不比對顯示截斷文字。初始scan的message不符即ValidationError，不進button selection。

expectedWindowID透過bridge傳入DialogPressExecutor（optional default nil）。先沿用session/deadline/完整性/唯一候選/按鈕一致性檢查，再檢查candidate.windowID；不符回既有refused outcome，不能呼叫decide或press。其後仍用原message+ordered buttons fingerprint拒絕命令內部變更。guarded拒絕以一般錯誤說明未按任何按鈕，不輸出非預期dialog內容。

harness在真正dismiss argv帶自己的window ID與nonce message；增加在上一個檢查與命令開始間被替換的fake案例。只重複preflight不是修法。不新增HID、default-button、focus或重播。harness在真正dismiss呼叫前記錄attempted；任何未確認結果都保留fixture，cleanup不再次press。AXPress成功不等於已關閉，須明確no-dialog回報或原fixtureJS恢復後才清除pending狀態。

## Validation

TDD parser pair/positive ID、exact raw message、same fingerprint wrong window zero decision/press、正確／未指定期望、existing stale/locked/incomplete refusal。相關CLI/MCP與harness回歸。真實GUI待解鎖，必須明示未驗收。

## Live acceptance correction (2026-09-13)

Safari 27 實測原文為 `JavaScript ` 加上 fixture nonce 訊息；共用 fixture_dialog_expectations 僅接受 nonce 原文與這個已量測的前綴兩種形狀，並將完整原文帶入 expect-message。legacy shell harness 同樣呼叫帶身份期望的 helper；helper 於 dispatch 前原子建立 attempt 檔案，跨程序 cleanup 不重播。結果不確定時只能先以自有 fixture 的 JS 回應證明恢復，才能關閉精確 URL；舊版缺 expectation 旗標的 binary 在建立 fixture 前即拒絕。

Legacy EXIT handler 必須保留原失敗狀態，且 cleanup 失敗時把原本的成功轉為失敗；任何 assertion 跳過都回 77，不算 acceptance。以實際 shell cleanup／終端片段搭配假 browser 程序驗證 recovery failure、close failure、既有失敗保留、全部成功及有 skip 五條分支。
