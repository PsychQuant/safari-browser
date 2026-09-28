## 1. 協定與預檢

- [x] 1.1 實作「可選上限宣告與單次型別解析」，履行 Daemon advertises an optional request line limit 與 Client validates request limit advertisements：DaemonProtocol 加可選編碼／typed decoder、Instance 宣告實際 reader limit；以 codec 十進位字串／無效 scalar／整數精度／legacy decoder 及真實 server 自訂與預設值測試驗證。
- [x] 1.2 實作「完整編碼後的零送出拒絕」，履行 Client rejects known oversize requests before transmission：DaemonClient 在加 LF 與 writeFrame 前比對完整 envelope，加入專用錯誤；原始 RED 轉 GREEN，精確邊界、escaping／Unicode／envelope bytes、handler counter 及私密錯誤內容測試驗證。

## 2. 相容性與驗證

- [x] 2.1 實作並驗證「私密診斷與既有不重播語意」及 Legacy request and post-send semantics remain compatible：router 遇本地超量不 fallback、legacy 缺欄位仍送出、誤報上限或送出中斷仍 unknown；以 Tests/daemon-peer-disconnect-test.py 的空 exec CLI fixture 驗證專用回退路徑，保留 DaemonRequestBoundsTests 與 DaemonTransportDeadlineTests 的 server 獨立限制、部分送出、不重播測試。
- [x] 2.2 更新 CLAUDE.md／CHANGELOG.md 說明 request-line 宣告、新舊相容與零送出界線；執行 daemon 聚焦測試、關鍵預檢 guard 變異及 make test-all，確認文件與實測一致。
- [x] 2.3 完成六方審查與修正、spectra analyze／validate，全部驗收通過後同步規格與歸檔；PR 與各提交引用 #202，依最終快照留下完整證據，issue 保留 OPEN。
