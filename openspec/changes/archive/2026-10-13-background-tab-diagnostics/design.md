## Context

ResolvedWindowTarget 有 windowID／anchorTabIndex，但 ResolvedScriptTarget 只保留 reference/key。必須保留固定分頁位置，且在失敗後重新查 current tab，不能沿用過期 isCurrent。

## Decisions

BackgroundTabDiagnosticTarget（windowID:Int, tabIndex:Int, matcher:SafariBridge.UrlMatcher?）是唯讀資料。ResolvedScriptTarget 增加 optional diagnosticTarget；無穩定 ID／固定 anchor 的 current-tab target 不推測。URL matcher 若已不匹配，診斷為 unknown。

BackgroundTabDiagnostics 提供 script(for:)->String?、inspect(Target?)->Observation(current/background/unknown)、warning(for:)->String? 與 @TaskLocal query override（@Sendable(String) async throws ->String）供隔離測試。正式查詢直接呼叫 runShell(/usr/bin/osascript, timeout:0.3)，沿用最長1秒的SIGKILL寬限，避免忙碌 daemon executor 阻塞診斷。只讀穩定window的tab count、current tab index、指定tab URL；輸出三個GS分隔欄位，嚴格驗證範圍與形狀。未知／錯誤無提示。

JS派送帶diagnosticTarget與既有warnWriter；runTargetedAppleScript的typed processTimedOut先沿用可見dialog檢查，再提示。getText空字串同樣先檢查可見dialog，再提示，仍保留成功空值。原error重新拋出，不改錯誤型別或值。非空成功、不含固定anchor的target、已確認可見dialog均不增加背景查詢。

提示只說診斷時的resolved target在背景、pending dialog可能尚未呈現；不證明dialog存在。使用固定文字，請重新確認target後以相同target flags執行tab focus，再dialog list；不嵌入URL或拼接可注入的shell命令。warnWriter優先，其次DaemonRequestContext.emit，最後stderr。

## Validation

TDD純觀測與script測試、TaskLocal fake runner 的bridge整合（timeout/empty/current/unknown/visible priority/no extra query）。GUI腳本僅自有nonce fixture，先checksession；在任何Safari操作前讀取選定binary的host-arch Mach-O UUID，透過guarded __mcp-exec與MCP context維持harness-owned process group，再用純wait 2000確認nested child確實繼承group，舊版逃逸／未知就拒絕GUI。之後刻意把alert留在背景，確認timeout提示，focus後確認dialog，安全清理。鎖定時exit77為未驗收，不能列為PASS。此GUI驗收與#128待解除鎖定的檢查序列執行。

## Risks

讀取只代表當時的位置，不能證明timeout原因；提示明示不確定性。目標已變、legacy無穩定ID、AppleScript失敗均不猜。不得自動focus/dismiss/replay。
