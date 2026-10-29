## Context

`safari-browser` 從 v2.7.0 起以 `make release-signed`（`scripts/release.sh`）發 release：Universal、Developer ID 簽章、hardened runtime、secure timestamp、Apple 公證，產物是裸執行檔 `safari-browser` 與只含雜湊一行的 `safari-browser.sha256`（#280）。已安裝的 binary 沒有更新路徑，plugin hook 依 #280 的決定維持離線、不替換 binary。

現有可重用的程式：

- `SignatureAssessment.evaluate(at:requiredEntitlement:)`：runtime 與 install guard 共用的唯一簽章判斷，回傳 `durable(shape:requirement:)`、`adHoc` 等（`install-signature-contract` 的 *Shared signature assessment*）。
- `MCPWorkerContext.executableURL()`：以 `_NSGetExecutablePath` 取得執行檔路徑。
- `BuildVersion.value`：`git describe --tags --match 'v[0-9]*' --always --dirty` 的結果，或 `unknown`（`cli-version` spec）。
- `DaemonClient.socketPath(dir:name:)`、`DaemonServeLoop.isDaemonAlive`、`DaemonStopCommand` 的關閉流程（送 `daemon.shutdown`、最多等 5 秒）。
- `SaveImageCommand` 的 ephemeral `URLSession` 用法。

維護者已定案的兩點（#314 Clarity Surface）：替換前不詢問；替換後停掉所有仍在執行的 daemon 並印出重開指令。

## Goals / Non-Goals

**Goals:**

- 一個指令完成「下載 → 驗證 → 原子替換」，驗證強度不低於 README 的手動步驟。
- `--check --json` 提供 hook 可判讀的封閉列舉結果。
- 任何失敗都不改變已安裝的 binary。
- 每一道守衛都能在不連網、不碰使用者真實安裝的情況下測試。

**Non-Goals:**

- hook 端的提示與自動更新（psychquant-claude-plugins#155）。
- 降級、指定版本、prerelease。
- sudo、寫入使用者無權寫入的目錄。
- 從命令列確認公證（#280 量到 `spctl`、`syspolicy_check`、`codesign --check-notarization` 對已公證的裸 Mach-O 都回答未公證）。

## Decisions

### Injectable SelfUpdate module

邏輯放在 `Sources/SafariBrowser/SelfUpdate/`，`SelfUpdateCommand` 只負責解析參數、組裝相依、印出結果。相依以 protocol 或 closure 注入：

- `ReleaseSource`：查 latest release、下載 asset。
- `SignatureVerifier`：已安裝與新版的身分檢查。
- `VersionProbe`：執行候選 binary 的 `--version`。
- `DaemonStopper`：列出並停掉 daemon。

正式實作使用 URLSession、Security framework、`Process`；測試使用假的實作。

替代方案：全部寫在指令裡。這樣就無法不連網地測試每一道守衛，所以不採用。

### Version comparison

`InstalledVersion` 解析 `BuildVersion.value`，規則是 `^v(\d+)\.(\d+)\.(\d+)(-(\d+)-g[0-9a-f]+)?(-dirty)?$`：

- 符合時，基準版本是三個數字，`hasSuffix` 表示有 `-N-g<hash>` 或 `-dirty`。
- 不符合時（裸 hash、`unknown`），結果是 `notComparable`。

與 latest tag `vA.B.C` 比較的結果：

- `latest > base` → `updateAvailable`
- `latest == base` 且沒有 suffix → `upToDate`
- `latest == base` 且有 suffix，或 `latest < base` → `ahead`

開發版因此永遠不會被「更新」成同一個或較舊的 release。

替代方案：直接比字串。開發版會被判為不同，因而被降級，所以不採用。

### Release source and asset contract

查詢一律走 `GET https://api.github.com/repos/PsychQuant/safari-browser/releases/latest`：

- header 帶 `Accept: application/vnd.github+json` 與 `User-Agent: safari-browser/<version>`，逾時 15 秒。
- 回應的 `tag_name` 必須符合 `^v\d+\.\d+\.\d+$`，`draft` 與 `prerelease` 都必須是 false。

Asset 規則：

- 名為 `safari-browser` 與 `safari-browser.sha256` 的 asset 必須各恰好一個。
- 兩者的 `browser_download_url` 都必須以 `https://github.com/PsychQuant/safari-browser/releases/download/<tag>/` 開頭。
- 上限：binary 64 MiB、checksum 檔 1 KiB。

`.sha256` 內容必須是 64 個小寫十六進位字元，後面最多一個換行。

Asset 名稱與 `scripts/release.sh` 是跨元件契約，由一個測試讀取 `scripts/release.sh` 的 `BINARY_NAME`，與 `SelfUpdate` 的常數比對。

### Trust anchor is the installed designated requirement

信任檢查依序要求以下三點：

