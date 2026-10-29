## 1. 模組骨架與純邏輯

- [x] 1.1 建立 Injectable SelfUpdate module：`Sources/SafariBrowser/SelfUpdate/` 定義 `ReleaseSource`、`SignatureVerifier`、`VersionProbe`、`DaemonStopper` 四個注入點與 `SelfUpdater` 協調者，`SelfUpdateCommand` 只組裝相依。驗證：`swift build` 通過，`SelfUpdaterTests` 能以假相依建立 `SelfUpdater`。
- [x] 1.2 [P] 先寫失敗測試，再實作 Version comparison（Installed version comparison）：`InstalledVersion` 依 spec 的分類表把 `BuildVersion` 字串分成 `up-to-date`／`update-available`／`ahead`／`not-comparable`。驗證：`SelfUpdateVersionTests` 涵蓋分類表全部七列，先紅後綠。
- [x] 1.3 [P] 先寫失敗測試，再實作 Release source and asset contract（Latest release lookup）：解析 `releases/latest` 的 JSON，拒絕 tag 形式不符、draft／prerelease、asset 缺少或重複、下載網址不屬於本 repo 這個 tag、超過 64 MiB／1 KiB 的回應，錯誤訊息指名不符的項目。驗證：`SelfUpdateReleaseTests` 以假回應逐一觸發每種拒絕。
- [x] 1.4 [P] 寫契約測試把 asset 名稱與 `scripts/release.sh` 綁在一起（Latest release lookup 的 release script 情境）：讀 `scripts/release.sh` 的 `BINARY_NAME` 預設值，斷言等於 `SelfUpdate` 的 binary asset 名稱、checksum asset 名稱為其加上 `.sha256`。驗證：`SelfUpdateReleaseContractTests` 綠；把常數改掉時紅。

## 2. 驗證與替換

- [x] 2.1 先寫失敗測試，再實作 Downloaded binary matches its published checksum：binary 以 `mkstemp` 寫進目標目錄的 staging 檔，`.sha256` 必須是 64 個小寫十六進位加最多一個換行，CryptoKit 算出的 SHA-256 必須相等；不符時刪 staging 檔。驗證：`SelfUpdateChecksumTests`（相符、不符、格式錯誤、大寫、多餘空白）。
- [x] 2.2 先寫失敗測試，再實作 Trust anchor is the installed designated requirement（New binary satisfies the installed designated requirement）：正式的 `SignatureVerifier` 用 `SignatureAssessment.evaluate(at:requiredEntitlement:)` 判斷已安裝與 staged 都是 Developer ID durable，檢查 hardened runtime 旗標，並以已安裝那支的 designated requirement 呼叫 `SecStaticCodeCheckValidity`。驗證：`SelfUpdateSignatureTests` 以注入結果涵蓋四種拒絕；另以真的 `SignatureAssessment` 對 `/bin/ls` 的副本斷言被拒（Self-update uses the shared assessment and atomic installation）。
- [x] 2.3 先寫失敗測試，再實作 Version probe after signature check（New binary reports the release tag）：只有簽章檢查通過後才執行 staged 的 `--version`（10 秒逾時），輸出去掉一個結尾換行後須等於 tag。驗證：`SelfUpdaterTests` 斷言簽章失敗時 probe 沒被呼叫、版本不符或逾時時更新失敗。
- [x] 2.4 先寫失敗測試，再實作 Atomic replacement with hard-link backup（Atomic replacement keeps a backup）：解析 symlink 找真實檔案、刪舊 `.previous`、`link` 備份、`rename` 覆蓋；備份失敗就不替換。驗證：`SelfUpdateReplaceTests` 在暫存目錄真跑，斷言新 inode、`.previous` 是舊位元組、symlink 未被改、一個正在執行舊檔的子行程跑完且結束碼正常。
- [x] 2.5 先寫失敗測試，確認 Failure leaves the installed binary unchanged：網路、回應形狀、大小、checksum、簽章、版本、目錄不可寫、備份失敗每一種情況下，目標的位元組與 inode 都不變、目錄裡沒有 `.safari-browser.self-update.*` 殘檔、不呼叫 sudo。驗證：`SelfUpdateFailureTests` 逐一跑每種失敗並比對 inode 與目錄列表。

