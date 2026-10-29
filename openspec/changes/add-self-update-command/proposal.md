## Why

v2.7.0 起 release 都是 Developer ID 簽章、hardened runtime 並經 Apple 公證（#280），但已安裝的 binary 沒有任何更新路徑：plugin 的 SessionStart hook 只回報版本、不下載也不替換，使用者每出一版都要照 README 手動下載、核對 checksum、驗簽章、搬進 `~/bin`。重複的手動驗證容易被省略，結果不是漏驗，就是一直停在舊版（#314）。

## What Changes

- 新增 `safari-browser self-update`：從 `PsychQuant/safari-browser` 的最新 release 下載 `safari-browser` 與 `safari-browser.sha256`，依序核對 checksum、簽章、自報版本，通過才以原子 rename 替換正在執行的那支 binary，並保留一份備份。替換前不詢問（維護者決定，#314 Clarity Surface 第 2 列）。
- 新增 `safari-browser self-update --check`（含 `--json`）：只查詢、比版本、回報，不下載 binary、不寫檔。`--json` 的 `status` 是封閉列舉，供 plugin hook 判讀（PsychQuant/psychquant-claude-plugins#155）。
- 信任檢查：已安裝那支必須是 Developer ID 的 durable 簽章；新版必須也是、帶 hardened runtime 與 `com.apple.security.automation.apple-events` entitlement，並且**滿足已安裝那支的 designated requirement**。判斷重用 `SignatureAssessment`。
- 替換完成後，停掉 socket 目錄裡所有仍在執行的 daemon，並印出 `safari-browser daemon start`（維護者決定，#314 Clarity Surface 第 1 列）。
- 任何一步失敗都中止，已安裝的 binary 不變，staging 檔被清除。

## Non-Goals

- plugin hook 的每日檢查與提示（psychquant-claude-plugins#155）。
- 背景自動更新、排程更新、Homebrew。
- 降級、指定版本、prerelease 通道。
- 以 sudo 寫入使用者無權寫入的目錄。
- 從命令列確認公證：裸 Mach-O 無法 staple，`spctl` 對已公證的它也回答未公證（#280 的量測），所以不列為檢查項。

## Capabilities

### New Capabilities

- `self-update`: `self-update` 與 `self-update --check` 的版本比較、release 來源、checksum 與簽章驗證、原子替換、daemon 收尾與輸出契約

### Modified Capabilities

- `non-interference`: 新增 self-update 的干擾等級分類——第一個會連網、也會改寫 CLI 自己 binary 的指令
- `install-signature-contract`: 原子安裝的要求延伸到 self-update，且 self-update 必須使用共用的簽章判斷

## Impact

- Affected specs: `self-update`（新）、`non-interference`、`install-signature-contract`
- Affected code:
  - 新增 `Sources/SafariBrowser/Commands/SelfUpdateCommand.swift`
  - 新增 `Sources/SafariBrowser/SelfUpdate/`（版本比較、release 來源、驗證、替換、daemon 收尾）
  - 修改 `Sources/SafariBrowser/SafariBrowser.swift`（註冊子指令）
  - 新增 `Tests/SafariBrowserTests/SelfUpdate*Tests.swift`
  - 文件：`README.md`、`docs/release.md`、`CLAUDE.md`、`CHANGELOG.md`
- 外部相依：GitHub REST API（`releases/latest`，未認證每小時 60 次）
