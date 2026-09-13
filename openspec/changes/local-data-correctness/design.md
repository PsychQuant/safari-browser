## Context
#111/#112/#113 共用 storage 邊界；#115/#116/#117/#120 共用 parser/query 行為；#114 涵蓋四個 formatRow 及後續 dialog renderer addenda。
## Goals / Non-Goals
消除新磁碟資料複本，比僅 chmod 更能處理同 UID 威脅與 signal 遺留。不得宣稱檔案 mode 能隔離同 UID。既有歷史殘留檔不憑 prefix 自動刪除，避免誤刪仍在使用的複本。無新 FDA 授權、無寫入來源資料內容，無改已安裝binary。
## Decisions
1. SQLiteReader.Database owns connection + sourceURL。withDatabase(at:body:) 開唯讀fixture/source；withSnapshot(at:timeout:afterStep:body:) 以5秒單調期限、SQLite backup到 :memory:，設定來源一致read transaction、匹配page_size，目的temp_store=MEMORY、完成後query_only。SQLite可能維護其正常WAL共享索引/鎖；不執行來源寫入SQL。Plist以POSIX open/read直接讀Data，不複製檔案。非sqlite錯誤保留errno。原withCopy API退休。
2. APIs固定：SafariDataStore.withDatabaseSnapshot(sourceURL:timeout:body:)；SafariDataStore.readPlist(sourceURL:)；SQLiteReader.withDatabase(at:body:)；SQLiteReader.query(in:sql:bindings:maxResults:rowMapper:)；舊query(at:sql:rowMapper:)保留並新增可選bindings/maxResults。Database.sourceURL供解析診斷。Mapper可throw，回nil表示篩選。取到maxResults個非nil後立即finalize，不要求再step DONE；未滿時任何SQLite錯誤仍失敗，另計rowsStepped。
3. Parser在filter前區分valid/invalid。全非空但無有效entry→parse error；部分invalid→stderr含數量/index/field且保留有效列；正常無match不是schema錯誤。Optional date/title/device/count用nil或既有明示unknown，不能捏造時間；HistoryVisit.visitTime改Date?。History以bindings下推since；LIMIT由maxResults計已接受列數，避免SQL LIMIT把壞列算入額度；search以Swift Unicode lowercased/contains處理。
4. Command.run()委派可注入sourceURL的run(sourceURL:)供真實command-level測試，無新增production env覆寫。四parser保留URL fixture入口，新增Data或Database入口供記憶體snapshot。測試使用ArgumentParser.exitCode(for:)與實際run輸出確認missing=0、FDA!=0與stdout/stderr分離。
5. 共用text boundary跳脫C0/DEL/C1/Unicode行分隔與bidi、backslash/quote；local field內的分隔符要跳脫，四formatRow均套用。Dialog訊息/按鈕與Errors相關分支共用helper，單值256字元上限，截斷必標示。Raw matching與JSON資料不改。
6. Bookmarks search僅title/URL、不改cloud/downloadflags；search與folder filter皆需符合。
## Task ownership
Root：SafariDataStore、SQLiteReader、storage/SQLite tests、Errors的新I/O case。Parser agent：四Commands除formatRow、parser/query/command tests、SchemaDiagnostics。Formatter agent：四Commands的formatRow、LocalDataOutput、BlockingDialogGate renderer、Errors的dialog分支、texttests。History date?由parser改型別、formatter處理formatRow顯示。
## R1 re-baseline: checkpointed WAL without sidecars
實測正常可寫目錄也會在本機SQLite回CANTOPEN/errno3，不能只改錯誤字樣而失去Safari關閉後的讀取能力。新增受限fallback：只在初始化CANTOPEN後，在APFS/HFS上用OFD exclusive lease覆蓋SQLite標準locking bytes；鎖需要O_RDWR描述符，但不執行任何寫入。持鎖後驗SQLite WAL header、WAL/journal缺失或為空，再以持有fd的immutable唯讀URI進行相同memory backup。其他SQLite寫入者被排除，lease在consumer前關閉；source資料內容與sidecars都不由fallback改寫。非空WAL、無法鎖定、只讀來源無法取得lease或非支援檔案系統均明確失敗，不退回猜測。
SQLite後續ENOENT不再當主檔不存在：只有初次POSIX source open有此權限。SQLite錯誤保留operation/code/errno；附件檔失敗不得exit0。
測試：正常/readonly directory的無sidecar WAL讀取、source內容不變、OFD與SQLite POSIX writer互斥、consumer前釋鎖，以及backup中SIGINT/TERM/KILL後writer可恢復。普通readonly交易/backup路徑維持優先，不對活動WAL使用immutable。
參考：https://sqlite.org/uri.html 、https://sqlite.org/lockingv3.html 。lease只針對使用本機POSIX協定的SQLite操作，不宣稱保護任意忽略鎖的原始檔案寫入者。

## Risks / Trade-offs
記憶體峰值增加；NOMEM/timeout明確失敗。ReadonlySQLite會參與讀鎖和共享索引，這是Backup API的一致性成本。舊資料複本不自動sweep，新的流程不再產生它們，signal不會遺留新複本。Readtransaction與page size、busy、WAL checkpoint需合成fixture驗證。
## Verification
TDD重現錯誤映射、跨checkpoint不一致、limit後corruption與ANSI注入；完整parserfixtures/stream/exitcode，SQLite memory storage invariants，strict/full suites與獨立IDD驗證。
## Sources
https://sqlite.org/backup.html
https://sqlite.org/wal.html
