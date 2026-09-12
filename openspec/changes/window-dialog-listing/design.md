## Decisions

DialogTreeSnapshot 新增 observedWindowIDs，valid unique ID 讀取後記錄。GlobalDialogProbe 的同一 worker operation 轉成 Sendable WindowDialogObservation（不讓 AX node 逸出），保留 snapshot.scanResult 作為既有 scan() 回值。observe() 使用相同 worker/budget，整個listing只呼叫一次。

WindowDialogObservation.status(for:Int?) 回 WindowDialogStatus，含 state(present/clear/unknown)、windowID、messages、reason；jsonObject計算屬性供JSONSerialization，textSuffix供兩個formatter。唯有完整 snapshot 且包含該 stable ID 才可 clear/present；否則unknown，完整性失敗不輸出部分message。多個候選可列messages；text單一訊息用既有bounded escaping，多個用count，unknown 於 JSON 與 stderr 明列，明確 disabled 則不加文字提示。state只描述可見window-native dialog，不宣稱每個tab被阻擋或沒有背景pending dialog。

WindowDialogObservation.capture() 先尊重process或DaemonRequestContext的dialogProbeDisabled；之後可使用@TaskLocal provider override供tests，正式路徑檢查GUISession，再GlobalDialogProbe.shared.observe()。停用／session／權限／不完整／未觀測ID各有明確reason。DaemonRequestContext只新增讀取disabled的logical property，不洩漏環境。

DocumentInfo與TabInfo增加optional windowID，constructor預設nil保持既有fixture相容；flatten從原WindowInfo傳遞。bare listTabs先讀一次front的stable ID，有ID則所有後續欄位使用window id；沒ID維持原data fallback但status unknown。explicit/profile listing沿用既有resolved ID。

commands保留profile/globalindices/原排序。只在有rows時做capture一次。JSON每列blocking_dialog含state/window_id/messages/reason。documents 行尾、tabs 第四個 TSV 欄位僅追加 present 標記；clear/unknown 不加 suffix，原前綴／前三欄不動。legend 與去重後的 unknown reason 說明送 stderr，disabled 不新增文字提示，使用TargetOptions.stderrWarnWriter。無rows不製造fake rows。

## Validation

TDD provider snapshot/legacy scan mapping、complete與unknown、ID membership、停用/permission/session、bounded worker。Formatter測prefix/TSV前三欄、escaping、profile與rowidentity。橋接測bare tabs固定ID、flattenID、每command僅一次capture。GUI效能與真實marker待解鎖，不能把fake tests當實機證據。

## Review correction

原 unknown 文字 suffix 違反 opt-out 恢復舊格式的契約。依 R1 logic/DA 審查，unknown 改於 stderr 摘要揭露、JSON 每列保留；明確 opt-out 完全不加新的 dialog 文字提示。InProcessStepDispatcher 的 documents 曾保留獨立舊 JSON encoder，改共用 DocumentsCommand.jsonRows 與一次 capture，避免 daemon exec 遺漏 metadata；以實際 dispatch 函式搭配注入測試驗證 enabled/disabled 兩種請求。
