## Summary

#202 以可選的 daemon request 上限宣告，讓 client 在本筆 RPC 送出任何 byte 前提供明確超量診斷，保留舊 peer 與已送出後不重播的契約。

## Motivation

自有 peer 宣告 64 bytes 上限時，現有 client 仍送出 166 bytes（含 LF）並取得成功，重現 2 項斷言失敗。缺欄位的 legacy peer 測試仍成功。現有程式只解讀版本、編碼 envelope 後直接 write；版本預設值可為 source／unknown，不能據此推論 request 限制。

## Proposed Solution

既有 v2 handshake 的 protocol object 新增可選十進位字串 maxRequestLineBytes；新 server 宣告實際 reader limit（正式預設 128 MiB），舊 client 仍可忽略欄位。新 client 驗證 typed handshake；缺欄位保留 legacy 行為，present 但無效的值拒絕為握手錯誤。

以完整編碼 JSON 的 Data.count（不含 LF）對比宣告上限。超量拋專用本地錯誤，只含數字與固定指引、不 fallback；部分送出後仍是 outcome unknown、不重播。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- persistent-daemon：可選 request-line 上限宣告、嚴格解析、送出前大小拒絕與新舊相容性。

## Impact

DaemonProtocol.swift、DaemonClient.swift、DaemonServer.swift；protocol／preflight／request bounds 與 Tests/daemon-peer-disconnect-test.py 的 exec CLI 測試；CLAUDE.md、CHANGELOG.md 與 persistent-daemon delta spec。

## Evidence-driven revision

初版 JSON number 宣告在實測中無法嚴格拒絕小數：JSONDecoder 將 9007199254740993.5 解成 9007199254740993。尚未發布的新欄位改為 ASCII 十進位正整數字串（例如 "1024"），避免浮點精度或另寫 JSON parser。初版 number 方案與失敗證據保留在診斷紀錄，後續實作／測試以本次修正為準。
