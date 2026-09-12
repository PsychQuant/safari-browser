## Decisions

DialogTreeSnapshot 新增 observedWindowIDs，valid unique ID 讀取後記錄。GlobalDialogProbe 的同一 worker operation 轉成 Sendable WindowDialogObservation（不讓 AX node 逸出），保留 snapshot.scanResult 作為既有 scan() 回值。observe() 使用相同 worker/budget，整個listing只呼叫一次。

WindowDialogObservation.status(for:Int?) 回 WindowDialogStatus，含 state(present/clear/unknown)、windowID、messages、reason；jsonObject計算屬性供JSONSerialization，textSuffix供兩個formatter。唯有完整 snapshot 且包含該 stable ID 才可 clear/present；否則unknown，完整性失敗不輸出部分message。多個候選可列messages；text單一訊息用既有bounded escaping，多個用count，unknown明列。state只描述可見window-native dialog，不宣稱每個tab被阻擋或沒有背景pending dialog。

WindowDialogObservation.capture() 先尊重process或DaemonRequestContext的dialogProbeDisabled；之後可使用@TaskLocal provider override供tests，正式路徑檢查GUISession，再GlobalDialogProbe.shared.observe()。停用／session／權限／不完整／未觀測ID各有明確reason。DaemonRequestContext只新增讀取disabled的logical property，不洩漏環境。

DocumentInfo與TabInfo增加optional windowID，constructor預設nil保持既有fixture相容；flatten從原WindowInfo傳遞。bare listTabs先讀一次front的stable ID，有ID則所有後續欄位使用window id；沒ID維持原data fallback但status unknown。explicit/profile listing沿用既有resolved ID。

commands保留profile/globalindices/原排序。只在有rows時做capture一次。JSON每列blocking_dialog含state/window_id/messages/reason。documents行尾、tabs第四個TSV欄位追加present/unknown標記；clear不加suffix，原前綴／前三欄不動。legend/unknown說明送stderr，使用TargetOptions.stderrWarnWriter。無rows不製造fake rows。

## Validation

TDD provider snapshot/legacy scan mapping、complete與unknown、ID membership、停用/permission/session、bounded worker。Formatter測prefix/TSV前三欄、escaping、profile與rowidentity。橋接測bare tabs固定ID、flattenID、每command僅一次capture。GUI效能與真實marker待解鎖，不能把fake tests當實機證據。
