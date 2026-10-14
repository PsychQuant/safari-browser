## Context

safari-browser 的 root command 在 `Sources/SafariBrowser/SafariBrowser.swift`，沒有設定 `version:`，所以 `--version` 回 `Unknown option`。swift-argument-parser 在設了 `version:` 之後會自動提供 `--version`，所以旗標本身只是一行；難處在版本字串的來源：

- `build` 目標目前只做 `swift build -c release`（`openspec/specs/build-and-install` 的 Requirement「Build via Makefile」），SwiftPM 沒有把字串在編譯期注入程式的內建機制，manifest 的沙箱也不能執行 `git`。
- `install` 與 `install-signed` 都依賴 `build`，三者最後吃的都是 `.build/release/safari-browser`。
- `swift test` 與 `scripts/run-unit-tests.py` 不經過 Makefile，所以任何方案都必須讓「沒有蓋章」的建置仍能編譯。
- 這個 repo 的 tag 空間與 IDD 的 baseline tag 共用：不加過濾時 `git describe --tags --always --dirty` 在 `main` 回 `idd-217-baseline-31-gd454d7c`，對應不到任何 release。

## Goals / Non-Goals

**Goals:**

- `safari-browser --version` 印出一個能對應到 git tag 或 commit 的字串。
- 每個經過 `make build` / `make install` / `make install-signed` 的 binary 都帶蓋入的版本。
- 沒有 Makefile、沒有 `.git`、或 `git` 不可用時建置照常成功，版本為 `unknown`。
- 蓋章不留下工作樹的變更，包含建置失敗與被中斷的情況。

**Non-Goals:**

- 不發布 release，也不決定發布節奏（維護者的決定）。
- 不修改 plugin 的 SessionStart hook（另一個 repo）。
- 不自動更新已安裝的 binary。
- 不處理常駐 daemon 在安裝後仍是舊 inode 的問題（#121）。
- 範圍內：`Sources/SafariBrowser/SafariBrowser.swift`、新的 `Sources/SafariBrowser/BuildVersion.swift`、`Makefile` 的 `build` 目標、新的 `scripts/stamp-version.sh`、測試、`build-and-install` spec、文件。範圍外：其餘所有指令的行為。

## Decisions

### 1. 版本字串的來源：追蹤中的佔位檔，建置時由包裝腳本蓋章

新增 `Sources/SafariBrowser/BuildVersion.swift`，內容是 `enum BuildVersion { static let value = "unknown" }`，納入版本控制。`SafariBrowser.configuration` 的 `version:` 讀 `BuildVersion.value`。

**為什麼不是 SwiftPM build-tool plugin：** plugin 在 `swift build` 就會生成檔案，連 `swift test` 都會帶版本，更乾淨；但為了一個字串引入 plugin target 與一個長期維護的建置依賴，影響面大於一支 shell 腳本。選擇影響面較小的做法，並把 plugin 記為之後若需要「所有建置都帶版本」時的升級路徑。

**為什麼不是只在發布時改常數：** 那會讓 `main` 上每個建置都寫 2.6.0，重現 issue 抱怨的模糊。

### 2. 蓋章由 `scripts/stamp-version.sh` 包住建置指令

`scripts/stamp-version.sh <版本檔> -- <指令…>` 依序做：

1. 先算版本，再動檔案：`git describe --tags --match 'v[0-9]*' --always --dirty`。順序固定是先算後寫，否則蓋章這個動作本身會讓 `--dirty` 永遠成立。
2. 版本字串不是 `^[A-Za-z0-9._+-]+$`，或 `git` 失敗，就用 `unknown`。這同時擋掉會破壞 Swift 字串引號的內容。
3. 把原檔備份到暫存檔，設定 `trap`（EXIT、INT、TERM）還原，再寫入蓋章後的檔案。
4. 執行 `--` 之後的指令，以該指令的結束碼結束。

還原用「備份複本」而不是 `git checkout`，這樣在沒有 `.git` 的原始碼包裡也能還原。

Makefile 的 `build` 目標改成呼叫這支腳本包住 `swift build -c release`。`install` 與 `install-signed` 不需要改，因為它們依賴 `build`。

**為什麼拆成腳本而不是寫在 Makefile 的一長串 shell：** 蓋章與還原需要被測試（建置失敗、被中斷時是否還原），而不想為了測試跑一次約 30 秒的 release 建置。腳本可以拿 `true`、`false` 與一個會檢查檔案內容的指令來測。

### 3. 版本字串格式

沿用 `git describe` 的輸出，不另外加工：剛好在 tag 上是 `v2.6.0`；之後的建置是 `v2.6.0-31-gd454d7c`；有未提交修改時尾端加 `-dirty`；沒有任何 `v*` tag 時 `--always` 退成短 sha。`--match 'v[0-9]*'` 是必要的，沒有它會落在 `idd-*-baseline` 這類 tag 上。

### 4. `--version` 報的是 client binary

常駐 daemon 在 `make install` 之後可能仍是安裝前的 inode（#121）。`--version` 只報執行它的那個 client binary 的版本，不查 daemon。這點寫進 README，不在本次處理。

## Risks / Trade-offs

- **中斷時留下已蓋章的檔案** → 腳本用 `trap` 還原，並有測試確認指令失敗與收到終止訊號後檔案內容回到佔位值。
- **蓋章期間工作樹有短暫的修改** → 可接受；`git describe` 在蓋章前已算好。plugin 方案能避免這件事，已記為升級路徑。
- **直接執行 `swift build` 的人拿到 `unknown`** → 這是設計內的退路；README 說明正式安裝請走 `make install`。
- **版本字串無法對應 release 的情況**：repo 沒有任何 `v*` tag 時退成短 sha，仍能對應到 commit。
