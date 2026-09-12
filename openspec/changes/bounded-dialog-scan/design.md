## Context

舊 collectDialogs 用 Optional 且把 AXWindows 讀取失敗回成空陣列；findDialogElement 的 depth/prefix 截斷沒有留下完整性。入口探測已具備 95 ms caller wait 與 single-flight，但全域路徑尚未採用。本機六窗 clear 基準為 0.163–0.180 秒；15 窗／其他 Space 的舊 18 秒案例仍需有整體上限。

## Goals / Non-Goals

目標：全域 caller 800 ms 上限、確實檢查所有視窗才回 none、保留真實本文與按鈕、dismiss 在完整的新快照上決策。
非目標：不實作 #129 列表標記或 #108/#131 的 JS 診斷；不自動 focus、切 Space 或 dismiss；不宣稱能中止單次 OS IPC。

## Decisions

### Shared bounded worker

新增 BoundedAXWorker，production 的入口與全域探測共用 `.shared`，最多一個在途工作。`run(budget:fallback:operation:)` 的 operation 收到同一個 DispatchTime deadline；caller timeout 只放棄該次結果，不新增 worker、不允許晚到值污染下一次。每個測試實例可用獨立 worker。`withExclusive(fallback:operation:)` 讓同步 dismiss scan/press 使用同一個互斥額度，忙碌則拒絕；不把 AXPress 放進 caller 已返回後仍可繼續的背景工作。入口預算保持95ms，全域上限800ms。

### Complete global scanner

新增 DialogTreeScanner，使用既有 DialogProbeProvider 與 DialogMessageText。scan 接受 DispatchTime deadline；每次讀取 timeout 為 min(剩餘時間,40ms)。最多64個視窗、每窗512節點與8層、每個dialog256節點與6層。超出界線、失敗、未知視窗ID或非AXWindow根、重複ID皆不完整。WebArea 是刻意排除的網頁內容；不任意略過原生 toolbar/group 分支。視窗根本身帶AXDialog/AXSystemDialog subrole也須辨識。深度優先找到最外層 native dialog 後讀它的訊息與按鈕，繼續其他分支以辨識多個候選。遇到巢狀已知native root須保留為另一個候選，其細節不混入外層；因已知歧義，巢狀候選訊息可明示未讀。Node以整次scan共用的Hashable身分集合去重（跨視窗、discovery與details）；只允許剛找到的dialog root交接details時的那一次既有身分。循環或重複引用須不完整，不能捏造更多候選。視窗根的role在實際走訪時驗證一次，不預先重讀。訊息與按鈕元素只讀一次並保留同序配對。詳細資料截斷/讀取失敗使嚴格全域結果不完整，不能支持按鈕決策。可選文字或title屬性回unsupported/noValue是明確不存在，依既有規則省略；無名稱的按鈕不列入選擇，但繼續走訪其子項。文字區域的可編輯性若未知則不完整，不能讀取其值。

同步掃描結果保留 Node/按鈕引用供同一個執行緒立即按鈕；背景全域讀取只將 Sendable 的 DialogScan 值返回 caller，AX節點不跨 worker。已確認的多個候選可回 ambiguous；不完整的0/1候選不得回 none/one。

### Strict command integration

DialogScan 與 DialogPressOutcome 新增 inspectionIncomplete，命令回非0並建議重新執行 list，不假稱沒有dialog或缺權限。GlobalDialogProbe 透過共享 worker 跑全域scanner；SafariBridge.scanBlockingDialogs 改接它。dismiss 以同步scanner重讀所有視窗，唯完整且單一候選可讓原本decide callback選index；使用同次快照中的button元素，按下前重查session與deadline。保留原有AXPress結果不確定性，絕不自動重試。40ms上限適用讀取；AXPress可使用同一個800ms deadline的剩餘時間，不額外把動作切成40ms。

## Implementation Contract

list 在正常15個可讀視窗情境於1秒內完成，caller最多等待800ms的讀取工作；未完成回 inspectionIncomplete，exit非0。單一dialog保留目前message/buttons與安全文字輸出，多個保持拒絕選擇；未授權、鎖定及不可用session分別保留既有錯誤。入口target/TTL/200ms命令總預算不變。全域與入口共享worker忙碌時不可排隊或增加在途worker。dismiss 不使用舊的寬鬆collector，也不在背景執行動作。

驗收：完整15窗合成樹與實機自有fixture、每類讀取阻塞／錯誤／截斷測試、single-flight交叉競爭、晚到結果隔離、未完整時press callback不執行、同次按鈕配對、既有dialog及daemon回歸。

## Risks / Trade-offs

- AX IPC 無法強制取消 → caller放棄結果、在途額度保持到真正結束；忙碌期間誠實回unknown。
- 某些可見資訊不可讀 → 嚴格list/dismiss拒絕是有意行為，不能藉逾時取得absence證明。
- 同步AXPress仍依系統回應 → 保留pressUnconfirmed語意，不宣稱硬性動作完成期限。
- 預算需要涵蓋15窗 → 先實測現有provider；不足時再評估batch attribute API，不能用跳過未知原生分支換成功。

## Migration Plan

保留成功輸出與選鈕介面，僅新增明確的不完整錯誤。依PR150基底建立獨立PR；不自動合併。回退以回退本次提交處理。
