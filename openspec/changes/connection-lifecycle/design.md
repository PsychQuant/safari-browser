## Context

#199 的三個真實 socket 重現均失敗：停止後仍 dispatch 一次、無輸入 client 未收到 EOF、已結束三條連線仍追蹤三個 task。觀察接縫只記錄 read 前／transport 結束與目前追蹤數，尚未改修復邏輯。#198 已把 listener 與 shutdown 權限綁定世代；本題處理一般已接納連線。

## Goals / Non-Goals

**Goals:** 撤銷連線後禁止新 dispatch、有界完成 transport 等待、完成工作即退休、close 與 I/O 不使用重用後的 fd、回覆不互相穿插，保留既有 wire／不重播政策。

**Non-Goals:** 不增加正常 RPC 執行期限、不重播工作、不重設整個 worker pool／編譯快取、不宣稱已開始的不可中斷副作用已撤銷；不設定整體行程記憶體上限，不用未驗證的 Data 容量假設重寫 framing。

## Decisions

### 單一描述元 owner 與非同步 nonblocking I/O

新增 DaemonConnection，採唯一 UUID 與短鎖保護 open/revoked/closed 狀態和 fd。adopt 呼叫即移交 fd；設定 O_NONBLOCK、FD_CLOEXEC、SO_NOSIGPIPE，失敗也由 owner 關閉。read/write、shutdown/close 都在同一把鎖中檢查狀態並執行單次 nonblocking syscall，不把裸 fd 傳給跨 await 的工作。撤銷原子地標記、shutdown 並 close 一次，後續操作只看 revoked 狀態，不再使用舊 fd 數值。

EAGAIN 在鎖外等候原生 DispatchSourceRead／Write 就緒通知；EINTR 檢查取消並 yield 後重試。初版固定 5 ms 等待使自有 warm RPC 中位數由 0.124 ms 退步至 6.83 ms；原生通知版量到 0.140 ms（同一 fixture、各 40 次，非普遍效能保證）。

