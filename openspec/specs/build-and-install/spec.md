# build-and-install Specification

## Purpose

定義專案的建置、安裝與清理入口，包含預設 ad-hoc 開發安裝、可供完全取用磁碟（FDA）授權跨重編保留的 Developer ID 安裝，以及簽章驗證與原子替換的失敗邊界。

## Requirements

### Requirement: Build via Makefile

The system SHALL provide a Makefile with `build` target that runs `swift build -c release`.

#### Scenario: Build the project

- **WHEN** user runs `make build` in the repo root
- **THEN** `swift build -c release` executes and produces `.build/release/safari-browser`


<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->

---
### Requirement: Install via Makefile

系統 SHALL 提供 `make install`，建置 release binary 後以 ad-hoc 簽章安裝至 `$(INSTALL_DIR)/safari-browser`；`INSTALL_DIR` 預設為 `~/bin`。此預設 SHALL 不要求 `DEVELOPER_ID`，讓沒有 Apple Developer 憑證的使用者仍能安裝。

安裝 SHALL 在目的目錄建立暫存檔，複製 binary、設定執行權限並完成簽章，再以同一檔案系統的 rename 原子替換正式路徑，SHALL NOT 直接覆寫舊 inode。簽章失敗時 SHALL 保留既有安裝並清理暫存檔。安裝後 SHALL 核對正式路徑與本次暫存成品的 SHA-256；若另一個安裝已替換該路徑，SHALL 回報失敗且不刪除或還原他人的安裝。

#### Scenario: Install the binary

- **WHEN** 使用者執行 `make install`
- **THEN** 建置完成的 binary 以 ad-hoc 簽章及執行權限原子安裝至目的路徑
- **AND** 指引說明 ad-hoc FDA 授權不能保證跨重編保留，並指向 `DEVELOPER_ID=<cert-sha1> make install-signed`

#### Scenario: Replace a binary still held by a running process

- **GIVEN** 舊 binary 的 inode 仍由執行中的程序持有
- **WHEN** 安裝成功替換正式路徑
- **THEN** 正式路徑指向新 inode，新 binary 可啟動，舊程序仍持有原本的檔案

#### Scenario: Signing fails before replacement

- **GIVEN** 目的路徑已有可用 binary
- **WHEN** 暫存成品無法完成簽章
- **THEN** 安裝以非零狀態結束，既有 binary 保持原樣且暫存檔被清理

#### Scenario: Another installer replaces the destination

- **WHEN** rename 後正式路徑的 SHA-256 與本次暫存成品不同
- **THEN** 安裝以非零狀態回報競爭，不宣稱本次成品已安裝，也不還原或刪除正式路徑

<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->

<!-- @trace
source: shared-install-signature-contract
code:
  - Makefile
  - Sources/SafariBrowser/Info.plist
  - Sources/SafariBrowser/Entitlements.plist
  - scripts/verify-install-signature.swift
-->

---
### Requirement: Install with a durable Developer ID signature

系統 SHALL 提供獨立的 `make install-signed`，供需要 `history`、`bookmarks`、`cloud-tabs`、`downloads` 等 FDA 查詢，且具備 Developer ID 簽署憑證的使用者選用。此 target SHALL 要求非空的 `DEVELOPER_ID`，以該憑證、hardened runtime 與 `Sources/SafariBrowser/Entitlements.plist` 簽署暫存成品，並使用與 `install` 相同的目的路徑及原子替換方式。本機自行建置安裝 SHALL 不要求 notarization 或 `NOTARY_PROFILE`。

簽章 identifier SHALL 來自 `Sources/SafariBrowser/Info.plist` 的 `CFBundleIdentifier`（由 `Package.swift` 嵌入 binary），SHALL NOT 由暫存檔名或另一份硬編碼 identifier 決定。產出的 designated requirement（DR）SHALL 採 Developer ID identity-bound 形狀：identifier、Apple generic anchor、Developer ID 憑證條件與 leaf certificate 的 team OU，而非內容雜湊。跨重編保留既有 FDA 授權 SHALL 以維持同一簽署身分與 DR 為前提；更換身分或 `CFBundleIdentifier` SHALL 不被描述為保證保留授權。