## 3. 指令與輸出

- [x] 3.1 先寫失敗測試，再實作 Check output contract（Check reports without writing、Check JSON status is a closed enumeration）：`self-update --check` 只查詢與比較、不下載 binary、不寫檔；`--json` 輸出 `installed`／`latest`／`status`，status 只有五個值，`lookup-failed` 時 `latest` 為 null、帶單行 `error`、結束碼 1；`--json` 不帶 `--check` 是 usage error。驗證：`SelfUpdateCommandTests` 涵蓋五種 status 的輸出與結束碼，並斷言 `--check` 前後目標檔 inode 相同、下載介面沒被呼叫。
- [x] 3.2 先寫失敗測試，再實作 No prompt before replacing：`self-update` 不詢問；`up-to-date`／`ahead` 印原因、不下載、結束碼 0；`not-comparable` 結束碼 1 並指向 README 手動步驟。驗證：`SelfUpdateCommandTests` 斷言沒有讀 stdin、三種狀態的輸出與結束碼。
- [x] 3.3 先寫失敗測試，再實作 Daemon shutdown after replacement（Running daemons are stopped after replacement）：替換成功後列出預設 socket 目錄的 `safari-browser-<name>.sock`，對活著的送 `daemon.shutdown` 並等最多 5 秒，印 `daemon <name>: stopped` 與 `safari-browser daemon start`（非 default 附 `--name`）；停不掉只警告、結束碼仍 0。驗證：`SelfUpdateDaemonTests` 以暫存 socket 目錄與假 stopper 涵蓋 default、具名、停不掉三種情況。
- [x] 3.4 在 `Sources/SafariBrowser/SafariBrowser.swift` 註冊 `SelfUpdateCommand`，使 `safari-browser self-update --help` 列出 `--check`、`--json`。驗證：`swift run safari-browser self-update --help` 的輸出含兩個旗標；既有 `CLIVersion` 相關測試不變。

- [x] 3.5 ASSUMPTION: Self-update is not an MCP tool。規格原本沒寫，實作時發現 `MCPToolCatalog` 會把每個公開子指令自動變成 MCP tool；`safari.self-update` 會讓 MCP client 在 session 中途替換 server 自己的 binary，違背「由使用者明確執行」的決定，所以照保守做法排除（與 `mcp` 相同），並補進 spec。驗證：`MCPToolCatalogTests` 斷言沒有 path 以 `self-update` 開頭，比對用的公開子指令清單同步排除。

## 4. 規格、文件與整體驗證

- [x] 4.1 文件記錄 Self-update is non-interfering and contacts only GitHub：`CLAUDE.md` 新增一節說明 `self-update` 的干擾等級、只連 GitHub、信任錨點與替換方式；`README.md` 與 `docs/release.md` 的安裝段落加入 `self-update` 與 `--check`，寫明 v2.7.0 需先手動安裝一次、`.previous` 回滾方式、Full Disk Access 延續「預期、尚未量到」。驗證：內容審閱；`grep -n 'self-update' README.md docs/release.md CLAUDE.md` 各有命中。
- [x] 4.2 `CHANGELOG.md` 的 `## Unreleased` 加入 `self-update` 條目。驗證：內容審閱。
- [x] 4.3 全部測試與規格驗證通過：`make test` 全綠（失敗的既有測試要在報告中具名列出），`spectra validate add-self-update-command` 與 `spectra analyze add-self-update-command` 沒有 Critical／Warning。驗證：貼出兩個指令的輸出摘要。
