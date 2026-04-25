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

## Post-archive maintenance

`spectra archive` appends `<!-- @trace ... -->` HTML comments that list every file the archiving session wrote — including transient `.remember/logs/autonomous/save-*.log` and `.remember/tmp/*` paths. Without pruning, specs like `screenshot/spec.md` balloon to 35 000+ lines, 98% of which is log-file noise invisible in any rendered view.

After any `spectra archive` run that touches `openspec/specs/**`, run:

```bash
./scripts/prune-spec-traces.sh --dry-run   # preview line deltas
./scripts/prune-spec-traces.sh --apply     # strip transient refs, backup to /tmp/spec-prune-backup/<ts>/
```

The script is idempotent — re-running is a no-op once specs are clean. Real code refs (`Sources/`, `Tests/`, docs) are preserved; only `.remember/logs/` + `.remember/tmp/` lines are removed. Provenance headers (`source:` / `updated:`) always survive.

See `#41` for the bloat incident that motivated this.

## Plugin

Claude Code plugin 位於另一個 repo：

- **Plugin**: `/Users/che/Developer/psychquant-claude-plugins/plugins/safari-browser/`
- **SKILL.md**: plugin repo `skills/safari-browser/SKILL.md`
- **Marketplace**: `psychquant-claude-plugins/.claude-plugin/marketplace.json`

### Playbook skills（site-specific 操作手冊）

每個 site-specific 操作流程是 plugin repo `skills/` 底下的獨立 skill，命名 `safari-<site>-<action>/SKILL.md`，與 main `safari-browser` skill 同層。Claude Code 依 description 自動 surface。

- **Contribution guide**: `psychquant-claude-plugins/plugins/safari-browser/skills/CONTRIBUTING-PLAYBOOKS.md`
- **Authoritative spec**: `openspec/specs/playbook-skills/spec.md`（本 repo）
- **Seeds**: `safari-plaud-upload`, `safari-github-star`
- **User-local override**: 個人 playbook 放 `~/.claude/skills/safari-<site>-<action>/SKILL.md` — Claude 原生 skill loader 直接吃，plugin 不做任何 custom precedence
- **跨 repo 同步**: 規範住本 repo，實作住 plugin repo —— 改規範時記得同步檢查 plugin 裡的 seeds 和 CONTRIBUTING-PLAYBOOKS.md 沒有 drift

## References

`references/` is gitignored local-only space for external-project clones. See [`REFERENCES.md`](REFERENCES.md) for the tracked map of expected local bundles (`agent-browser`, `mas`) plus the rationale for intentional omissions.

