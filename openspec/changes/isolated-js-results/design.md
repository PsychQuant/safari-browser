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
