## Context
上一批 PR #142/#145 已合併。問題由實測與交叉審查提出，均有可重現輸入。

## Goals / Non-Goals
Goals：讓退出權限限於正式 daemon，exec 選項限於單一 request，GUI 不可用與無視窗明確分開。
Non-Goals：不發布或替換已安裝 binary、不自動解鎖／授權／關閉使用者 dialog；不在此處重作全 app AX 走訪效能（#128）或 alert 本文（#127）。

## Decisions
1. Instance 接受可選 shutdown watchdog callback；預設 nil。Server 轉送此依賴，唯 __serve 正式入口注入五秒後 _exit 的排程。測試用可觀察 callback 驗證注入路徑，另等待超過原期限確認嵌入式測試不被終止。
2. 測試 runner 同時要求 exit 0 與 XCTest 最終 suite 完成統計、非零測試數；缺 final summary 必失敗。Makefile test/test-unit/test-all 均經此 runner。測試涵蓋部分輸出但 exit 0。
3. Exec envelope 新增 dialogProbe 物件，只接受 disabled/debug 布林值，client 即使 unset 也明確送 false；不得傳完整環境。缺整個欄位時保留 legacy daemon 環境預設。欄位錯誤在執行步驟前拒絕。Request context 在 gate 首次建立前套用選項，請求間不漏狀態。
4. GUI session utility 可注入 dictionary reader；locked 與 unavailable 為獨立錯誤，提示解鎖或使用有效登入 session。共用於 scoped provider、whole-app dialog scan／press 與 capture resolver。避免用 screen-recording／AX permission 代替 session 判定；locked scan 無 AX 操作，press 無副作用。

## Family-wide scope
- Instance 的測試與正式 Server caller；僅 __serve 持有宿主退出權限。
- ExecCommand envelope、DaemonDispatch decoder、DaemonRequestContext gate、diagnostics；其他 request 不受影響。
- DialogScan、DialogPressOutcome 的全部 switch，capture front/target resolver 與 scoped provider；保留未知狀態，不能退回 noDialog/noSafariWindow。

## Risks / Trade-offs
Legacy client 無 dialogProbe 欄位仍採 daemon 環境，文件明寫相容性。單元測試使用注入 session 避免真的鎖住使用者畫面；正常狀態再跑 Safari e2e。測試完成標記解析綁定目前 XCTest runner，格式改變需明確失敗並調整。

## Verification
每項先加入失敗 regression，再實作。完整 Swift suite 須不分群完成且有 final count；Python runner 假成功回歸；exec 四種旗標組合與連續 request；session 三態和操作前拒絕；smoke/daemon/live fixture。最後凍結 commit 做 IDD 六角度交叉審查。
