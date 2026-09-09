## 1. 獨立底層修正

- [x] [P] 1.1 單調時鐘期限與結果未知：實作 Absolute request deadline；以 fake socket peer 驗證 handshake／trickle／EOF／write 共用期限，無效 timeout 被拒，完整送出後不接受無法對應 requestId 的回覆。Refs #130。
- [x] [P] 1.2 主執行緒編譯快取：實作 Cached scripts execute on the main thread，保留 source 快取；以獨立 process 的 return→delay→重用序列驗證不掛住且 cacheCount=2。Refs #130。
- [x] [P] 1.3 子行程同時讀取兩條 pipe：實作 Exec subprocess stderr delivery；以同時寫超過 128 KiB 的 fixture 驗證無死鎖、成功與失敗均轉發 stderr。Refs #136。

## 2. 請求整合

- [x] 2.1 整合 Silent fallback to stateless path on daemon failure 與 Exec unknown outcomes are not replayed；假 server 收到完整 mutation 後斷線，斷言 fallback=0，連線拒絕仍 fallback。Refs #130。
- [x] 2.2 每次請求的執行環境與警告傳遞：實作 Request diagnostics remain visible 及 Exec request context；交錯與連續請求各自取得 warning，成功與失敗 envelope 均回傳，cached runner 不開內部 socket，stdout 保持 JSON。Refs #136。

## 3. 驗證與交付

- [x] 3.1 完整 swift test、make test-all 與 Safari dialog／exec fixture 驗證兩條路徑，保留跳過原因；更新 README／CHANGELOG 的新期限、結果未知與 diagnostics 契約，經 spectra analyze／validate 檢查。Refs #130, #136。
- [ ] 3.2 凍結提交並完成獨立交叉驗證，逐 issue 同步 checklist／Current Status，建立承接 #126 的 PR；不 merge、不 close。Refs #130, #136。
