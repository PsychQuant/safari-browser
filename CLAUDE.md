<!-- SPECTRA:START v1.0.1 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra:*` skills when:

- A discussion needs structure before coding → `/spectra:discuss`
- User wants to plan, propose, or design a change → `/spectra:propose`
- Tasks are ready to implement → `/spectra:apply`
- There's an in-progress change to continue → `/spectra:ingest`
- User asks about specs or how something works → `/spectra:ask`
- Implementation is done → `/spectra:archive`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra:apply` and `/spectra:ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

## Plugin

Claude Code plugin 位於另一個 repo：

- **Plugin**: `/Users/che/Developer/psychquant-claude-plugins/plugins/safari-browser/`
- **SKILL.md**: plugin repo `skills/safari-browser/SKILL.md`
- **Marketplace**: `psychquant-claude-plugins/.claude-plugin/marketplace.json`

## Design Principle: Non-Interference

所有指令預設不干擾使用者操作 — 使用者可以同時做其他事情不受影響。

- **不控制**滑鼠/鍵盤（除非 `--allow-hid` / `--native`）
- **不彈出**系統對話框
- **不發出**聲音（`screencapture -x`）
- **不搶**視窗焦點

新增指令前須分類 interference level（Non-interfering / Passively interfering / Actively interfering）。
完整規範：`openspec/specs/non-interference/spec.md`

## Multi-window / Multi-document targeting (#17 #18 #21)

多視窗環境下，**預設 target 是 `document 1`**（單視窗時等價於 `current tab of front window`）。
當 Safari 有多個視窗時，**優先用 `--url`** 明確指定 document，避免 z-order 歧義：

```bash
# 先發現可用的 targets
safari-browser documents

# 針對特定 document
safari-browser --url plaud get url
safari-browser --url plaud click "button.upload"
safari-browser --window 2 get title
```

**規則**：
- `--url` / `--window` / `--tab` / `--document` 四者**互斥**
- `tabs` / `tab` / `open --new-tab` / `open --new-window` 只接受 `--window`（window-level UI ops）
- Read-only query 自動 document-scoped，modal sheet 不會 block（#21 fix）
- Keystroke / upload dialog 維持 window-scoped 語意（front window）

AI agent 在多視窗環境建議：先跑 `safari-browser documents` 看有哪些 documents，然後用 `--url <substring>` 明確指定。避免靠 `front window` 的 z-order 猜測。

新抽象：
- `SafariBridge.TargetDocument` enum — 四個 case
- `SafariBridge.resolveDocumentReference(_:) -> String` — AppleScript reference 產生器
- `TargetOptions` ParsableArguments — 全域 CLI flags via `@OptionGroup`
- `SafariBrowserError.documentNotFound(pattern:availableDocuments:)` — 錯誤路徑含 discovery

完整 spec 見：
- `openspec/specs/document-targeting/spec.md`（設計稿在 `openspec/changes/multi-document-targeting/` 的 apply 完成後會 archive 到 specs）
- `openspec/changes/multi-document-targeting/design.md`（trade-offs、alternatives、migration）
