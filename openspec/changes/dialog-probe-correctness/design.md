## Context

Refs #134, #137, #135, #138, #133。承接 daemon-request-boundaries 的 request-local gate；本組修正 gate 內的身分與有效期限、AX 探測本身、以及漏掉的 native 指令入口。

## Goals / Non-Goals

Goals：不把別的視窗 dialog 歸因目標；沒探完不宣稱 clear；每指令 200 ms 總預算限制探測等待；讓 native 指令也得到警告。

Non-Goals：不操作使用者既有 dialog、不新增取消 AX IPC 能力、不保證動作與探測之間 Safari 狀態永不變動；#114 的輸出清理另案。

## Decisions

### 穩定視窗身分與入口涵蓋

Positional target 先透過 AppleScript 取得實際 window ID（一般傳輸使用 1 秒要求，daemon 內部執行仍受整個 exec request 的 client deadline 約束；不宣稱可取消 AppleScript）。已列舉的 WindowInfo 保留 windowID，不能再丟掉。AX worker 只接受正值 ID，逐一用 CGWindowID 比對，不用 AX 順序或 focused-window 猜測；身分取得失敗回 unprobed。

resolveNativeTarget 成功後統一 check；resolveToAppleScript 的快速路徑也取得穩定 ID。用解析後 reference＋key 的內部結果供 JS／空文字失敗路徑使用，避免靠全域 last。tabs --window 直接 listTabs 的路徑也補探測。取得身分的時間與 AX 探測時間分開量測，不能把前者隱藏於探測預算宣稱。

### 帶目標與期限的 gate

BlockingDialogState.none 改 clear。以 WindowKey 查詢 cache；state(for:) 與 throwIfBlocked(_:) 都拒絕超過 TTL 的值。單調時鐘是預設，測試可注入。每個 CLI 指令共用總探測預算，daemon exec 每步使用新預算。probe 在 lock 外執行，避免阻塞其他請求；警告與 cache 的更新仍受鎖保護。

通用 subprocess timeout 不再掃整個 Safari 或讀無 key 的最後答案。有明確目標的 JS／get text 失敗路徑重新檢查該 ID；沒身分就保留原錯誤，不能拿別窗 dialog 說明。

### 有界 worker 與可測樹走訪

新增單一有界 worker，單次呼叫端等待最多 100 ms（實作保留返回開銷）；gate 為每個 CLI 指令共用 200 ms 總預算。已有未完成工作時立即回 unprobed，不新增 worker／佇列。每次工作獨立結果容器；逾時結果不會延遲更新 gate cache。

AX 節點只在 worker 中建立與使用。每次 IPC 設剩餘時間的 messaging timeout；即使 SPI 不遵守，呼叫端仍可返回。注入 windows／windowID／role／subrole／children／text／buttonTitle provider；找不到、讀取失敗、超過深度或節點上限且仍有未檢查分支均為 incomplete→unprobed。確定 dialog 存在但讀不到文字時仍 present，顯示既有空訊息提示。

實測視窗的第二個原生子節點含 50 個分頁按鈕，廣度優先會先掃這些按鈕再到 content group 的第三層，造成 45 ms 到期。走訪改為深度優先、維持原 children 順序，先沿 content path 找 dialog；用含 50 個慢速兄弟分頁的 provider 回歸測試確認。不略過任何分支來宣稱 clear，未完成仍是 unprobed。

### 可驗證的 e2e

檢查 python3、計時結果及 mktemp 成功後才進行測試；區分不可用環境與非預期 CLI 錯誤。debug 輸出增加每指令實際 probe 累計 ≤200 ms 斷言。正式 dismiss 和 cleanup 共用 nonce-scoped 所有權檢查。針對 unicode 換行、全換行、debug=0/1、URL target 補單元斷言。

## Implementation Contract

- Stable target probing：假樹視窗順序倒置或插入設定／Inspector，不會影響正值 ID 配對；unknown 身分不回 clear。
- Expiring keyed verdicts：A 的 present 不阻擋 B；A 超過 2 秒 TTL 不再可用；無 key 查詢 API 移除。
- Bounded complete probing：阻塞 provider 的呼叫端在單次 100 ms 內返回 unprobed，同一邏輯指令最多消耗 200 ms；寬裕的單元測試時序容差只涵蓋排程延遲，debug 的正式預算為每指令累計 200 ms。工作上限為 1，遲到結果不寫 cache。
- Native command warnings：close／pdf／tab focus／upload／save-image／一般 screenshot／tabs --window 透過目標解析顯示警告，不修改 stdout schema。
- Honest probe tests：provider 的讀取失敗、深度 3 dialog、空樹與截斷樹有可區別的結果；Safari e2e 確認正常及 dialog 路徑。

## Risks / Trade-offs

- 正值 window ID 讀取增加有期限的 AppleScript round trip → 優先重用解析已有 ID，文件分開說明 target resolution 與 probe 成本。
- AX worker 無法硬取消 → 最多留一個工作，不堆疊；新請求回 unprobed。
- 很大的無 dialog 樹可能未完整檢查 → 回 unprobed；不能為了讓測試綠而宣稱 clear。
- 不實際移動使用者跨 Space 的視窗 → 以假 provider 驗證順序不相關，真人環境量測僅操作測試自行建立的分頁／視窗，未覆蓋情境明列。

## Budget correction — 2026-09-12

依 #126 已結案的 Errata（https://github.com/PsychQuant/safari-browser/issues/126#issuecomment-5622718883），舊 50 ms 口徑已由每指令 ≤200 ms 取代；本 change 初稿誤沿用舊數字，現更正。深度優先的走訪改善仍保留，避免無效讀取。

Gate 在鎖內為真正執行的 probe 預留剩餘預算，完成後按實際時間結算，快取命中不消耗 AX 預算。預算用完回 unprobed；不可用另一個視窗的答案。一般 CLI process 是一個邏輯指令；daemon exec 每個 step 是一個邏輯指令，step 開始只重置探測預算，保留該 request 的警告去重；新 step 清掉上一個邏輯指令的快取，同一步內仍採帶 TTL 的快取。beginCommand 不影響其他 request。

等待上限不是取消 AX IPC。Worker 忙碌仍立即 unprobed、不排隊。測試涵蓋兩次耗時探測後第三次不執行、下一步取得新預算，以及 probe 的剩餘預算往下傳。

Native UI scope：AXWebArea 是網頁內容邊界，不向其內走訪。ARIA dialog 不會停止 JavaScript，不能當成原生 blocking dialog。回歸測試與 HTML fixture 都包含 DOM dialog，仍須能執行 JS；原生 alert 則仍需被偵測。Screenshot 預設路徑在 capture resolver 取得實際 CGWindowID 後探測，以保留既有 CG fallback。

GUI 鎖定驗證：在鎖定狀態下 AXIsProcessTrusted 仍為 true，但 kAXWindows 的元素會退化成 AXApplication／ID 0；不能把它當成沒有視窗。Scoped probe 因無法配對正值 ID 而維持 unprobed；e2e 用 CGSessionCopyCurrentDictionary 檢查 GUI session，鎖定／無 GUI 回 77 並在任何 Safari 操作前停止，檢查本身失敗則回 1。測試用 session checker 可注入，避免 CI 依賴真人桌面狀態。
