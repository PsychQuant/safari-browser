## 1. 蓋章腳本（先寫測試；對應 design 決定「蓋章由 `scripts/stamp-version.sh` 包住建置指令」與 spec 需求「The version maps to a git tag or commit」「A version that cannot be determined is reported as unknown」）

- [x] 1.1 新增 `scripts/stamp-version-test.sh`，涵蓋蓋章腳本的行為：成功時指令看得到蓋入的版本、指令失敗時結束碼原樣傳回且佔位檔還原、收到 TERM 時佔位檔還原、版本含雙引號時改寫 `unknown`、目錄沒有 `.git` 時寫 `unknown`、tag 為 `idd-*` 時不出現在字串中。先執行確認全部失敗（腳本尚不存在）。（驗證 spec 需求 The version maps to a git tag or commit、A version that cannot be determined is reported as unknown）
- [x] 1.2 新增 `scripts/stamp-version.sh`：先計算 `git describe --tags --match 'v[0-9]*' --always --dirty`，不合 `^[A-Za-z0-9._+-]+$` 或 `git` 失敗就用 `unknown`；備份原檔、設定 EXIT/INT/TERM 的 trap 還原、寫入蓋章內容、執行 `--` 之後的指令並以其結束碼結束。驗證：`bash scripts/stamp-version-test.sh` 全數通過。

## 2. CLI 旗標（先寫測試；對應 design 決定「版本字串的來源：追蹤中的佔位檔，建置時由包裝腳本蓋章」與 spec 需求「The CLI reports a version」「The reported version is the client binary's」）

- [x] 2.1 [P] 新增 `Tests/SafariBrowserTests/BuildVersionTests.swift`：驗證追蹤中的佔位值是 `unknown`、`SafariBrowser.configuration.version` 等於 `BuildVersion.value`、以 `SafariBrowser.parse(["--version"])` 的路徑被接受而不是回 unknown option。先執行確認失敗。（驗證 spec 需求 The CLI reports a version、The reported version is the client binary's）
- [x] 2.2 新增追蹤中的 `Sources/SafariBrowser/BuildVersion.swift`（`enum BuildVersion { static let value = "unknown" }`），並在 `Sources/SafariBrowser/SafariBrowser.swift` 的 root `CommandConfiguration` 設 `version: BuildVersion.value`。驗證：`swift test --filter BuildVersionTests` 通過，`swift build` 後 `.build/debug/safari-browser --version` 印 `unknown`。（實作 spec 需求 The CLI reports a version）

## 3. Makefile 與 spec（對應 spec 需求「Build via Makefile」）

- [x] 3.1 修改 `Makefile` 的 `build` 目標，用 `scripts/stamp-version.sh Sources/SafariBrowser/BuildVersion.swift -- swift build -c release` 取代單純的 `swift build -c release`，並把新的測試腳本接成 `make test-stamp-version`。驗證：`make build` 完成後 `git status --porcelain` 為空，且 `.build/release/safari-browser --version` 印出以 `v` 開頭或短 sha 的字串，不含 `idd-`。（實作 spec 需求 Build via Makefile）
- [x] 3.2 確認 `openspec/changes/add-cli-version/specs` 的 delta 通過驗證（`spectra validate add-cli-version`）。delta 不手動合併進 `openspec/specs`：封存（`/spectra-archive`）會套用 delta，手動合併會讓封存拒絕或重複。

## 4. 文件與整體驗證

- [x] 4.1 [P] 在 `CHANGELOG.md` 的 Unreleased 區塊加一條說明 `--version` 與其格式，並在 `README.md` 說明：正式安裝請走 `make install`，直接執行 `swift build` 的版本是 `unknown`，`--version` 報的是 client binary 而不是常駐 daemon。驗證：兩個檔案出現 `--version` 說明，內容審閱。（記錄 spec 需求 The reported version is the client binary's）
- [x] 4.2 跑完整驗證：`make test-stamp-version`、`swift test`、`make build` 後確認工作樹乾淨、`make install` 到暫存的 `INSTALL_DIR` 後 `--version` 與 `make build` 的輸出一致。驗證：全部指令結束碼為 0，輸出貼進 issue 的 Implementation Complete 留言。