每個 readiness source 使用私有 F_DUPFD_CLOEXEC 副本，只做通知、不做 stream read/write。原 fd 的 revoke 仍在短鎖內 shutdown/close，再在鎖外取消並喚醒等待者；監控副本僅由 source cancel handler 關閉，避免取消中的 callback 碰到重用 fd。事件／逾時／撤銷只完成一次，source handler 弱引用 registration，避免循環持有。依 [Apple cancellation handler 契約](https://developer.apple.com/documentation/dispatch/dispatch_source_set_cancel_handler)，不能先關 source 所監控的 fd 再等 handler 結束。這會在等待期間多使用一個 fd；副本建立失敗明確回報，不無界重試。

Environment.wait 只保留為可控制 syscall／clock fixture 的替代等待；正式預設為原生通知。不能在 cooperative pool 上用無 await 的 poll 迴圈持續等待，也不能持鎖等待 peer。一般讀寫不新增整筆 RPC deadline；stop 的撤銷與 task cancellation 會中止等待。每次 I/O 單次處理有界區塊，較長的進度迴圈定期 yield。

比較方案：直接從 stop 關閉裸 fd 會碰到重用競態；持鎖 blocking read 會使 stop 卡住；blocking I/O 加 lease 的方案仍需額外喚醒／等待協定。nonblocking syscall 的短鎖讓 I/O 與 close 的線性化點可直接驗證。

### 連線登記與 dispatch 接納

Instance 改用 Connection ID 的登記集合，保存 owner、transport task 與世代。task 建立／登記在同一個 actor turn；transport 結束以 ID／世代退休，停止先撤銷全部 owner 再取消 transport，不等待 read loop 排程。完成舊工作的通知不可用 fd 數值清除新項目。transport 診斷在同一 actor turn 比對連線世代、準備原 logging-session emission 後才退休，後續 writer 不消耗新 session 額度。stop 移除 active registry 不代表 join 已在解析的 transport task；其有界解析離開後仍須走拒絕與完成通知。

讀取／解析後，actor 在同一個 turn 檢查連線仍 active、世代符合且未取消，再接納 handler task。讀取期間撤銷、EOF 的部分行或合併多行，都必須經過此守衛；只有真 EOF 的合法最後一行保留 #194 相容性，取消不是 EOF。handler 已接納後的副作用不能被宣稱沒有發生。

### 可取消完成等待與未完成工作追蹤

新增 DaemonRequestCompletion<Value: Sendable>，以短鎖加 checked continuation 仲裁 result／cancellation，只恢復一次。等待者取消時立即退出；之後到達的結果不儲存、不回覆。不可使用會在 scope 結束時等待不合作子工作的 task group／async let。

handler 採可個別取消的 unstructured task，傳入已解析的 Sendable request 資料和 DaemonRequestContext／timing 設定。transport 取消只中止其等待、釋放 reader／frame；正在執行的 handler 保留獨立的未完成登記，直到真正結束才退休。已完成 operation handle 不保留，晚到完成以 request ID／connection ID 比對。測試分別觀察 active transports 與 unfinished operations，不能把 transport=0 當成所有副作用已停止。

### 單一回覆與 shutdown 等待預算

每個請求使用自己的 DaemonRequestCompletion<Response> 作為 reply 仲裁；正常結果與 cancelled 回覆只有第一個 complete 能取得單次 frame 寫入權，唯一 transport 消費者負責寫入。已開始寫正常結果時，不能在其中插入 cancellation JSON。若撤銷使部分回覆中斷，client 沿用結果未知／不重播。

lifecycle dispatch 產生 response 與所屬世代的 after-reply shutdown plan。對 shutdown caller 先嘗試 ACK 寫入，總預算 250 ms；即使 peer 不讀或已斷線，仍繼續停止。接著用另一個所有 in-flight cancellation 回覆共用的 250 ms 絕對期限，不逐 client 重設；只有成功選定 cancelled 回覆的 plan 才等待該 request 的 replyFinished 完成觀察，等待也受同一期限控制，不能 join 非合作 handler；耗盡就停止額外回覆並撤銷連線。正常 shutdown 的既有 cancelled code／requestId 保留。process host 原有五秒退出 watchdog 保留；不把 best-effort 取消訊息當成副作用回滾保證。

快照保存 Connection／request 身分，不保存稍後直接 write 的裸 fd。#198 admission-captured shutdown capability 與世代守衛保留；過期 shutdown 不能取得新 Run 的停止權限。

### Reader 與記憶體證據

共用 #194 的 framing 核心（128 MiB 行上限、8 KiB 分段、只掃新增 bytes、保留合併行、EINTR／EOF 分類），新增 async I/O adapter，不建立兩份分岔 parser。transport 結束即釋放其 reader、frame 與已完成 task handle；尚在執行的 handler 只保留必要的 request 資料直到返回。

以自有大型 request 連線反覆開關，記錄追蹤數、完成／釋放事件與實際 process footprint；量測只描述測試配置，不能把邏輯 pending byte 數當成 Foundation capacity，不能宣稱 Data(pending) 一定壓縮配置。先取得實證，再決定是否需要額外容量處置。

## Implementation Contract

無效 JSON／非 object frame 的日誌保留既有安全 byte-count marker，full-log 模式也不保留整個壞 frame；正常有效 params 的 full-log 選項不變。

新增內部 DaemonConnection（採用 fd、撤銷、async 讀寫、單次 request reply claim）與 DaemonRequestCompletion（單次 result/cancel 完成）介面；兩者 Sendable 契約由鎖保護。CLI 旗標、RPC request schema、既有成功與錯誤 envelope 不新增欄位。

停止前已接納但尚未 dispatch 的請求不得啟動新 handler；已開始的工作只提出合作取消，不重播、不宣稱副作用消失。client 在完整 cancelled envelope 時保留 domain error；讀到不完整回覆仍是結果未知。shutdown ACK／取消寫入受上述總期限控制，避免不讀資料的 client 阻擋停止。

驗收包含三個原始 RED、read/write 等待撤銷、stop/start、同 fd 數值重用、完成 task 自動退休、多 request 回覆競爭、coalesced／EOF／超量 framing、非合作 handler 與舊完成的隔離、真實 daemon lifecycle／client no-replay。控制排程的自有 fixture 使用兩秒完成觀察界線；這不是任意負載與核心停頓下的硬牆鐘保證。

## Risks / Trade-offs

- [I/O 變 nonblocking 後 spin／延遲] 原生就緒通知、取消及定期 yield；測試 EAGAIN／EINTR、monitor 退休與正常 warm request 延遲。
- [reply 仲裁錯誤] request token 決定一次完整 frame；部分 frame 不能改寫成另一種結果。
- [不合作工作仍存活] transport 必須先完成，operation 如實追蹤直到返回，不重設共享 cache 或強殺嵌入式行程。
- [世代與 fd 重用] 所有 I/O 都經 owner 短鎖，registry 與完成通知按 UUID，不以 fd 充當身分。
- [量測誤解] footprint 與邏輯所有權分開報告，不推出未實測的固定記憶體倍數。

## Migration Plan

基底已整合 #198 的主分支 `7a63179`；本 change 只修改 connection 層。#198 原本可在舊 socket 回傳 cancelled 的延遲 shutdown 情境，因本題真正撤銷 transport，更新為舊連線關閉／未完整回覆維持結果未知且不重播；shutdown capability 與新 Run 保護保留。若回退，恢復原本 blocking read 與 task 陣列行為，#198 listener／Run 保護仍保留。合併前執行完整測試、六方確認與規格同步歸檔。

## Open Questions

沒有需要使用者決定的產品政策；實體配置保留量是待量測的實作證據，不預先假定結果。