在替換正式路徑前，簽章 guard SHALL 確認程式簽章有效、binary 滿足其自身 DR、DR 為 Developer ID 形狀，且 `com.apple.security.automation.apple-events` entitlement 為布林真值。簽署或此驗證失敗 SHALL 保留既有安裝並清理暫存檔。rename 後 SHALL 再對正式路徑執行相同驗證，並核對 SHA-256 為本次成品；任一條件不成立 SHALL 回報非零狀態，不自動還原或刪除可能由其他安裝寫入的 binary。

#### Scenario: Install a signed build for local data access

- **GIVEN** `DEVELOPER_ID` 指定可用的 Developer ID 簽署憑證
- **WHEN** 使用者執行 `make install-signed`
- **THEN** 通過簽章 guard 的暫存成品才會替換正式路徑，且正式路徑再次通過相同 guard 與本次成品雜湊核對後才回報成功
- **AND** 使用者被指引手動將安裝的 binary 加入系統設定的 FDA；簽章驗證不等於已取得 FDA 授權

#### Scenario: Missing signing identity

- **WHEN** 使用者未設定 `DEVELOPER_ID` 而執行 `make install-signed`
- **THEN** 安裝以非零狀態結束且不替換正式路徑

#### Scenario: Reject a signed build outside the contract

- **WHEN** 暫存成品的簽章失效、不滿足自身 DR、非 Developer ID DR 形狀或缺少布林真值的 Apple Events entitlement
- **THEN** guard 拒絕安裝，既有 binary 保持原樣

#### Scenario: Validate an existing installation without modifying it

- **WHEN** 使用者執行 `make verify-install-signature`
- **THEN** guard 唯讀檢查已安裝 binary 是否具有可辨識且滿足的 identity-bound DR 與有效程式簽章，不要求憑證、FDA 授權或 Safari 執行中
- **AND** 無法確認 durability 時回報非零狀態；細分退出碼以 `scripts/verify-install-signature.swift` 標頭為準，make 包裝層不保證保留該退出碼

<!-- @trace
source: shared-install-signature-contract
code:
  - Makefile
  - Package.swift
  - Sources/SafariBrowser/Info.plist
  - Sources/SafariBrowser/Entitlements.plist
  - scripts/verify-install-signature.swift
-->


---
### Requirement: Clean via Makefile

The system SHALL provide a Makefile with `clean` target that removes the `.build/` directory.

#### Scenario: Clean build artifacts

- **WHEN** user runs `make clean` in the repo root
- **THEN** the `.build/` directory is removed


<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->

---
### Requirement: Git repository initialized

The system SHALL have a git repository with proper `.gitignore` excluding `.build/`, `.swiftpm/`, `Package.resolved`, and `references/`.

#### Scenario: Gitignore covers build artifacts

- **WHEN** user runs `git status` after a build
- **THEN** `.build/`, `.swiftpm/`, and `Package.resolved` are not shown as untracked files

<!-- @trace
source: repo-setup-and-plugin
updated: 2026-03-28
code:
  - README.md
  - Sources/SafariBrowser/SafariBrowser.swift
  - Sources/SafariBrowser/Commands/DblclickCommand.swift
  - Sources/SafariBrowser/Commands/TypeCommand.swift
  - Sources/SafariBrowser/Commands/ScrollIntoViewCommand.swift
  - Sources/SafariBrowser/Commands/SelectCommand.swift
  - Sources/SafariBrowser/Commands/HoverCommand.swift
  - Sources/SafariBrowser/Commands/FocusCommand.swift
  - Sources/SafariBrowser/Commands/UploadCommand.swift
  - Sources/SafariBrowser/SafariBridge.swift
  - Sources/SafariBrowser/Commands/GetCommand.swift
  - Sources/SafariBrowser/Commands/CheckCommand.swift
  - Sources/SafariBrowser/Commands/IsCommand.swift
  - Sources/SafariBrowser/Commands/FillCommand.swift
  - Sources/SafariBrowser/Commands/HighlightCommand.swift
  - Sources/SafariBrowser/Commands/ClickCommand.swift
  - Sources/SafariBrowser/Commands/SnapshotCommand.swift
-->
