## Context

JSCommand 在多次 AppleScript 往返間使用共用 __sbResult／__sbLen／__sbResultLen／__sbLargeErr。已用真正的 JSCommand.run 寫檔路徑與 JavaScriptCore 重現同長度結果被其他呼叫取代；CompileCache 則按完整 source 鍵入，尚無錯誤快取的證據。原始 OpenAlex 事件的觸發原因仍未證實。

## Goals / Non-Goals

Goals：逐呼叫結果隔離、明確完整性失敗、保留空結果與 expression／statement 語意、錯誤不重跑、失敗不覆寫輸出檔；共用大型讀取的所有 caller 一併驗證。

Non-Goals：不推斷 API 回應的業務身分、不宣稱已重現原 OpenAlex 事件、不把頁面識別碼當作抵抗同頁惡意 JS 的安全邊界、不取代 #188 的完整分頁身分工作，也不改 #180／#181 的目標解析效能策略。

## Decisions

### 逐呼叫結果物件

JavaScriptResultSession 為一次執行建立 UUID 衍生的 ASCII 屬性名稱與 token，放置在 window 的獨立屬性。物件欄位為 token、phase、text；phase 僅有 prepared、running、done、error。初始化回覆必須帶正確 token 與 prepared，才送使用者程式。結果與錯誤皆存為字串，不共用其他指令的欄位。

JSWrapper 產生無 eval 的 expression／statement 兩種包裝。執行前必須找到同一個 prepared 物件，並先設 running；完成後才設 done，例外則安全轉成文字並設 error。使用者程式位於內層 function，協定區域變數名稱亦由唯一 token 衍生，避免 s 等普通名稱遮蔽使用者讀取的頁面變數。每次回讀都檢查 token、phase 及 text 型別。

替代方案「每次先刪舊欄位」不能防止交錯；全域 mutex 不能涵蓋不同 CLI 程序。因此使用每次獨立物件。

### 帶識別與範圍的傳輸框架

metadata 為 token:phase:length，length 是 JavaScript 明確轉成十進位字串的 UTF-16 單位數；Swift 嚴格驗證 token、狀態、非負整數與可表示範圍，不把無效資料當成零。

每塊為 token:offset:end:payload:token，固定識別長度與首段數字使 payload 內含冒號也能無歧義解碼。檢查 token、offset、end、尾端 token、payload 的 UTF-16 長度及總長。Swift 以 UTF-8 位元組解析 ASCII 框架，不用 Character 切割，以免 payload 開頭的組合字元黏到分隔符。固定尾端保護原字串尾端換行；不使用頁面 JSON／String 全域函式作協定轉換。上限維持每塊約 256 Ki UTF-16 單位，框架只增加常數長度。若預定 end 切在 UTF-16 代理對中間，JS 將 end 前移一個單位，Swift 驗證並依實際 end 前進。不能完整表示的回覆明確失敗。

一般模式先取完整框架，只有整個回覆為空（Safari 大結果限制）才從同一已完成物件分塊讀取；不重跑使用者程式。非空但錯誤的框架直接失敗。--large／--output 直接分塊。

### 安全的語法後備與導頁判讀

expression 往返後只有原物件仍為 prepared 才允許 statement 後備，因為使用者程式開始前必設 running。error／running／遺失物件均不得當語法錯誤重跑。若已收到 executed 卻讀回 prepared，判為不一致回覆，不允許後備。兩種形式都留下 prepared 才回報語法錯誤。

JSCommand 保留前後 URL 對照：先取得本次 executed 確認或完整的 completed metadata，且已確認 URL 改變時沿用既有導頁提示、不輸出值，也不覆寫 --output 檔。同 URL 但物件遺失時回報無法確認結果，不重跑程式。其他執行期錯誤仍帶 JavaScript error 與既有 CSP 提示。

### 共用讀取家族與清理

SafariBridge.doJavaScriptLarge 保持 caller 介面，內部改用 JavaScriptResultSession 的 expression-only 模式。JSCommand 使用允許 statement 後備的同一引擎。GetText／GetHTML 的大型後備直接將既有 DOM 讀取 expression 傳入 helper，不再先寫共用 __sbResult。SnapshotCommand 的兩個 helper 呼叫納入相容測試。

清理只刪除本次唯一屬性，成功、錯誤與取消都嘗試清理；傳輸或頁面消失導致清理不可用時不把其他呼叫的狀態當替代。錯誤清理不能遮蔽原錯誤。因終止程序無法保證清理，下一次呼叫仍使用新識別，不可能把殘留物件當成本次結果。

## Implementation Contract

js、js --large、js --output 及 doJavaScriptLarge 共用逐呼叫結果協定。可觀察輸出維持使用者回傳字串，協定前後綴不得洩漏至 stdout 或檔案；--output 僅在完整回讀成功後原子寫入。transport frame 遺失、識別不符、長度無效或短塊時非零結束，不接受部分結果。

驗收使用 JavaScriptCore 執行正式包裝程式，透過既有 AppleScript runner 接縫測正式 JSCommand；涵蓋交錯、空值、錯誤、statement、Unicode、導頁／遺失狀態、不完整塊與目的檔保留。必要的 Safari 真實行為驗收另記環境與限制，不以 JSC 測試宣稱已證實 AppleScript 傳輸行為。

