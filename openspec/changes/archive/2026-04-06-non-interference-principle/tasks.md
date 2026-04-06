## 1. Spec 歸檔

- [x] 1.1 [P] 將 `specs/non-interference/spec.md` 歸檔到 `openspec/specs/non-interference/spec.md`（default non-interference、explicit opt-in、interference warning、conformance classification 四個 requirements）

## 2. 現有實作 conformance 驗證

- [x] 2.1 [P] 驗證 `ScreenshotCommand.swift` 符合 default non-interference requirement — 確認 `screencapture -x` silent flag 存在
- [x] 2.2 [P] 驗證 `UploadCommand.swift` 符合 explicit opt-in for interfering operations requirement — 確認預設走 JS DataTransfer、`--allow-hid` 才走 System Events
- [x] 2.3 [P] 驗證 `PdfCommand.swift` 符合 explicit opt-in for interfering operations requirement — 確認無 `--allow-hid` 時拒絕執行
- [x] 2.4 [P] 驗證 `channel/channel.ts` 符合 default non-interference requirement — 確認 `SB_CHANNEL_MONITOR` 預設關閉
- [x] 2.5 [P] 驗證 `UploadCommand.swift` 和 `PdfCommand.swift` 符合 interference warning on stderr requirement — 確認 HID 啟用時 stderr 有警告訊息

## 3. Conformance classification for new commands

- [x] 3.1 [P] 更新 CLAUDE.md 加入 non-interference principle 及 conformance classification for new commands 的引用，指向 `openspec/specs/non-interference/spec.md`
- [x] 3.2 [P] 更新 plugin SKILL.md 在 upload/pdf 段落加入 interference level 標註（conformance classification）