Key decision: **`browser-harness` is cited by URL, not bundled locally** (#36). Three in-flight specs (`playbook-skills`, `persistent-daemon` design + proposal) already cite browser-harness concepts via https://github.com/browser-use/browser-harness URLs; local clones under `references/` don't participate in PR diffs / history (dir is gitignored), so bundling offers no reviewer or reader benefit over URL citations.

## Design Principle: Non-Interference

所有指令預設不干擾使用者操作 — 使用者可以同時做其他事情不受影響。

- **不控制**滑鼠/鍵盤（除非 `--allow-hid` / `--native`）
- **不彈出**系統對話框
- **不發出**聲音（`screencapture -x`）
- **不搶**視窗焦點

新增指令前須分類 interference level（Non-interfering / Passively interfering / Actively interfering）。
完整規範：`openspec/specs/non-interference/spec.md`

## Design Principle: Human Emulation (tab-targeting-v2)

safari-browser 預設行為應貼近人類用 Safari 的心智模型 — 與 Non-Interference 同級 principle，衝突時透過 spatial gradient 調和。四條衍生規則：

- **Tab bar 是 ground truth** — 所有 target-resolution 走 `tabs of windows` 而非 `documents` collection（documents 每 window 只看得到 front tab，不是人類看到的）
- **歧義時 fail-closed** — `.urlContains` 多 match 預設丟 `ambiguousWindowMatch`，不 silent first-match；想要舊行為加 `--first-match` opt-in（附 stderr warning）
- **已開的網址 focus 而非重開** — `open <url>` 預設檢查 exact URL match：有就 focus existing（走 spatial gradient），無就 new-tab；想要 navigate front tab 語義加 `--replace-tab`
- **空間感分級互動**（Spatial Gradient）— `focusExistingTab` 根據目標 tab 位置採不同動作：

  | Layer | 目標位置 | 行為 | Interference |
  |---|---|---|---|
  | 1 | Front tab of front window | noop | Non-interfering |
  | 2 | Background tab of front window | `set current tab` | Passively (no warning) |
  | 3 | Different window, same Space | `activate window N` + tab-switch | Passively (stderr warning) |
  | 4 | Different macOS Space | 不跨 Space raise，改開 new tab 在當前 Space | Non-interfering |

  Space detection 透過私 SPI `CGSGetActiveSpace` / `CGSGetWindowWorkspace`；權限不足時 fallback 到 Layer 3（保守）。

完整規範：`openspec/specs/human-emulation/spec.md`（tab-targeting-v2 archive 後生成）

## Multi-window / Multi-document targeting (#17 #18 #21 #23 #26)

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

# #26: Window-only commands 也全部接受 TargetOptions（native-path resolver）
safari-browser close --url plaud
safari-browser screenshot --url plaud out.png
safari-browser pdf --url docs --allow-hid out.pdf
safari-browser upload --native "input[type=file]" file.mp3 --url plaud
safari-browser close --document 3     # document N → owning window
safari-browser pdf --tab 2 --allow-hid out.pdf  # --tab alias for --document
```

**規則**：
- `--url` / `--window` / `--tab` / `--document` 四者**互斥**
- Read-only query 自動 document-scoped，modal sheet 不會 block（#21 fix）
- **Window-level UI ops**（`tabs` / `tab` / `open --new-tab` / `open --new-window`）只接受 `--window`
- **Window-only primitives**（`close` / `screenshot` / `pdf` / `upload --native` / `upload --allow-hid`）**接受完整 TargetOptions**（#26）— 透過 `SafariBridge.resolveNativeTarget` 把 `--url` / `--tab` / `--document` 映射到具體 `(windowIndex, tabIndexInWindow)` pair，keystroke-based commands 會先 tab-switch 再 raise window 再送 keystroke
- **Multi-match fail-closed**（#26）：`--url plaud` 比對到 >1 個 window 會丟 `ambiguousWindowMatch` 並列出所有 match 要求更具體 substring；first-match 不是 valid behavior（silent-wrong-target 是 automation 的 nightmare）
- **Screenshot 不 tab-switch**（#26）：其他 window-only commands 會 `performTabSwitchIfNeeded`，但 screenshot 刻意不切 tab — 因為 screenshot 是觀察性的，切 tab 破壞非干擾契約。URL 指向 background tab 時，screenshot 捕捉該 window 的**當前 tab**（可能不是 plaud）。要捕捉 background tab 內容需先手動切 tab。
- **`pdf` / `upload --native` 的 targeting flag 會 briefly raise 目標 window + 必要時 switch tab**（#23 verify R4 + #26）— 因為 keystrokes 一定打 front window，raise 和 tab-switch 都是操作的一部分
- **`screenshot`（R7 C）全路徑使用 AXUIElement private SPI**（`_AXUIElementGetWindow`）：`--window N` / `--url` / `--document` 等所有有 flag 的 path 都走 AX 當 `AXIsProcessTrusted()` 為 true，可讀 hidden / background window bounds **不 raise**。預設 `screenshot`（無 flag）AX 可用時走 AX，不可用時回退 legacy CG name-match。`--full` mode 下 bounds read/write 也走 AX（`kAXPositionAttribute` / `kAXSizeAttribute`）同一個 AX element，消除 R6 cross-API mismatch。
- 不想授權 Accessibility → 改用 document-scoped 命令（`snapshot --url`, `get text --url`, `get source --url`）讀 DOM content 不需要 CG window ID。
- **Upload 路由**（#26 更新 #23 的 split path）：
  - Explicit `--js` → JS DataTransfer（受 10 MB 硬上限限制 from #24）
  - Explicit `--native` / `--allow-hid` → native file dialog 走 resolver
  - 無 flag 時：AX 可用 → native + resolver；AX 不可用 → JS fallback + 10 MB 上限檢查
  - `--url plaud` 搭配 11 MB 檔案不再像 #24 那樣無解 — AX 可用就走 native，**不**觸發 10 MB 上限
- **Wait breaking change**（#23）：原本的 `wait --url <pattern>` 改為 `wait --for-url <pattern>`，因為 `--url` 現在是 targeting flag

**注意**：`documents` subcommand 列出 Safari `document` collection 的 MRU 順序，但 `--document N` 在 native path（#26）被解讀成「spatial window-major 第 N 個 tab」— 兩者在單視窗單 tab 等價，多 tab 情境下略有差異。JS path 保留 Safari 的 document-index semantics。

AI agent 在多視窗環境建議：先跑 `safari-browser documents` 看有哪些 documents，然後用 `--url <substring>` 明確指定。避免靠 `front window` 的 z-order 猜測。

新抽象：
- `SafariBridge.TargetDocument` enum — 四個 case（#23）
- `SafariBridge.resolveDocumentReference(_:) -> String` — AppleScript reference 產生器（#23）
- `SafariBridge.resolveNativeTarget(from:) async throws -> ResolvedWindowTarget` — native path resolver（#26）
- `SafariBridge.pickNativeTarget(_:in:)` — pure resolver 核心（#26）
- `SafariBridge.listAllWindows()` / `parseWindowEnumeration(_:)` — 單一 AppleScript roundtrip enumeration（#26）
- `SafariBridge.performTabSwitchIfNeeded(window:tab:)` — tab 切換 helper（#26）
- `SafariBridge.ResolvedWindowTarget` / `WindowInfo` / `TabInWindow` structs（#26）
- `TargetOptions` ParsableArguments — 全域 CLI flags via `@OptionGroup`（#23，#26 擴展到 window-only primitives）
- `SafariBrowserError.documentNotFound(pattern:availableDocuments:)` — 錯誤路徑含 discovery（#23）
- `SafariBrowserError.ambiguousWindowMatch(pattern:matches:)` — 多 match 錯誤含 window + URL 列表（#26）

完整 spec 見：
- `openspec/specs/document-targeting/spec.md`
- `openspec/specs/document-listing/spec.md`
- `openspec/specs/non-interference/spec.md`
- `openspec/changes/archive/2026-04-13-multi-document-targeting/`（#23 原 design + trade-offs）
- `openspec/changes/native-url-resolution/`（#26 native path URL resolution）

## Persistent daemon (opt-in, Phase 1)

`safari-browser` 預設每次呼叫都 spawn 一個 `osascript` subprocess（~3s cold start）。`persistent-daemon` 是 opt-in 長駐 process，把 AppleScript source pre-compile 成 `NSAppleScript` handle 放記憶體裡，**不快取 Safari state**（re-query each request，符合 `No Safari state cache` 契約）。**與 save-image-subcommand 的順序**：save-image 先 land，daemon 疊在它上面。

### 三個 opt-in signal（任一觸發即啟用）

| Signal | 用途 |
|---|---|
| `--daemon` flag | 單次顯式 opt-in |
| `SAFARI_BROWSER_DAEMON=1` env | session-wide opt-in |
| Live socket at `${TMPDIR}/safari-browser-<NAME>.sock` | 跑過 `daemon start` 後自動沿用 |

三者皆 off → **完全 stateless path**，沒有 daemon process，沒有 socket，和舊版行為位元級一致。

### Namespace

`<NAME>` 來源優先序：`--name` flag > `SAFARI_BROWSER_NAME` env > `"default"`。兩個不同 NAME 的 daemon 共存不會衝突（獨立 socket / pid / log）。

### Phase 1 coverage（daemon-routed）

`snapshot` `click` `fill` `type` `press` `js` `documents` `get url` `get title` `wait` `storage`

### 不在 Phase 1 的 commands（daemon 開著也走 stateless）

`screenshot` `pdf` `upload --native` `upload --allow-hid` — 這些走 keystroke / CG / AX private SPI，daemon 化沒有顯著收益。

### Failure modes（五種都 silent-fallback）

1. Socket 不存在
2. Connection refused（daemon crashed 但 socket 殘留）
3. Version handshake mismatch（CLI vs daemon build 不同）
4. Non-domain error（socket IO / JSON parse）
5. 15 秒 timeout

這五種會 fallback 到 stateless 並在 stderr 印一行 `[daemon fallback: <reason>]`。**Domain errors**（例如 `ambiguousWindowMatch`）**不 fallback** — 因為 stateless path 會產生一樣的 ambiguity，fallback 沒意義。

### Idle timeout

預設 600 秒（10 分鐘）沒收到 request 就 clean-exit（移除 socket + pid）。可用 `SAFARI_BROWSER_DAEMON_IDLE_TIMEOUT` env 調整，clamped 到 `[60, 3600]`。

### Version handshake

Daemon 連線時送 `{"protocol":"safari-browser-daemon","version":"<semver>+<git-commit>"}` handshake。Dirty build（`git status` 非空）的 version 會帶 `+dirty-<hash>` 尾巴，**永遠 mismatch** — 避免 WIP daemon 吃到下一版 CLI 的 request。

### 相關 specs

- `openspec/specs/persistent-daemon/spec.md`（archive 後生成）
- `openspec/changes/persistent-daemon/`（while in-flight）

## Exec scripts (`safari-browser exec`)

Multi-step automation in single invocation。Agents 用 JSON 描述 step sequence，binary 處理 variable capture / conditional flow / shared target resolution，避免 shell pipelining 的 plumbing。

### Script format

```json
[
  {"cmd": "get url", "var": "u"},
  {"cmd": "js", "args": ["1+1"], "if": "$u contains \"plaud\""},
  {"cmd": "click", "args": ["button.upload"], "onError": "continue"}
]
```

| Key | Required | Meaning |
|---|---|---|
| `cmd` | yes | Subcommand name（`get url`, `click`, `js`, `wait`, `storage local get`, ...） |
| `args` | no | Positional args（default `[]`） |
| `var` | no | Bind result to `$name` for later steps |
| `if` | no | Skip step when expression is false |
| `onError` | no | `"abort"`（default）or `"continue"` |

### `if:` expression mini-language

| Form | Example |
|---|---|
| `$var contains "<literal>"` | `$url contains "plaud"` |
| `$var equals "<literal>"` | `$title equals "Dashboard"` |
| `$var exists` | `$token exists` |

無 `and` / `or` / `not` / parens — 複雜邏輯讓 host language（Python / shell）生 JSON。

### Error codes

`invalidScriptFormat` `invalidStepSchema` `undefinedVariable` `invalidCondition` `maxStepsExceeded` `unsupportedInExec` — 加上每 step 自己 dispatch 出來的標準 error codes（`elementNotFound`, `documentNotFound`, `ambiguousWindowMatch`, ...）。

### v1 implementation note

V1 dispatch 透過 subprocess 跑同個 binary（不是 design 原本的 daemon-shared-connection）。當 daemon mode opt-in 時每個 step 還是 ~50ms 透過 warm daemon。Connection-sharing 是 v2 enhancement。

`screenshot` / `pdf` / `upload` 觸發 `unsupportedInExec`（keystroke / CG / AX path 不適合 exec script）。

### 相關 specs

- `openspec/specs/script-exec/spec.md`（archive 後生成）
- `openspec/changes/script-exec-command/`（while in-flight）

## Tab ownership marker (`--mark-tab`)

讓多個 agent / process 在同台機器上互相偵測「這個 tab 現在被別人操作」的 advisory probe。**不是 lock**，只是 hint — 兩個 agent 都可以 wrap 而第三個 query 看到 marker 後決定是否 yield 屬於 caller-policy。

### Opt-in signals（三選一）

| Signal | Mode |
|---|---|
| `--mark-tab` flag | Ephemeral — wrap before, unwrap after this command |
| `--mark-tab-persist` flag | Persist — wrap before, leave marker until `tab unmark` |
| `SAFARI_BROWSER_MARK_TAB=1` env | Ephemeral session-wide (env value `2` or `persist` → persist mode) |

兩個 flag 互斥；flag 永遠贏 env。預設完全 OFF — `safari-browser click ...` 不加 flag 永遠不 mutate title。

### Marker format（不可配置）

兩個 zero-width-space (`U+200B`) 包住原 title。**對使用者不可見**，AX / Spotlight / Stage Manager / screenshot 都讀不到任何 visible 變化。Hardcoded — 沒有 `--mark-tab "[my-agent]"` API（spec 層級禁止以避免 cross-process side-channel for agent identity）。

### Probe 與 cleanup

```bash
# 在 PR pipeline / 多 agent 場景：先 query，再決定動作
safari-browser tab is-marked --url plaud   # exit 0 = marked, 1 = unmarked, 2 = error

# 從 crash 過的 --mark-tab-persist 殘留 marker 救援
safari-browser tab unmark --url plaud
```

### Title race

如果 page 在 operation 中途 navigate 或 JS 改寫 `document.title`，cleanup 偵測到 expected wrapped title 不見就印一行 `[mark-tab: title changed during operation; original not restored]\n` to stderr 然後 no-op。**不重試、不強制 force-set**（避免 Layer 3 oscillation）。

### v1 scope

V1 wires marker 到 `ClickCommand` 作為 reference integration。其他 30+ commands 的批量 wiring + daemon-protocol-level 整合是 v2。`tab is-marked` / `tab unmark` 已可用，可作為 manual probe 起點。

### 相關 specs

- `openspec/specs/tab-ownership-marker/spec.md`（archive 後生成）
- `openspec/changes/tab-ownership-marker/`（while in-flight）
