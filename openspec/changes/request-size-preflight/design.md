## Context

#194 在 server 設定整筆 request JSON 行上限，但 client 只讀版本，無法分辨 peer 的限制。版本 metadata 可缺省為 source／unknown，因此版本相同不代表支援上限。基底 37dd598 的自有 socket 測試已重現：宣告 64 bytes，client 仍傳送 166 bytes（含 LF）。

## Goals / Non-Goals

Goals：新 daemon 宣告實際 reader limit；新 client 以完整 JSON envelope 的編碼 bytes 在本筆 RPC 零送出時拒絕超量；保留新舊互通、版本比對及送出後不重播。

Non-Goals：不變更 server reader 的 128 MiB 預設與拒絕政策、不新增自動 stateless fallback、不保證整體行程記憶體上限、不變更 caller 身分驗證、不處理 #205 日誌語意。

## Decisions

### 可選上限宣告與單次型別解析

在 protocol object 新增 maxRequestLineBytes，值為 ASCII 十進位正整數字串。Instance 握手必須傳入實際 requestLineLimit；encodeHandshake 的可選參數預設 nil，讓舊 fixture 可明確模擬 legacy peer。decodeHandshake 以同一次 JSONDecoder 取得 version 與上限，避免以兩個 decoder 對重複欄位取得不同解讀。缺欄位為 nil；present 值須為字串，字元形式 [1-9][0-9]* 且可轉為 Int；null、bool、所有 JSON number、空字串、符號、空白、前導零、小數、指數、非 ASCII 數字及溢位皆拒絕。原 decodeHandshakeVersion 保留，驗證舊 decoder 忽略新欄位。

這是一般限制 metadata，並非授權 capability 或 caller 身分握手；不增加 round trip。拒絕從版本推估限制及強制所有舊 peer 套用新 client 的預設上限，避免版本 metadata 不完整時誤判。

### 完整編碼後的零送出拒絕

DaemonClient.exchange 在既有握手、版本檢查後，照原方式編碼 method／params／requestId。比較 Data.count 與宣告值，尚未加 LF、更未呼叫 writeFrame。等於上限可通過；大於上限拋 requestTooLarge(encodedBytes:limit:)。不能用原始 params 長度、Swift 字元數或估算值替代，JSON escaping、UTF-8 與 envelope 都算入。

### 私密診斷與既有不重播語意

專用錯誤只含 encodedBytes、limit 與固定縮小請求指引，清楚說明本筆 RPC 尚未送出任何 request byte；不能聲稱整條命令沒有執行，因先前 RPC 可能已完成。fallbackReason 為 nil。缺欄位時照原流程送出，無效上限走既有 invalid handshake／protocolError。已寫入部分 bytes 後失敗仍為 requestOutcomeUnknown，不允許 router 改走 stateless。server 持續獨立限制輸入，不能依賴 client 自律。

## Implementation Contract

- Wire：既有 v2 protocol.version 旁新增可選 protocol.maxRequestLineBytes，單位為完整 UTF-8 JSON 行 bytes、不含 LF；正式 server 宣告 "134217728"，測試 Instance 宣告設定值。
- API：DaemonProtocol.Handshake 含 version 與可選 maxRequestLineBytes；decodeHandshake 回傳有效物件或 nil。encodeHandshake 支援可選上限。舊 version-only decoder 不修改。
- Client：版本相符後先編碼，再比較；超量零寫入、handler 次數零、router fallback 次數零。邊界相等正常送出並執行一次。
- 驗收：codec scalar 表格、新舊 client／server handshake、精確邊界、escaping／Unicode／envelope overhead、自有 peer 實際收到 bytes、實際 server handler 與 router fallback counters，以及 legacy／誤報上限 peer 的送出後 unknown 分類。
- 變更範圍：DaemonProtocol／DaemonClient／DaemonServer、對應測試、CLAUDE.md／CHANGELOG.md 與 persistent-daemon 規格。完整非 GUI 測試及六方審查後才能標 verified；本題不需要 Safari 前景操作。

## Risks / Trade-offs

- [舊 peer 無 metadata] → 無法預檢，保留既有送出後拒絕行為，不做無證據推論。
- [惡意或失準宣告] → server 仍自行限制；client 送出後錯誤維持 unknown；本 metadata 不是安全授權機制。
- [編碼本身需配置記憶體] → 本題只避免已知超量的傳送，不宣稱避免編碼配置或全行程上限。
- [typed decoder 更嚴格] → 有效 v2 fixture 全部維持，非 JSON bool 的 dirty 欄位不屬於有效 typed version；舊 version-only API 不改。

## Migration Plan

以可選欄位漸進部署。新 server + 舊 client 忽略宣告；新 client + 舊 server 保留舊路徑；兩者皆新才預檢。回退 client 或 server 都不需重寫資料。文件明載未知上限與已送出後的界線。

## Open Questions

無阻擋問題。初版 number 宣告已被實測反證：JSONDecoder 將 9007199254740993.5 接受為 Int。以尚未發布欄位的十進位字串表示取代該方案，維持單一 JSONDecoder 解讀，透過 UTF-8 字元檢查及 Int 的有界轉換避免數值捨入。
