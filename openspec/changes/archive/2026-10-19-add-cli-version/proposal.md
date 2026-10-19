## Why

safari-browser 的 CLI 沒有版本旗標（`safari-browser --version` 回 `Unknown option`），而最新的 release（v2.6.0，2026-04-26）遠落後 `main`：例如 #127 的修復（PR #150，2026-09-13 合併）不在任何 release 裡。使用者端的已安裝 binary 可以比 `main` 舊好幾週，卻沒有任何一端看得出來；plugin 的 SessionStart 檢查目前只能比對檔案建置時間，答不出「我裝的是哪一版」。#278 要的是讓每個 binary 都能報出可對應到 git 的版本。

## What Changes

- root command 設定 `version:`，由 swift-argument-parser 提供 `--version`。
- 新增一個單一來源常數 `BuildVersion.value`；追蹤中的檔案內容是佔位字串 `unknown`，讓不經 Makefile 的 `swift build` 與 `swift test` 永遠能編譯。
- Makefile 的 `build` 目標在 `swift build -c release` 之前把 `git describe --tags --match 'v[0-9]*' --always --dirty` 的結果寫進該常數，建置結束（含失敗、中斷）後以 trap 還原追蹤中的佔位檔，工作樹保持乾淨。`install` 與 `install-signed` 都依賴 `build`，因此一併涵蓋。
- 取不到版本（沒有 `.git` 的原始碼包、`git` 不可用）時字串維持 `unknown`，建置不失敗。
- `build-and-install` spec 補上蓋章、還原與 `unknown` 退路的需求。
- 在 CHANGELOG 與 README 記一行用法。

## Non-Goals

- **不發布 release。** 讓 release 跟上 `main` 是維護者對節奏與發布管道的決定，不是實作能決定的事；本次只讓「與 release 比較」有意義（有版本字串可比）。
- **不修改 plugin 的 SessionStart hook。** 它在另一個 repo（psychquant-claude-plugins），本變更落地後可改為優先比對 `--version`。
- **不自動更新已安裝的 binary。** `make install-signed` 會重設 Full Disk Access 授權（#119），自動覆蓋不是好預設。
- **不採用 SwiftPM build-tool plugin。** 它更乾淨，但為了一個字串引入 plugin target 與長期依賴，影響面大於 Makefile 蓋章。
- **不採用「只在發布時改常數」。** 那會讓 `main` 上每個建置都寫 2.6.0，重現原本的模糊。
- 不處理常駐 daemon 在 `make install` 之後仍是舊 inode 的問題（#121）；`--version` 報的是 client binary，這一點寫進文件。

## Capabilities

### New Capabilities

- `cli-version`: CLI 的 `--version` 旗標、版本字串的格式與取不到時的 `unknown` 退路。

### Modified Capabilities

- `build-and-install`: `build` 目標在建置前蓋入版本並於結束後還原追蹤中的佔位檔。

## Impact

- Affected specs: `cli-version`（新）、`build-and-install`（修改）
- Affected code:
  - New: Sources/SafariBrowser/BuildVersion.swift, Tests/SafariBrowserTests/BuildVersionTests.swift
  - Modified: Sources/SafariBrowser/SafariBrowser.swift, Makefile, openspec/specs/build-and-install/spec.md, CHANGELOG.md, README.md
  - Removed: （無）

## Assumptions

- 版本字串採用 `git describe --tags --match 'v[0-9]*' --always --dirty`；不加 `--match` 時這個 repo 的 `main` 會回 `idd-217-baseline-31-gd454d7c`，無法對應任何 release。
- `--dirty` 讓本機有未提交修改的建置與乾淨建置可區分。
- 蓋章只放在 `build` 目標；直接執行 `swift build -c release` 的人拿到 `unknown`，這是設計內的退路，不算失敗。
