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

## Plugin & MCP

Claude Code plugin 位於另一個 repo：

- **Plugin**: `/Users/che/Developer/psychquant-claude-plugins/plugins/safari-browser/`
- **MCP server**: `channel/channel.ts`（本 repo）→ 同步到 plugin repo 的 `channel/channel.ts`
- **SKILL.md**: plugin repo `skills/safari-browser/SKILL.md`
- **Marketplace**: `psychquant-claude-plugins/.claude-plugin/marketplace.json`

修改 `channel/channel.ts` 後須同步到 plugin repo 並 push。
MCP server 提供 4 個 tools：`safari_action`、`safari_monitor_pause`、`safari_monitor_resume`、`safari_monitor_status`。

## Design Principle: Non-Interference

所有指令預設不干擾使用者操作 — 使用者可以同時做其他事情不受影響。

- **不控制**滑鼠/鍵盤（除非 `--allow-hid` / `--native`）
- **不彈出**系統對話框
- **不發出**聲音（`screencapture -x`）
- **不搶**視窗焦點

新增指令前須分類 interference level（Non-interfering / Passively interfering / Actively interfering）。
完整規範：`openspec/specs/non-interference/spec.md`
