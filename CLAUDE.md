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

## Multi-window / Multi-document targeting (#17 #18 #21 #23)

多視窗環境下，**預設 target 是 `document 1`**（單視窗時等價於 `current tab of front window`）。
當 Safari 有多個視窗時，**優先用 `--url`** 明確指定 document，避免 z-order 歧義：

```bash
# 先發現可用的 targets
safari-browser documents

# 針對特定 document
safari-browser get url --url plaud
safari-browser click "button.upload" --url plaud
safari-browser get title --window 2

# #23: Storage / Wait / Snapshot / Upload(--js) 全部支援 TargetOptions
safari-browser storage local get token --url plaud    # per-origin token
safari-browser wait --for-url "/dashboard" --url plaud
safari-browser snapshot --url plaud
safari-browser upload --js "input[type=file]" file.mp3 --url plaud

# #23: Window-only commands（close / screenshot / pdf / upload --native）
safari-browser close --window 2
safari-browser screenshot --window 2 out.png
safari-browser pdf --window 2 --allow-hid out.pdf
safari-browser upload --native "input[type=file]" file.mp3 --window 2
```

**規則**：
- `--url` / `--window` / `--tab` / `--document` 四者**互斥**
- Read-only query 自動 document-scoped，modal sheet 不會 block（#21 fix）
- **Window-level UI ops**（`tabs` / `tab` / `open --new-tab` / `open --new-window`）只接受 `--window`
- **Window-only primitives**（`close` / `screenshot` / `pdf` / `upload --native`）只接受 `--window` — 底層是 AppleScript `close current tab of window N` / CGWindowListCopyWindowInfo / System Events keystrokes，沒有 document-scoped 版本（#23）
- **`screenshot` / `pdf` / `upload --native` 的 `--window N` 會 briefly raise window N to front**（#23 verify R4）— 這是跨 AppleScript ↔ CoreGraphics 邊界唯一可靠的 window identity 策略。Bounds / title 兩種 disambiguation 在 real world 都會失敗（maximized windows 同 bounds、auth callbacks 讓 AS URL ≠ CG cached title）。三個命令統一走 raise-then-resolve。需要不干擾 z-order 的背景抓取 → 改用 `--url` + JS API
- **Upload split path**（#23）：`--js` 接受完整 TargetOptions、`--native` / `--allow-hid` 只接受 `--window`；沒指定 mode 時若帶了 `--url` / `--tab` / `--document` 會自動走 JS path
- **Wait breaking change**（#23）：原本的 `wait --url <pattern>` 改為 `wait --for-url <pattern>`，因為 `--url` 現在是 targeting flag

AI agent 在多視窗環境建議：先跑 `safari-browser documents` 看有哪些 documents，然後用 `--url <substring>` 明確指定。避免靠 `front window` 的 z-order 猜測。

新抽象：
- `SafariBridge.TargetDocument` enum — 四個 case
- `SafariBridge.resolveDocumentReference(_:) -> String` — AppleScript reference 產生器
- `TargetOptions` ParsableArguments — 全域 CLI flags via `@OptionGroup`
- `WindowOnlyTargetOptions` ParsableArguments — window-only 子集（#23），Close/Screenshot/Pdf 共用
- `SafariBrowserError.documentNotFound(pattern:availableDocuments:)` — 錯誤路徑含 discovery

完整 spec 見：
- `openspec/specs/document-targeting/spec.md`
- `openspec/specs/document-listing/spec.md`
- `openspec/changes/archive/2026-04-13-multi-document-targeting/`（原 design + trade-offs）
