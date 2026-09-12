## Decisions

`--expect-window-id` 與 `--expect-message` 必須同時提供或都不提供。ID>0；message使用原始字串精確匹配，不trim、不比對顯示截斷文字。初始scan的message不符即ValidationError，不進button selection。

expectedWindowID透過bridge傳入DialogPressExecutor（optional default nil）。先沿用session/deadline/完整性/唯一候選/按鈕一致性檢查，再檢查candidate.windowID；不符回既有refused outcome，不能呼叫decide或press。其後仍用原message+ordered buttons fingerprint拒絕命令內部變更。guarded拒絕以一般錯誤說明未按任何按鈕，不輸出非預期dialog內容。

harness在真正dismiss argv帶自己的window ID與nonce message；增加在上一個檢查與命令開始間被替換的fake案例。只重複preflight不是修法。不新增HID、default-button、focus或重播。

## Validation

TDD parser pair/positive ID、exact raw message、same fingerprint wrong window zero decision/press、正確／未指定期望、existing stale/locked/incomplete refusal。相關CLI/MCP與harness回歸。真實GUI待解鎖，必須明示未驗收。