## Risks / Trade-offs

- 共享協定同時牽涉 JSWrapper、JSCommand、SafariBridge、GetCommand → 依序實作並驗全體 caller。
- JS 字串長度與 Swift 字元數不同 → 用 UTF-16 單位比對，避免 String.count。
- raw frame 與 payload 有相同分隔符 → 前綴固定段數、尾綴固定長度，不對整個 payload 做 split。
- 同頁 JS 可任意改自己的全域狀態 → 此為意外交錯隔離與完整性檢查，不是安全驗證。
- 舊 #82 同 URL 導頁可能重跑 → prepared 身分仍存在才允許 fallback，否則明確失敗。

- 每次識別會改變 AppleScript source；現有 CompileCache 以完整 source 保留 NSAppleScript → #170 先前「重複 js 有快取命中、編譯成本低」的判斷必須重測，且需檢查長時間 daemon 的快取成長。此風險尚未以實測排除，不宣稱維持原暖啟動效能。

## 2026-09-28 審查修正

### 暫時編譯與舊 daemon 相容

PreCompiledScripts.CachePolicy 區分 reuse 與 ephemeral。ephemeral 在原有 MainActor 上編譯與執行，不讀取或寫入永久 CompileCache；reuse 保持原行為。JavaScriptResultSession 的操作範圍以 TaskLocal 傳遞 ephemeral，in-process runner 消費政策，跨行程 router 改呼叫 applescript.executeEphemeral。此範圍也可能使操作內的目標查詢重新編譯，不能宣稱原暖啟動效能不變；#170 需在新基底量測。

新方法採用既有 source／timing 參數與 status／output／errorKind／message 回覆形狀，日誌維持 source 遮蔽。既有 applescript.execute 預設 reuse。使用不同方法名稱，讓舊 daemon 明確以 methodNotFound 拒絕且沒有執行腳本，再走既有安全的 stateless fallback；不送一個可能被舊版忽略的 cacheable 參數。已送出而結果未知的傳輸失敗仍不得重跑。

真實 NSAppleScript 回歸：四次新 session 經 in-process cache 路徑，修正前永久項目由 1 增至 18，修正後維持 1。RPC 測試涵蓋暫時執行、原快取保留、舊方法拒絕後只退回一次，以及編譯／執行錯誤不留存。

### 導頁、取消與診斷收尾

有本次 executed／completed 證據時，bridge 最終的 targetTabChanged 也轉成 executionResultLost，再由 JSCommand 正式呼叫的 settleNavigationOrRethrow 比對 URL。執行前的 raw targetTabChanged 保留失敗，不能僅因 URL 改變便宣稱程式已跑。框架回空則重新觀察本次 metadata；狀態消失可進導頁判讀，狀態仍在但資料無效仍失敗。

操作開始、程式派送、讀取分塊及回傳／發布前檢查合作式取消。取消不能撤銷已送出的副作用；清理仍僅對本次 key 盡力執行。未配對 UTF-16 回傳帶本次 token 的明確錯誤標記，顯示無法無損傳輸，不冒充另一呼叫的資料錯誤。

導頁後的 URL 仍依既有 windowID／tab 位置觀察；關閉或重排造成同位置換分頁的限制仍由 #188 處理。本次不以分頁數等弱條件冒充身分證明。

### 驗證範圍與後續

20 筆純 AppleScript return-fixture RPC 微量測：ephemeral p50 0.575 ms／p95 0.838 ms；reuse p50 0.251 ms／p95 0.366 ms。這是受控原生 RPC／編譯路徑，沒有 Safari 或頁面操作，不能代替 Safari 指令延遲，也不證明真實暖啟動沒有回歸。#170 已同步量測前提；真實 Safari／CSP 時段仍待提供。

硬終止／cleanup 不可用後的頁面狀態累積另由 #193 追蹤。本次不掃描刪除其他呼叫的屬性；後續回收需有有效呼叫的保護證據。

最終評估確認攜帶 done 或 error，不只標示「曾執行」。error 確認後即使頁面導走、錯誤本文遺失，仍須明確失敗，不能轉成成功導頁；確認狀態與 metadata 矛盾時拒絕且不重跑。

## 2026-09-28 第二輪後的契約校正

第二輪指出兩項需要繼續修正的邊界：失敗清理／導頁觀察期間收到取消仍可能正常返回；以及 --output 導頁時保留舊檔卻回報成功。後者推翻先前「--output 導頁也視為成功」的設計，因為使用者會把舊檔當成本次結果，與 #190 的新鮮度目標矛盾。

清理後、URL 觀察前後與沒有可回傳值的正常退出前，均需檢查取消。一般清理失敗仍不遮蔽原錯誤；已取消的 task 不能被轉成成功導頁。未要求 output 的已確認成功導頁仍可正常返回；要求 --output 而沒有可寫入結果時則明確失敗、保留舊檔，說明程式已執行且未重跑。不能為了製造新檔而寫入假空結果。