1. 已安裝那支的 `SignatureAssessment.evaluate(at:requiredEntitlement: "com.apple.security.automation.apple-events")` 是 `durable(shape: "Developer ID", …)`。否則拒絕，說明沒有可比對的身分，並指向 README 的手動步驟。
2. 新版的同一個判斷也是 `durable(shape: "Developer ID", …)`，而且簽章旗標含 hardened runtime（`kSecCodeSignatureRuntime`）。
3. 以已安裝那支的 designated requirement 呼叫 `SecStaticCodeCheckValidity(新版, kSecCSCheckAllArchitectures, installedDR)`，結果必須是 `errSecSuccess`。

designated requirement 涵蓋 identifier、Developer ID 憑證鏈與 team OU，TCC 也是用它判斷 Full Disk Access 授權能否沿用。所以「信任新版」與「授權預期延續」是同一個檢查。

替代方案：
- 只比 team：比 designated requirement 寬，也不保證授權延續，所以不採用。
- 以 release notes 的 team ID 為準：它與 binary 走同一條通道（#310），所以不採用。
- 呼叫 `codesign` 子行程：違反 shared assessment 的規定，所以不採用。

### Atomic replacement with hard-link backup

步驟：

1. 被替換的是執行檔路徑解析 symlink 後的真實檔案，symlink 本身不動。
2. checksum 在記憶體裡比對通過後，staging 檔才以 `mkstemp` 在目標檔的同一個目錄建立（名稱 `.safari-browser.self-update.XXXXXX`，0600），寫入並 `fsync`；簽章驗證通過後才改成 0755（verify round 1）。
3. 驗證全部通過後，把目標 hard link 到一個新的暫存名稱，再 `rename` 蓋過 `<target>.previous`，最後刪掉暫存名稱（`.previous` 原本就是目標的 link 時 `rename` 不做事，暫存名稱會留下，round 2）。舊的 `.previous` 只在新備份存在後才被換掉；備份失敗就中止，不替換（round 1）。
4. 最後 `rename(staging, target)`。

這樣任何時刻 `target` 都存在。正在執行的舊行程保有舊 inode，新路徑是新 inode（`install-signature-contract` 的 *Atomic installation evidence*）。任何一步失敗都刪除 staging 檔。

替代方案：先 `rename(target → previous)` 再 `rename(staging → target)`。兩步之間 `target` 不存在，所以不採用。

### One update at a time from the installed binary

（verify round 1 加入）目標目錄裡的 `.safari-browser.self-update-lock` 以 `flock(LOCK_EX|LOCK_NB)` 互斥，持有到結束；持有中再跑一次會直接失敗。持鎖後比對執行中行程的 code hash 與目標檔：不同代表另一次更新已經換掉它，這次若繼續，會把 `.previous` 變成新版的副本，所以拒絕。替代方案：在 commit 前重新比對 inode。但沒有鎖時兩次執行仍會交錯，所以不採用。

### Interrupted runs leave nothing behind for long

（verify round 1 加入）`defer` 在 signal、crash、斷電時不會執行，staging 檔會留下。每次執行在持鎖後先清掉 `.safari-browser.self-update.`／`.safari-browser.self-update-prev.` 加六個英數字、屬於使用者的一般檔案。下載先在記憶體裡比對 checksum，再以 0600 寫入，簽章通過才改成 0755，所以殘檔至少不是未驗證的可執行檔。清理在下一次「會替換」的執行裡做（`--check`、已是最新、`ahead` 都不會走到持鎖那一步）。替代方案：安裝 SIGINT／SIGTERM handler。但它擋不住 SIGKILL 與斷電，下一次執行時清理才能涵蓋所有情況。

### Version probe after signature check

候選 binary 的 `--version` 在簽章檢查**之後**才執行。這樣被執行的只會是與已安裝那支同一身分簽出的程式碼。

- 10 秒的期限同時涵蓋執行與讀取輸出（round 1）。
- 輸出在執行中就讀，上限 4096 bytes。
- 程式結束後，pipe 關閉或等 0.5 秒就用已讀到的內容，持有 pipe 的孫行程卡不住更新。
- 不使用 `waitUntilExit()`：它會跑 run loop，在 cooperative thread 上會一直卡住（測試實際卡住過）。

stdout 去掉一個結尾換行後必須逐字等於 tag。

### Daemon shutdown after replacement

替換成功後，在 daemon 的預設 socket 目錄（`DaemonPaths.resolveSocketDir` 的預設值）列出 `safari-browser-<name>.sock`。對 `isDaemonAlive` 為真的每一個，沿用 `DaemonStopCommand` 的流程送 `daemon.shutdown` 並等待最多 5 秒。

每停掉一個就印 `daemon <name>: stopped`，最後印出 `safari-browser daemon start`；非 default 的 namespace 附 `--name <name>`。停不掉時只警告，結束碼仍為 0，因為替換已經完成。

### Check output contract

`self-update --check` 印出人讀的一行；`--json` 印出一個物件：

```json
{"installed":"v2.7.0","latest":"v2.8.0","status":"update-available"}
```

`status` 是封閉列舉，只有五個值：`up-to-date`、`update-available`、`ahead`、`not-comparable`、`lookup-failed`。

- `lookup-failed` 時 `latest` 是 `null`，另有 `error` 欄位（一行、無控制字元），結束碼 1。
- 其餘四種的結束碼都是 0。

`self-update`（不帶 `--check`）的結果：

| 狀況 | 結束碼 | 輸出 |
|---|---|---|
| 替換成功 | 0 | 舊版與新版 |
| `up-to-date` | 0 | 已是最新 |
| `ahead` | 0 | 說明已安裝的建置比最新 release 新、不替換 |
| `not-comparable` | 1 | 說明無法比較，指向手動步驟 |
| 任何驗證失敗或 I/O 錯誤 | 1 | 失敗原因 |

替換前不詢問。

## Implementation Contract

- **介面**
  - 新子指令 `self-update`，旗標 `--check`、`--json`；`--json` 只與 `--check` 一起使用，否則是 usage error。
  - 只用 Foundation、Security、CryptoKit，不新增套件相依。
- **可觀察行為**
  - `--check` 不寫任何檔案、不下載 binary。
  - `self-update` 只有在所有驗證都通過後，已安裝的路徑才會變成新版；失敗時路徑上的位元組與 inode 都不變，staging 檔不殘留。
- **錯誤模式**：以下每一種都有具名、可讀的訊息，結束碼 1。
  - 網路逾時或失敗
  - API 回應形狀不符
  - tag 形式不符
  - asset 缺少或重複
  - 下載網址不屬於本 repo 的這個 tag
  - 超過大小上限
  - checksum 格式不符或不相符
  - 已安裝那支不是 Developer ID
  - 新版不是 Developer ID、缺 entitlement、缺 hardened runtime
  - 新版不滿足已安裝那支的 designated requirement
  - 自報版本不符或逾時
  - 目錄寫不進去
  - 備份失敗
- **驗收**
  - 每一種錯誤模式都有 XCTest 行為測試，使用注入的假相依，不連網。
  - 原子替換以暫存目錄真跑（含正在執行的舊 inode 不受影響）。
  - 一個測試以真的 `SignatureAssessment` 對非 Developer ID 的檔案（`/bin/ls` 的副本）確認會被拒絕。
  - 一個測試把 asset 名稱與 `scripts/release.sh` 綁在一起。
  - `make test` 全綠。
- **範圍外**：hook、背景更新、降級、prerelease、sudo、公證確認。

## Risks / Trade-offs

- [Full Disk Access 延續仍未觀察過] → 文件寫明「預期延續、尚未量到」；第一次真實更新後量測並更新文件。
- [與 release 流程耦合：asset 名稱、`.sha256` 格式、tag 形式] → 契約測試讀 `scripts/release.sh`；`.sha256` 格式由 release-test 既有斷言固定。
- [GitHub 未認證 rate limit 每小時 60 次] → `lookup-failed` 時明確回報；hook 端每日一次（#155）。
- [轉址到其他主機下載] → 只接受 API 回報、且網址前綴屬於本 repo 這個 tag 的 asset；URLSession 跟隨 GitHub 自己的 CDN 轉址，最後的位元組由 checksum 與簽章把關。
- [checksum 與 binary 走同一條通道] → checksum 只防傳輸損壞，真正的信任來自 designated requirement 檢查。
- [替換正在執行的 binary] → rename 不影響舊行程；測試在暫存目錄驗證新 inode 與舊行程都正常。
- [daemon 版本握手分不出新舊版] → #304 之前握手版本來自 `SAFARI_BROWSER_BUILD_*`（預設 `1.0.0+unknown`），不是 `BuildVersion`，所以沒停到的 daemon 會用舊程式碼回應新 CLI；#304 讓握手帶蓋章的建置身分之後，新 CLI 會判為 mismatch 而退回 stateless。輸出只說兩種情況下都成立的事：寫出掃描過的目錄、停不掉的 daemon、目錄解析失敗的情況，以及「沒停到的 daemon 仍在跑舊 binary」。
- [執行中的 `safari-browser mcp`] → 替換後它的 MCP image guard 會拒絕每一個 tool call（fail-closed），輸出提示要重開。
- [running-binary 檢查讀的是路徑上的檔案] → `SecCodeCopySelf` 的 static code 從啟動路徑讀；一般的 `mv` 蓋過那個路徑時，hash 比對會拿新檔跟自己比。另以 `SecCodeCheckValidity(running)` 擋下這種情況（round 2；DA 實測回 -67034）；它沒有自動測試（要用子行程替換執行中的 binary），列在 follow-up。
- [撤銷與公證] → 都沒有檢查，與 README 的手動步驟相同；候選者的驗證另加 `kSecCSStrictValidate`，對應 `--strict`。
- [hardened runtime 只讀預設架構的 slice] → designated requirement 已逐 slice 檢查並釘住 team 與 identifier，風險小；逐 slice 檢查 runtime 另案追蹤。

## Migration Plan

新增指令，沒有既有行為要遷移。v2.7.0 沒有 `self-update`，第一次仍需手動安裝含此指令的版本，README 與 `docs/release.md` 會說明。回滾：`<target>.previous` 就是上一版，`mv` 回去即可，文件寫明。
